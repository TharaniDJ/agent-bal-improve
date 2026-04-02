import ballerina/http;
import ballerina/log;
import ballerina/os;

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
// A HEAD check is sufficient — no need to look for newer siblings.
//
// Returns the existing SpecResult if valid, null if we need further checking.

public function stepQuickVerify(
    string? knownSpecUrl,
    string? knownSpecRepo
) returns SpecResult? {

    if knownSpecUrl is () {
        log:printInfo("  [step1] no known URL — proceeding to discovery");
        return ();
    }

    // GitHub-hosted URLs need version-sibling checking — skip Step 1
    if knownSpecUrl.includes("raw.githubusercontent.com") {
        log:printInfo("  [step1] GitHub URL — skipping to version check");
        return ();
    }

    log:printInfo(string `  [step1] stable endpoint check: ${knownSpecUrl}`);

    if !headOk(knownSpecUrl) {
        log:printInfo("  [step1] URL is dead — triggering re-discovery");
        return ();
    }

    // Confirm it still looks like a spec
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
// Checks the parent folder structure for newer rollout/version siblings.
// This replaces what CASE A did in the original agent.
//
// Returns the latest confirmed URL (could be the same as known, or a newer one).
// Returns null if the known URL is dead and we need full re-discovery.

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
    "1. First fetch the known spec URL to confirm it is still valid (contains openapi: or swagger:)\n" +
    "   - If 404 or not a spec → output DEAD\n" +
    "   - If valid → proceed to step 2\n" +
    "2. Check the parent folder using the Contents API for newer siblings:\n" +
    "   - For versioned folder structures (Rollouts/<number>/<vN>/):\n" +
    "     * List the Rollouts folder → pick highest numeric folder\n" +
    "     * List that folder → pick highest vN subfolder\n" +
    "     * Get download_url of the spec file\n" +
    "   - For flat folders (all spec files at same level):\n" +
    "     * List the folder → if multiple spec files, pick most recently updated\n" +
    "   - SKIP folders named: staging, prerelease, preview, draft, canary, beta, alpha, rc\n" +
    "   - SKIP ISO date folders (YYYY-MM) unless no vN folder exists\n" +
    "3. If a newer version exists → return it. Otherwise → return the original.\n" +
    "\n" +
    "## Output format — EXACTLY one of these\n" +
    "When the spec is valid (same or newer):\n" +
    "GITHUB_CHECK_RESULT:\n" +
    "URL: https://raw-download-url\n" +
    "REPO: owner/repo\n" +
    "\n" +
    "When the known URL is dead or not a spec:\n" +
    "GITHUB_CHECK_RESULT:\n" +
    "DEAD\n" +
    "\n" +
    "No explanatory text before or after.";

public function stepGithubVersionCheck(
    string knownSpecUrl,
    string? knownSpecRepo,
    string anthropicKey
) returns SpecResult?|string {
    // Returns:
    //   SpecResult  → found valid (same or newer) URL
    //   "DEAD"      → known URL is dead, need full re-discovery
    //   ()          → error/timeout, treat as dead

    log:printInfo(string `  [step2] GitHub version check: ${knownSpecUrl}`);

    string repoContext = knownSpecRepo is string
        ? string `\nGitHub repo: ${knownSpecRepo}`
        : "";

    // Infer repo from URL if not provided
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

    // HEAD check to confirm
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

const string DISCOVERY_SYSTEM_PROMPT =
    "You are an expert at finding publicly available OpenAPI/Swagger specification files.\n" +
    "\n" +
    "## Your ONLY job\n" +
    "Find the raw download URL(s) for the OpenAPI/Swagger spec file.\n" +
    "Return a structured list of candidate URLs — do NOT verify content.\n" +
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
    "  - If docs page is a JavaScript SPA (empty page_text < 200 chars):\n" +
    "    * If knownSpecRepo is given → go directly to Contents API for that repo\n" +
    "    * Otherwise infer org/repo from the docs URL and try Contents API\n" +
    "\n" +
    "## Strategy\n" +
    "1. Fetch the docs URL\n" +
    "2. If it has spec_links → extract raw download URLs\n" +
    "3. If it is a SPA or GitHub link → use Contents API to find spec files\n" +
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

    string userMsg = string `Find the OpenAPI spec download URL for: ${apiName}
Docs URL: ${docsUrl}${targetNote}${repoHint}

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
                // Add alternate branch variant
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
// Given a list of candidate URLs from discovery, verify the content
// and return the first valid one. Pure HTTP — no Claude needed.

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
    http:Client cl = check new (url, {
        followRedirects: {enabled: true, maxCount: 5},
        timeout: 15,
        secureSocket: {enable: true}
    });
    http:Response resp = check cl->get("", headers);
    if resp.statusCode != 200 {
        return error(string `HTTP ${resp.statusCode}`);
    }
    string body = check resp.getTextPayload();
    return body.length() > maxBytes ? body.substring(0, maxBytes) : body;
}
