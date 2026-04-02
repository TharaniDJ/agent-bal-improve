// pipeline.bal
// Three-step chained pipeline for finding and verifying OpenAPI specs.
//
// Step 1: stepQuickVerify    — pure HTTP, stable/direct endpoints only
// Step 2: stepGithubVersionCheck — Claude, GitHub-hosted specs with known URL
// Step 3: stepDiscovery      — Claude, find candidates from scratch
// Step 4: stepContentVerify  — pure HTTP, confirm discovered candidates

import ballerina/http;
import ballerina/log;
import ballerina/os;

// ─── Known SPA domains ───────────────────────────────────────────────────────
// These docs pages are JavaScript SPAs — fetching them wastes time and returns
// nothing useful. When detected, Claude skips straight to GitHub inference.

isolated function isKnownSpa(string url) returns boolean {
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

    // Confirm it still looks like a spec (first 2KB is enough)
    string|error body = httpGetBodyPartial(knownSpecUrl, 2000);
    if body is error {
        log:printInfo("  [step1] content check failed — triggering re-discovery");
        return ();
    }

    string trimmed = body.trim();
    boolean isSpec = trimmed.startsWith("openapi:") || trimmed.startsWith("swagger:") ||
                     trimmed.includes("\"openapi\"") || trimmed.includes("\"swagger\"");

    if !isSpec {
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
// folder for newer rollout/version siblings.
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
    "1. First fetch the known spec URL to confirm it is still valid\n" +
    "   (content must contain openapi: or swagger: or \"openapi\" or \"swagger\")\n" +
    "   - If 404 or not a spec → output DEAD\n" +
    "   - If valid → proceed to step 2\n" +
    "2. Check the parent folder using the Contents API for newer siblings:\n" +
    "   - For versioned folder structures (Rollouts/<number>/<vN>/):\n" +
    "     * List the Rollouts folder → pick highest numeric folder\n" +
    "     * List that folder → pick highest vN subfolder\n" +
    "     * Get download_url of the spec file\n" +
    "   - For flat folders (all spec files at same level):\n" +
    "     * List the folder → pick the spec file (prefer openapi/swagger in name)\n" +
    "   - SKIP folders named: staging, prerelease, preview, draft, canary, beta, alpha, rc\n" +
    "   - SKIP ISO date folders (YYYY-MM or YYYY-MM-DD) unless no vN folder exists\n" +
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

    // Infer repo from URL if not explicitly provided
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
// Only runs when no known URL exists, or known URL is dead.
// Fetches the docs URL and finds candidate raw download URLs.
// SPA domains are detected and Claude is told to skip the docs fetch entirely.

const string DISCOVERY_SYSTEM_PROMPT =
    "You are an expert at finding publicly available OpenAPI/Swagger specification files.\n" +
    "\n" +
    "## Your ONLY job\n" +
    "Find the raw download URL(s) for the OpenAPI/Swagger spec file.\n" +
    "Return a structured list of candidate URLs — do NOT verify content.\n" +
    "\n" +
    "## Known SPA domains — do NOT fetch docs page, go straight to GitHub\n" +
    "These docs pages are JavaScript SPAs that return no useful content.\n" +
    "If the docs URL belongs to one of these, skip step 1 and go directly to step 3:\n" +
    "  - docs.stripe.com\n" +
    "  - developers.zoom.us\n" +
    "  - developer.paypal.com\n" +
    "  - developers.docusign.com\n" +
    "  - developer.salesforce.com\n" +
    "  - platform.openai.com\n" +
    "  - developers.google.com\n" +
    "  - learn.microsoft.com\n" +
    "  - discord.com/developers\n" +
    "  - developer.atlassian.com\n" +
    "  - developer.x.com\n" +
    "  - developer.twitter.com\n" +
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
    "  - If docs page returns empty page_text (under 200 chars) with no spec_links\n" +
    "    → it is a SPA; go immediately to GitHub Contents API\n" +
    "\n" +
    "## Strategy\n" +
    "1. If docs URL is a known SPA domain → skip to step 3\n" +
    "2. Otherwise fetch the docs URL\n" +
    "   - If spec_links found → extract raw download URLs → done\n" +
    "   - If SPA detected (empty page_text) → go to step 3\n" +
    "   - If GitHub repo link found → go to step 3\n" +
    "3. GitHub search:\n" +
    "   - If knownSpecRepo given → use Contents API on that repo\n" +
    "   - Otherwise infer org/repo from the API name or docs URL\n" +
    "     e.g. 'Stripe' → try api.github.com/repos/stripe/openapi/contents/\n" +
    "     e.g. 'Zoom Meetings' → try api.github.com/repos/zoom/zoom-api-description/contents/\n" +
    "   - Drill into folders to find .yaml/.json spec files\n" +
    "4. For versioned folders (Rollouts/<number>/<vN>/):\n" +
    "   - Pick highest numeric rollout folder\n" +
    "   - Pick highest vN subfolder\n" +
    "   - Use download_url from Contents API response\n" +
    "5. If the user message names a Target spec → match by title, ignore others\n" +
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

    // Tell Claude explicitly when the docs URL is a known SPA
    string spaNote = isKnownSpa(docsUrl)
        ? string `\nNOTE: The docs URL (${docsUrl}) is a JavaScript SPA — do NOT fetch it. ` +
          "Go directly to the GitHub Contents API. " +
          "Infer the GitHub org/repo from the API name if knownSpecRepo is not provided."
        : "";

    string userMsg = string `Find the OpenAPI spec download URL for: ${apiName}
Docs URL: ${docsUrl}${targetNote}${repoHint}${spaNote}

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
            messages.push({"role": "user", "content": "Output DISCOVERY_RESULT now."});
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

        string|error body = httpGetBodyPartial(url, 3000);
        if body is error {
            log:printInfo("  [step4] content fetch failed — skipping");
            continue;
        }

        string trimmed = body.trim();
        boolean isSpec = trimmed.startsWith("openapi:") || trimmed.startsWith("swagger:") ||
                         trimmed.includes("\"openapi\"") || trimmed.includes("\"swagger\"");

        if !isSpec {
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

// ─── Shared HTTP helpers ──────────────────────────────────────────────────────

function httpGetBodyPartial(string url, int maxBytes) returns string|error {
    string ghToken = os:getEnv("GITHUB_TOKEN");
    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
    if url.includes("api.github.com") && ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

    // Raw content files get 20s, docs pages get 8s
    decimal timeoutSecs = isRawContentUrl(url) ? 20.0 : 8.0;

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
