// pipeline.bal
// Three-step chained pipeline for finding and verifying OpenAPI specs.
//
// Step 1: stepQuickVerify         — pure HTTP, stable/direct endpoints only
// Step 2: stepGithubVersionCheck  — Claude, GitHub-hosted specs with known URL
// Step 3: stepDiscovery           — Claude, find candidates from scratch
// Step 4: stepContentVerify       — pure HTTP, confirm discovered candidates
//
// SPA handling: known SPA domains are fetched via the headless browser
// service (browser-service/server.js) instead of being skipped. This allows
// Claude to read the actual rendered page and find "Download OpenAPI" links.

import ballerina/http;
import ballerina/log;
import ballerina/os;

// ─── Known SPA domains ───────────────────────────────────────────────────────
// These docs pages are JavaScript SPAs — fetching them wastes time and returns
// nothing useful. When detected, Claude skips straight to GitHub inference.

isolated function isKnownSpaDomain(string url) returns boolean {
    string lo = url.toLowerAscii();
    string[] spaDomains = [
        "docs.stripe.com",
        "developers.zoom.us",
        "developer.paypal.com",
        "developers.docusign.com",
        "developer.salesforce.com",
        "platform.openai.com",
        "developers.google.com",
        "learn.microsoft.com",
        "discord.com/developers",
        "developer.atlassian.com",
        "developer.x.com",
        "developer.twitter.com",
        "developers.hubspot.com"
    ];
    foreach string domain in spaDomains {
        if lo.includes(domain) { return true; }
    }
    return false;
}

// ─── STEP 1: Quick Verify (stable/direct URLs only) ──────────────────────────
// Only for non-GitHub direct endpoints like:
//   developer.candid.org/openapi/...
//   www.elastic.co/docs/api/...
//   api.mailchimp.com/schema/...
//   app.stainless.com/api/spec/...
//   developers.smartsheet.com/...
//   dac-static.atlassian.com/...
//
// These are CDN/API endpoints that always serve the current version.
// A HEAD check + content sniff is sufficient — no sibling checking needed.
// Returns the existing SpecResult if valid, null if we need further checking.

public function stepQuickVerify(
    string? knownSpecUrl,
    string? knownSpecRepo
) returns SpecResult? {

    if knownSpecUrl is () {
        log:printInfo("  [step1] no known URL — proceeding to discovery");
        return ();
    }

    // GitHub-hosted URLs need version-sibling checking — handled by step 2
    if knownSpecUrl.includes("raw.githubusercontent.com") {
        log:printInfo("  [step1] GitHub URL — skipping to version check");
        return ();
    }

    log:printInfo(string `  [step1] stable endpoint check: ${knownSpecUrl}`);

    if !headOk(knownSpecUrl) {
        log:printInfo("  [step1] URL is dead — triggering re-discovery");
        return ();
    }

    // Confirm it still looks like a spec (100KB for large specs)
    string|error body = httpGetBodyPartial(knownSpecUrl, 100000);
    if body is error {
        log:printInfo("  [step1] content check failed — triggering re-discovery");
        return ();
    }

    if !looksLikeSpec(body) {
        log:printInfo("  [step1] content is not a spec — triggering re-discovery");
        return ();
    }

    string fmt = knownSpecUrl.toLowerAscii().endsWith(".json") ? "json" : "yaml";
    log:printInfo("  [step1] stable URL confirmed valid — done");
    return {
        specUrl: knownSpecUrl,
        specRepo: knownSpecRepo,
        title: (),
        apiVersion: (),
        format: fmt
    };
}

// ─── STEP 2: GitHub Version Check ────────────────────────────────────────────
// For GitHub-hosted specs with a known URL.
// Fetches the known URL to confirm it is still valid, then checks the parent
// folder for newer siblings.
//
// Returns:
//   SpecResult  → valid URL (same or newer)
//   "DEAD"      → known URL is gone, need full re-discovery
//   ()          → agent error/timeout

const string GITHUB_CHECK_SYSTEM_PROMPT =
    "You are checking whether a GitHub-hosted OpenAPI spec URL is still the LATEST version.\n" +
    "\n" +
    "## Tool: fetch_page\n" +
    "Fetches a URL. Use it with the GitHub Contents API:\n" +
    "  https://api.github.com/repos/OWNER/REPO/contents/PATH\n" +
    "Returns a JSON array of {name, type, path, download_url} entries.\n" +
    "\n" +
    "Rules:\n" +
    "  - Maximum 5 fetch_page calls\n" +
    "  - Never fetch the same URL twice\n" +
    "  - Never fetch github.com/blob/ or github.com/tree/ pages\n" +
    "\n" +
    "## Your task\n" +
    "1. Fetch the known spec URL to confirm it is still valid\n" +
    "   (content must contain openapi: or swagger: or \"openapi\" or \"swagger\")\n" +
    "   - If 404 or not a spec → output DEAD\n" +
    "   - If valid → proceed to step 2\n" +
    "2. Check the parent folder using the Contents API for newer siblings:\n" +
    "   - List the parent folder and look for other spec files or subfolders\n" +
    "   - If multiple spec files exist, prefer the one with the highest version\n" +
    "     or most recently updated (use git/commits?path=... if needed)\n" +
    "   - Prefer files whose name contains: openapi, swagger, api, spec\n" +
    "   - Skip folders or files that appear to be staging, preview, or draft versions\n" +
    "3. If a newer version exists → return it. Otherwise → return the original.\n" +
    "\n" +
    "## Output format — EXACTLY one of these, no other text\n" +
    "\n" +
    "When the spec is valid (same or newer URL found):\n" +
    "GITHUB_CHECK_RESULT:\n" +
    "URL: https://raw-download-url\n" +
    "REPO: owner/repo\n" +
    "\n" +
    "When the known URL is dead or content is not a spec:\n" +
    "GITHUB_CHECK_RESULT:\n" +
    "DEAD\n";

public function stepGithubVersionCheck(
    string knownSpecUrl,
    string? knownSpecRepo,
    string anthropicKey
) returns SpecResult?|string {

    log:printInfo(string `  [step2] GitHub version check: ${knownSpecUrl}`);

    string repoContext = knownSpecRepo is string
        ? string `\nGitHub repo: ${knownSpecRepo}`
        : "";

    string? inferredRepo = knownSpecRepo;
    if inferredRepo is () {
        inferredRepo = inferRepoFromRawUrl(knownSpecUrl);
    }
    string repoForContentsApi = inferredRepo is string
        ? string `\nUse Contents API on repo: ${inferredRepo}`
        : "";

    string userMsg = string `Check if this GitHub-hosted OpenAPI spec URL is still the latest version:
Known URL: ${knownSpecUrl}${repoContext}${repoForContentsApi}

1. Fetch the known URL to verify it is still a valid spec
2. Check the parent folder for newer siblings
3. Return GITHUB_CHECK_RESULT`;

    json[] messages = [{"role": "user", "content": userMsg}];
    map<boolean> fetched = {};
    string model = os:getEnv("CLAUDE_MODEL");
    if model.length() == 0 { model = "claude-sonnet-4-6"; }
    int maxTurns = 7;
    int turn = 0;

    while turn < maxTurns {
        turn += 1;
        log:printInfo(string `  [step2 turn ${turn}]`);

        json|error resp = callClaude(anthropicKey, model, messages, GITHUB_CHECK_SYSTEM_PROMPT);
        if resp is error {
            log:printInfo(string `  [step2 error] ${resp.message()}`);
            return ();
        }

        string stopReason = "";
        json[] blocks = [];
        if resp is map<json> {
            json? sr = resp["stop_reason"];
            if sr is string { stopReason = sr; }
            json? cb = resp["content"];
            if cb is json[] { blocks = cb; }
        }

        string text = "";
        json[] toolBlocks = [];
        foreach json blk in blocks {
            if blk is map<json> {
                json? t = blk["type"];
                if t == "text" {
                    json? tv = blk["text"];
                    if tv is string { text += tv; }
                } else if t == "tool_use" {
                    toolBlocks.push(blk);
                }
            }
        }

        if text.length() > 0 {
            int preview = text.length() > 400 ? 400 : text.length();
            log:printInfo(string `  [step2 claude] ${text.substring(0, preview)}`);
        }

        if text.includes("GITHUB_CHECK_RESULT:") {
            return parseGithubCheckResult(text, knownSpecRepo);
        }

        if stopReason == "tool_use" && toolBlocks.length() > 0 {
            messages.push({"role": "assistant", "content": blocks});
            json[] results = [];
            foreach json tb in toolBlocks {
                if tb is map<json> {
                    string toolId = "";
                    json? tid = tb["id"];
                    if tid is string { toolId = tid; }
                    string output = "{\"error\":\"invalid call\"}";
                    json? inp = tb["input"];
                    if inp is map<json> {
                        json? urlVal = inp["url"];
                        if urlVal is string {
                            if fetched.hasKey(urlVal) {
                                output = "{\"error\":\"already fetched\"}";
                            } else {
                                fetched[urlVal] = true;
                                output = executeFetchPage(urlVal);
                            }
                        }
                    }
                    results.push({"type": "tool_result", "tool_use_id": toolId, "content": output});
                }
            }
            messages.push({"role": "user", "content": results});
            continue;
        }

        if stopReason == "end_turn" {
            messages.push({"role": "assistant", "content": blocks});
            messages.push({"role": "user", "content": "Output GITHUB_CHECK_RESULT now."});
            continue;
        }

        break;
    }

    return ();
}

function parseGithubCheckResult(string text, string? fallbackRepo) returns SpecResult?|string {
    int? idx = text.indexOf("GITHUB_CHECK_RESULT:");
    if idx is () { return (); }
    string after = text.substring(idx + 20).trim();

    if after.startsWith("DEAD") {
        log:printInfo("  [step2] known URL is DEAD — triggering re-discovery");
        return "DEAD";
    }

    string[] lines = splitLines(after);
    string url = "";
    string repo = fallbackRepo ?: "";

    foreach string line in lines {
        string t = line.trim();
        if t.startsWith("URL:") { url = t.substring(4).trim(); }
        else if t.startsWith("REPO:") { repo = t.substring(5).trim(); }
    }

    if url.length() == 0 { return (); }

    if !headOk(url) {
        log:printInfo(string `  [step2] returned URL failed HEAD check: ${url}`);
        return ();
    }

    string fmt = url.toLowerAscii().endsWith(".json") ? "json" : "yaml";
    log:printInfo(string `  [step2] confirmed: ${url}`);
    return {
        specUrl: url,
        specRepo: repo.length() > 0 ? repo : fallbackRepo,
        title: (),
        apiVersion: (),
        format: fmt
    };
}

// ─── STEP 3: Discovery Agent ──────────────────────────────────────────────────
// The primary strategy is ALWAYS to fetch the docs URL first.
// For SPA domains, the headless browser service renders the page so Claude
// can read the actual content including "Download OpenAPI" buttons.
// GitHub search and APIs-guru are fallbacks only.

const string DISCOVERY_SYSTEM_PROMPT =
    "You are an expert at finding publicly available OpenAPI/Swagger specification files.\n" +
    "\n" +
    "## Your ONLY job\n" +
    "Find the raw download URL(s) for the OpenAPI/Swagger spec file.\n" +
    "Return a structured list of candidate URLs — do NOT verify content.\n" +
    "\n" +
    "## PRIMARY STRATEGY: Always read the docs page first\n" +
    "The docs page is the most reliable source. It often has a visible\n" +
    "'Download OpenAPI', 'Download spec', or 'OpenAPI spec' link or button.\n" +
    "ALWAYS fetch the docs URL as your first action unless knownSpecRepo is given.\n" +
    "\n" +
    "When reading the docs page response:\n" +
    "  - Look in spec_links for any .yaml, .json, or openapi/swagger URLs\n" +
    "  - Look in other_links for links containing: download, openapi, swagger, spec\n" +
    "  - Look in page_text for mentions of spec URLs or download buttons\n" +
    "  - If the page has a 'Download OpenAPI' button link — that IS the answer\n" +
    "\n" +
    "## Tool: fetch_page\n" +
    "Fetches a URL. Returns:\n" +
    "  - HTML page  → { spec_links: [...], page_text: \"...\", other_links: [...] }\n" +
    "  - JSON file  → { type: \"json\", content: \"<first 4 KB>\" }\n" +
    "  - YAML file  → { type: \"yaml\", content: \"<first 4 KB>\" }\n" +
    "\n" +
    "Rules:\n" +
    "  - Maximum 6 fetch_page calls total\n" +
    "  - Never fetch the same URL twice\n" +
    "  - Never fetch github.com/blob/ or github.com/tree/ (use Contents API instead)\n" +
    "  - GitHub Contents API: https://api.github.com/repos/OWNER/REPO/contents/PATH\n" +
    "\n" +
    "## Fallback strategy (only when docs page has no spec links)\n" +
    "If the docs page returns empty page_text (under 200 chars) AND no spec_links:\n" +
    "  1. If knownSpecRepo given → use Contents API on that repo directly\n" +
    "  2. Otherwise infer the GitHub org/repo from the API name or docs URL\n" +
    "     and try the Contents API on the most likely repo name\n" +
    "  3. Drill into folders to find .yaml/.json spec files\n" +
    "  4. Prefer files whose name contains: openapi, swagger, api, spec\n" +
    "  5. Prefer files in root, /spec/, /openapi/, /defs/ over deeply nested paths\n" +
    "  6. Skip folders named: test, example, archive, staging, preview, draft\n" +
    "\n" +
    "## Last resort: APIs-guru directory\n" +
    "Only after exhausting the docs page AND GitHub search, check APIs-guru:\n" +
    "  https://api.github.com/repos/APIs-guru/openapi-directory/contents/APIs\n" +
    "Find the folder matching the API provider name (e.g. zoom.us, stripe.com).\n" +
    "Drill into the version subfolder and get the download_url of openapi.yaml.\n" +
    "Only use APIs-guru if all other approaches have failed.\n" +
    "\n" +
    "## File selection preferences\n" +
    "  - Prefer highest OpenAPI/Swagger version (3.1.0 > 3.0.0 > 2.0)\n" +
    "  - Prefer YAML over JSON at the same version\n" +
    "  - Prefer default branch (main/master) over tagged releases\n" +
    "\n" +
    "## Output format — EXACTLY this, nothing else\n" +
    "DISCOVERY_RESULT:\n" +
    "REPO: owner/repo\n" +
    "URL: https://raw-download-url-1\n" +
    "URL: https://raw-download-url-2\n" +
    "\n" +
    "Or if nothing found:\n" +
    "DISCOVERY_RESULT:\n" +
    "NONE\n" +
    "\n" +
    "Only raw download URLs. Never github.com/blob/ links. No other text.";

public function stepDiscovery(
    string docsUrl,
    string apiName,
    string? targetTitle,
    string anthropicKey,
    string? knownSpecRepo
) returns DiscoveryResult {

    log:printInfo("  [step3] starting discovery");

    string targetNote = targetTitle is string
        ? string `\nTarget: find ONLY the spec titled '${targetTitle}'.`
        : "";

    string repoHint = knownSpecRepo is string
        ? string `\nKnown GitHub repo: ${knownSpecRepo} — start here with Contents API.`
        : "";

    // Note whether browser service is available for SPA pages
    string browserNote = "";
    if isKnownSpaDomain(docsUrl) {
        if isBrowserServiceAvailable() {
            browserNote = string `\nNOTE: The docs URL (${docsUrl}) is a JavaScript SPA. ` +
                "The browser service is running so fetch_page will return the fully rendered page. " +
                "Fetch the docs URL first — look for 'Download OpenAPI' links or buttons in the response.";
        } else {
            browserNote = string `\nNOTE: The docs URL (${docsUrl}) is a JavaScript SPA and the ` +
                "browser service is not running. The docs page may return limited content. " +
                "Try fetching it anyway, but if page_text is empty or under 200 chars with no spec_links, " +
                "fall back to GitHub search using the knownSpecRepo or infer the repo from the API name.";
        }
    }

    string userMsg = string `Find the OpenAPI spec download URL for: ${apiName}
Docs URL: ${docsUrl}${targetNote}${repoHint}${browserNote}

IMPORTANT: Always fetch the docs URL first. It often has a direct download link for the OpenAPI spec.
Return DISCOVERY_RESULT with raw download URLs only.`;

    json[] messages = [{"role": "user", "content": userMsg}];
    map<boolean> fetched = {};
    string model = os:getEnv("CLAUDE_MODEL");
    if model.length() == 0 { model = "claude-sonnet-4-6"; }

    int maxTurns = 8;
    int turn = 0;

    while turn < maxTurns {
        turn += 1;
        log:printInfo(string `  [step3 turn ${turn}]`);

        json|error resp = callClaude(anthropicKey, model, messages, DISCOVERY_SYSTEM_PROMPT);
        if resp is error {
            log:printInfo(string `  [step3 error] ${resp.message()}`);
            break;
        }

        string stopReason = "";
        json[] blocks = [];
        if resp is map<json> {
            json? sr = resp["stop_reason"];
            if sr is string { stopReason = sr; }
            json? cb = resp["content"];
            if cb is json[] { blocks = cb; }
        }

        string text = "";
        json[] toolBlocks = [];
        foreach json blk in blocks {
            if blk is map<json> {
                json? t = blk["type"];
                if t == "text" {
                    json? tv = blk["text"];
                    if tv is string { text += tv; }
                } else if t == "tool_use" {
                    toolBlocks.push(blk);
                }
            }
        }

        if text.length() > 0 {
            int preview = text.length() > 400 ? 400 : text.length();
            log:printInfo(string `  [step3 claude] ${text.substring(0, preview)}`);
        }

        if text.includes("DISCOVERY_RESULT:") {
            return parseDiscoveryResult(text);
        }

        if stopReason == "tool_use" && toolBlocks.length() > 0 {
            messages.push({"role": "assistant", "content": blocks});
            json[] results = [];
            foreach json tb in toolBlocks {
                if tb is map<json> {
                    string toolId = "";
                    json? tid = tb["id"];
                    if tid is string { toolId = tid; }
                    string output = "{\"error\":\"invalid call\"}";
                    json? inp = tb["input"];
                    if inp is map<json> {
                        json? urlVal = inp["url"];
                        if urlVal is string {
                            if fetched.hasKey(urlVal) {
                                output = "{\"error\":\"already fetched\"}";
                            } else {
                                fetched[urlVal] = true;
                                output = executeFetchPage(urlVal);
                            }
                        }
                    }
                    results.push({"type": "tool_result", "tool_use_id": toolId, "content": output});
                }
            }
            messages.push({"role": "user", "content": results});
            continue;
        }

        if stopReason == "end_turn" {
            messages.push({"role": "assistant", "content": blocks});
            messages.push({
                "role": "user",
                "content": "Output DISCOVERY_RESULT now. If you have not yet tried the APIs-guru directory, try it before giving up."
            });
            continue;
        }

        break;
    }

    return {candidateUrls: [], specRepo: (), discoveryMethod: "none"};
}

function parseDiscoveryResult(string text) returns DiscoveryResult {
    int? idx = text.indexOf("DISCOVERY_RESULT:");
    if idx is () {
        return {candidateUrls: [], specRepo: (), discoveryMethod: "none"};
    }

    string after = text.substring(idx + 17).trim();

    if after.startsWith("NONE") {
        return {candidateUrls: [], specRepo: (), discoveryMethod: "none"};
    }

    string[] lines = splitLines(after);
    string[] urls = [];
    string? repo = ();
    map<boolean> seen = {};

    foreach string line in lines {
        string t = line.trim();
        if t.startsWith("REPO:") {
            string r = t.substring(5).trim();
            if r.length() > 0 { repo = r; }
        } else if t.startsWith("URL:") {
            string u = t.substring(4).trim();
            if u.startsWith("http") && !seen.hasKey(u) {
                seen[u] = true;
                urls.push(u);
                // Add alternate branch variant for raw GitHub URLs
                if u.includes("raw.githubusercontent.com/") {
                    string alt = "";
                    if u.includes("/main/") {
                        int? mi = u.indexOf("/main/");
                        if mi is int { alt = u.substring(0, mi) + "/master/" + u.substring(mi + 6); }
                    } else if u.includes("/master/") {
                        int? mi = u.indexOf("/master/");
                        if mi is int { alt = u.substring(0, mi) + "/main/" + u.substring(mi + 8); }
                    }
                    if alt.length() > 0 && !seen.hasKey(alt) { seen[alt] = true; urls.push(alt); }
                }
            }
        }
    }

    string method = urls.length() > 0 ? "discovered" : "none";
    return {candidateUrls: urls, specRepo: repo, discoveryMethod: method};
}

// ─── STEP 4: Content Verify ───────────────────────────────────────────────────
// Pure HTTP — no Claude needed.
// Confirms each candidate URL actually contains a valid spec.
//
// NOTE: Fetches 100KB to handle large specs like Stripe (~14MB) where
// the `openapi:` field appears deep in the file, not at the start.

public function stepContentVerify(
    DiscoveryResult discovery
) returns SpecResult? {

    if discovery.candidateUrls.length() == 0 {
        log:printInfo("  [step4] no candidates to verify");
        return ();
    }

    log:printInfo(string `  [step4] verifying ${discovery.candidateUrls.length()} candidate(s)`);

    foreach string url in discovery.candidateUrls {
        log:printInfo(string `  [step4 check] ${url}`);

        if !headOk(url) {
            log:printInfo("  [step4] HEAD failed — skipping");
            continue;
        }

        // Fetch 100KB — needed for large specs (e.g. Stripe) where openapi:
        // field is not in the first few KB due to alphabetical YAML ordering
        string|error body = httpGetBodyPartial(url, 100000);
        if body is error {
            log:printInfo("  [step4] content fetch failed — skipping");
            continue;
        }

        if !looksLikeSpec(body) {
            log:printInfo("  [step4] content is not a spec — skipping");
            continue;
        }

        string fmt = url.toLowerAscii().endsWith(".json") ? "json" : "yaml";
        log:printInfo(string `  [step4] confirmed valid: ${url}`);
        return {
            specUrl: url,
            specRepo: discovery.specRepo,
            title: (),
            apiVersion: (),
            format: fmt
        };
    }

    log:printInfo("  [step4] all candidates failed");
    return ();
}

// ─── Spec content detection ───────────────────────────────────────────────────
// Checks whether a string looks like an OpenAPI/Swagger spec.
// Handles large specs where openapi: field is not at the very start.

isolated function looksLikeSpec(string content) returns boolean {
    string t = content.trim();
    // Standard starts
    if t.startsWith("openapi:") { return true; }
    if t.startsWith("swagger:") { return true; }
    // JSON format
    if t.includes("\"openapi\"") { return true; }
    if t.includes("\"swagger\"") { return true; }
    // YAML field not at root (e.g. Stripe spec starts with components:)
    if t.includes("\nopenapi:") { return true; }
    if t.includes("\nswagger:") { return true; }
    // Large alphabetically-ordered specs (e.g. Stripe) start with components:
    // and openapi: is too deep to appear within the first 100KB fetch window.
    // components: is an OpenAPI 3.x-specific top-level keyword — safe heuristic.
    if t.startsWith("components:") { return true; }
    return false;
}

// ─── Shared HTTP helpers ──────────────────────────────────────────────────────

function httpGetBodyPartial(string url, int maxBytes) returns string|error {
    string ghToken = os:getEnv("GITHUB_TOKEN");
    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
    if url.includes("api.github.com") && ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

    // Raw content files get 20s, docs pages get 8s
    decimal timeoutSecs = isRawContentUrl(url) ? 20 : 8;

    http:Client cl = check new (url, {
        followRedirects: {enabled: true, maxCount: 5},
        timeout: timeoutSecs,
        secureSocket: {enable: true}
    });
    http:Response resp = check cl->get("", headers);
    if resp.statusCode != 200 {
        return error(string `HTTP ${resp.statusCode}`);
    }
    string body = check resp.getTextPayload();
    return body.length() > maxBytes ? body.substring(0, maxBytes) : body;
}
