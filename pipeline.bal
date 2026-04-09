// pipeline.bal
// Three-step chained pipeline for finding and verifying OpenAPI specs.
//
// Step 1: stepQuickVerify         — pure HTTP, stable/direct endpoints only
// Step 2: stepGithubVersionCheck  — Claude, GitHub-hosted specs with known URL
// Step 3: stepDiscovery           — Claude, find candidates from scratch
// Step 4: stepContentVerify       — pure HTTP, confirm discovered candidates
//
// SPA handling is transparent: httpGetBody() in agent.bal detects thin HTML
// responses and retries via the headless browser service automatically.

import ballerina/http;
import ballerina/log;
import ballerina/os;

// ─── STEP 1: Quick Verify (stable/direct URLs only) ──────────────────────────

public function stepQuickVerify(
    string? knownSpecUrl,
    string? knownSpecRepo,
    string sourceUrl,
    string anthropicKey
) returns SpecResult?|string {

    if knownSpecUrl is () {
        log:printInfo("  [step1] no known URL — proceeding to discovery");
        return ();
    }

    if knownSpecUrl.includes("raw.githubusercontent.com") {
        log:printInfo("  [step1] GitHub URL — skipping to version check");
        return ();
    }

    log:printInfo(string `  [step1] stable endpoint — LLM version check: ${knownSpecUrl}`);
    return stepStableVersionCheck(knownSpecUrl, sourceUrl, knownSpecRepo, anthropicKey);
}

// ─── STEP 1b: Stable Version Check ───────────────────────────────────────────

const string STABLE_CHECK_SYSTEM_PROMPT =
    "You are verifying whether a known OpenAPI/Swagger spec URL is still the LATEST STABLE version.\n" +
    "\n" +
    "## CRITICAL: Only OpenAPI/Swagger specs are acceptable\n" +
    "The spec file MUST contain one of these as a root-level key:\n" +
    "  - openapi: (OpenAPI 3.x) — value like '3.0.0', '3.1.0'\n" +
    "  - swagger: (OpenAPI 2.x) — value like '2.0'\n" +
    "AsyncAPI specs (asyncapi: key), JSON Schema files, and other API description\n" +
    "formats are NOT acceptable. If you find one, keep searching.\n" +
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
    "  - Never fetch github.com/blob/ or github.com/tree/ pages\n" +
    "\n" +
    "## Your task\n" +
    "\n" +
    "### Step 1: Validate the known URL\n" +
    "Fetch the known spec URL.\n" +
    "  - If 404/error OR content does not have openapi:/swagger: as root key → output DEAD.\n" +
    "  - If it is an AsyncAPI spec (asyncapi: key) → output DEAD.\n" +
    "  - If valid OpenAPI/Swagger → proceed to Step 2.\n" +
    "\n" +
    "### Step 2: Fetch the source URL\n" +
    "ALWAYS fetch the source URL next.\n" +
    "  - Look for newer stable OpenAPI/Swagger spec URLs.\n" +
    "  - If no newer version found → return the known URL.\n" +
    "\n" +
    "### Step 3: Compare and decide\n" +
    "  - Return newer URL if found, otherwise return known URL.\n" +
    "  - Never return prerelease/beta/alpha URLs.\n" +
    "\n" +
    "## Output format\n" +
    "\n" +
    "Valid:\n" +
    "STABLE_CHECK_RESULT:\n" +
    "URL: https://...\n" +
    "REPO: owner/repo\n" +
    "\n" +
    "Dead/not a spec:\n" +
    "STABLE_CHECK_RESULT:\n" +
    "DEAD\n";

public function stepStableVersionCheck(
    string knownSpecUrl,
    string sourceUrl,
    string? knownSpecRepo,
    string anthropicKey
) returns SpecResult?|string {

    log:printInfo(string `  [step1b] stable version check: ${knownSpecUrl}`);

    string userMsg = string `Verify this OpenAPI spec URL and check if it is still the latest stable version.

Known spec URL: ${knownSpecUrl}
Source URL: ${sourceUrl}

Steps:
1. Fetch the known spec URL — confirm it has openapi: or swagger: as a root key.
   If it is an AsyncAPI spec or not a spec at all → output DEAD.
2. Fetch the source URL to check for any newer stable spec version.
3. Return the best stable URL found.

Return STABLE_CHECK_RESULT.`;

    json[] messages = [{"role": "user", "content": userMsg}];
    map<boolean> fetched = {};
    string model = os:getEnv("CLAUDE_MODEL");
    if model.length() == 0 { model = "claude-sonnet-4-6"; }
    int maxTurns = 9;
    int turn = 0;

    while turn < maxTurns {
        turn += 1;
        log:printInfo(string `  [step1b turn ${turn}]`);

        json|error resp = callClaude(anthropicKey, model, messages, STABLE_CHECK_SYSTEM_PROMPT);
        if resp is error {
            log:printInfo(string `  [step1b error] ${resp.message()}`);
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
            log:printInfo(string `  [step1b claude] ${text.substring(0, preview)}`);
        }

        if text.includes("STABLE_CHECK_RESULT:") {
            return parseStableCheckResult(text, knownSpecUrl, knownSpecRepo);
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
            messages.push({"role": "user", "content": "Output STABLE_CHECK_RESULT now."});
            continue;
        }

        break;
    }

    return ();
}

function parseStableCheckResult(string text, string fallbackUrl, string? fallbackRepo) returns SpecResult?|string {
    int? idx = text.indexOf("STABLE_CHECK_RESULT:");
    if idx is () { return (); }
    string after = text.substring(idx + 20).trim();

    if after.startsWith("DEAD") {
        log:printInfo("  [step1b] known URL is DEAD — triggering re-discovery");
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

    if url.length() == 0 { url = fallbackUrl; }

    if !headOk(url) {
        log:printInfo(string `  [step1b] returned URL failed HEAD check: ${url}`);
        return ();
    }

    string fmt = url.toLowerAscii().endsWith(".json") ? "json" : "yaml";
    log:printInfo(string `  [step1b] confirmed: ${url}`);
    return {
        specUrl: url,
        specRepo: repo.length() > 0 ? repo : fallbackRepo,
        title: (),
        apiVersion: (),
        format: fmt
    };
}

// ─── STEP 2: GitHub Version Check ────────────────────────────────────────────

const string GITHUB_CHECK_SYSTEM_PROMPT =
    "You are checking whether a GitHub-hosted OpenAPI spec URL is still the LATEST version.\n" +
    "\n" +
    "## CRITICAL: Only OpenAPI/Swagger specs are acceptable\n" +
    "The spec MUST contain openapi: or swagger: as a root-level key.\n" +
    "asyncapi: specs, JSON Schema, and other formats are NOT acceptable.\n" +
    "\n" +
    "## Tool: fetch_page\n" +
    "Use with the GitHub Contents API:\n" +
    "  https://api.github.com/repos/OWNER/REPO/contents/PATH\n" +
    "\n" +
    "Rules:\n" +
    "  - Maximum 5 fetch_page calls\n" +
    "  - Never fetch the same URL twice\n" +
    "  - Never fetch github.com/blob/ or github.com/tree/ pages\n" +
    "\n" +
    "## Your task\n" +
    "1. Fetch the known spec URL — verify it has openapi: or swagger: root key.\n" +
    "   If AsyncAPI or not a spec → output DEAD.\n" +
    "   If valid → proceed to step 2.\n" +
    "2. Check the parent folder for newer siblings.\n" +
    "   Pick the best using VERSION PRIORITY:\n" +
    "     a. Named semantic versions (v3, v4 …) — highest wins\n" +
    "     b. Date-based (2024-01 …) — only if no named versions exist\n" +
    "     c. Named always beats date\n" +
    "3. Return the best valid OpenAPI/Swagger URL.\n" +
    "\n" +
    "## Output format\n" +
    "\n" +
    "Valid:\n" +
    "GITHUB_CHECK_RESULT:\n" +
    "URL: https://raw-download-url\n" +
    "REPO: owner/repo\n" +
    "\n" +
    "Dead/invalid:\n" +
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

IMPORTANT: The spec must contain openapi: or swagger: as a root-level key.
If it is an AsyncAPI spec (asyncapi: key), treat as DEAD and output DEAD.

1. Fetch the known URL to verify it is a valid OpenAPI/Swagger spec
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

const string DISCOVERY_SYSTEM_PROMPT =
    "You are an expert at finding publicly available OpenAPI/Swagger specification files.\n" +
    "\n" +
    "## CRITICAL: Only OpenAPI/Swagger specs are acceptable\n" +
    "The spec file MUST contain one of these as a ROOT-LEVEL key:\n" +
    "  - `openapi:` (OpenAPI 3.x) — value must be '3.0.x' or '3.1.x'\n" +
    "  - `swagger:` (OpenAPI 2.x) — value must be '2.0'\n" +
    "\n" +
    "REJECT immediately — do NOT return these:\n" +
    "  - AsyncAPI specs: contain `asyncapi:` root key (NOT openapi/swagger)\n" +
    "  - JSON Schema files: contain `$schema:` root key\n" +
    "  - GraphQL schemas, protobuf files, RAML specs\n" +
    "  - Event-API specs, webhook schemas, message schemas\n" +
    "  - Any spec whose filename contains: async, event, webhook, message, schema\n" +
    "\n" +
    "When you fetch a spec file and its content starts with `asyncapi:` or contains\n" +
    "`\"asyncapi\":` as a root key → that is an AsyncAPI spec, NOT OpenAPI. Reject it\n" +
    "and keep searching.\n" +
    "\n" +
    "## Your ONLY job\n" +
    "Find the raw download URL(s) for the LATEST STABLE OpenAPI/Swagger spec file.\n" +
    "Return a structured list of candidate URLs — do NOT verify content.\n" +
    "\n" +
    "## PRIORITY ORDER — follow strictly, top to bottom\n" +
    "\n" +
    "### PRIORITY 1: Source URL (ALWAYS do this first)\n" +
    "ALWAYS fetch the source URL as your very first action.\n" +
    "Look for:\n" +
    "  - Direct .yaml/.json download links\n" +
    "  - 'Download OpenAPI', 'Download spec', 'OpenAPI spec' links\n" +
    "  - GitHub repo links → use Contents API to find spec files\n" +
    "  - README files that reference spec URLs\n" +
    "\n" +
    "When the source URL is a GitHub repo:\n" +
    "  - Fetch api.github.com/repos/OWNER/REPO/contents/ to list files\n" +
    "  - Look for spec files: openapi.yaml, swagger.yaml, spec.yaml, api.yaml etc.\n" +
    "  - Check subdirectories: /spec/, /openapi/, /swagger/\n" +
    "  - For repos with multiple files (like twilio-oai), identify the PRIMARY spec\n" +
    "    (e.g. twilio_api_v2010.yaml for Twilio, not product-specific sub-specs)\n" +
    "  - ALWAYS fetch at least one candidate file to check its root key before returning\n" +
    "\n" +
    "### PRIORITY 2: Vendor's official GitHub repository\n" +
    "Only if the source URL yields nothing useful:\n" +
    "  1. Infer the GitHub org/repo from the API name or source URL\n" +
    "  2. Try Contents API on the most likely repo name\n" +
    "  3. Try common repo name patterns: {vendor}-openapi, {vendor}-api-spec,\n" +
    "     openapi-{vendor}, {vendor}-rest-api-specifications\n" +
    "  4. Drill into folders to find OpenAPI spec files\n" +
    "  5. Skip: test/, example/, archive/, events-api/, async-api/, webhook/\n" +
    "\n" +
    "### PRIORITY 3: Vendor CDN / developer portal\n" +
    "Only if GitHub yields nothing:\n" +
    "  - Try common CDN patterns: dac-static.{vendor}.com/openapi/\n" +
    "  - Try developer.{vendor}.com/openapi/\n" +
    "\n" +
    "### PRIORITY 4 (LAST RESORT): APIs-guru directory\n" +
    "ONLY after source URL AND vendor GitHub have both failed:\n" +
    "  https://api.github.com/repos/APIs-guru/openapi-directory/contents/APIs\n" +
    "  IMPORTANT: APIs-guru may contain AsyncAPI specs — always verify the root key.\n" +
    "\n" +
    "## GitHub repo with targetTitle\n" +
    "If a targetTitle is provided, find the spec matching that specific API product.\n" +
    "For repos with many spec files (like Twilio's twilio-oai), pick the one whose\n" +
    "filename best matches the targetTitle.\n" +
    "\n" +
    "## If no spec file found after exhausting all sources\n" +
    "As a LAST RESORT ONLY (after trying source URL, vendor GitHub, CDN, and APIs-guru),\n" +
    "you may return the vendor's GitHub repository URL as a fallback:\n" +
    "  REPO_FALLBACK: https://github.com/OWNER/REPO\n" +
    "Only do this if you have confirmed the repo exists and likely contains specs,\n" +
    "but you could not identify the exact file path.\n" +
    "\n" +
    "## Tool: fetch_page\n" +
    "Fetches a URL. Returns:\n" +
    "  - HTML page  → { spec_links: [...], page_text: \"...\", other_links: [...] }\n" +
    "  - JSON file  → { type: \"json\", content: \"<first 4 KB>\" }\n" +
    "  - YAML file  → { type: \"yaml\", content: \"<first 4 KB>\" }\n" +
    "\n" +
    "Rules:\n" +
    "  - Maximum 10 fetch_page calls total\n" +
    "  - Never fetch the same URL twice\n" +
    "  - Never fetch github.com/blob/ or github.com/tree/\n" +
    "  - GitHub Contents API: https://api.github.com/repos/OWNER/REPO/contents/PATH\n" +
    "\n" +
    "## Output format\n" +
    "DISCOVERY_RESULT:\n" +
    "REPO: owner/repo\n" +
    "URL: https://raw-download-url-1\n" +
    "URL: https://raw-download-url-2\n" +
    "\n" +
    "Or if nothing found:\n" +
    "DISCOVERY_RESULT:\n" +
    "NONE\n" +
    "\n" +
    "Only raw download URLs. Never github.com/blob/ links. No other text.\n" +
    "List official vendor URLs BEFORE any APIs-guru URLs.\n" +
    "NEVER include AsyncAPI, event-api, or webhook spec URLs in the output.";

public function stepDiscovery(
    string sourceUrl,
    string apiName,
    string? targetTitle,
    string anthropicKey,
    string? knownSpecRepo
) returns DiscoveryResult {

    log:printInfo("  [step3] starting discovery");

    string targetNote = targetTitle is string
        ? string `\nTarget: find ONLY the OpenAPI/Swagger spec for '${targetTitle}'. Ignore unrelated specs.`
        : "";

    string repoHint = knownSpecRepo is string
        ? string `\nKnown GitHub repo: ${knownSpecRepo} — start here with Contents API.`
        : "";

    string userMsg = string `Find the OpenAPI/Swagger spec download URL for: ${apiName}
Source URL: ${sourceUrl}${targetNote}${repoHint}

CRITICAL REQUIREMENTS:
- The spec MUST have openapi: or swagger: as its ROOT-LEVEL key.
- AsyncAPI specs (asyncapi: root key) are NOT acceptable — reject and keep searching.
- Event-api, webhook, and async specs are NOT acceptable.

STRICT PRIORITY ORDER:
1. ALWAYS fetch the source URL first.
   If it is a GitHub repo URL, use the Contents API to list files.
   Look for openapi.yaml, swagger.yaml, api.yaml, spec.yaml in root and /spec/ /openapi/ subdirs.
   Fetch at least one candidate file to verify it has openapi: or swagger: as root key.
2. Only if source URL yields nothing → check the vendor's official GitHub repo.
3. Only if both fail → check vendor CDN/portal.
4. ONLY as absolute last resort → check APIs-guru (but verify it is not AsyncAPI).

Return DISCOVERY_RESULT with raw download URLs only.
NEVER include AsyncAPI spec URLs.`;

    json[] messages = [{"role": "user", "content": userMsg}];
    map<boolean> fetched = {};
    string model = os:getEnv("CLAUDE_MODEL");
    if model.length() == 0 { model = "claude-sonnet-4-6"; }

    int maxTurns = 12;
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
                "content": "Output DISCOVERY_RESULT now.\n" +
                    "IMPORTANT: Only include OpenAPI/Swagger spec URLs (openapi: or swagger: root key).\n" +
                    "Do NOT include AsyncAPI (asyncapi: key), event-api, or webhook spec URLs.\n" +
                    "If you truly found nothing after trying source URL, vendor GitHub, and APIs-guru,\n" +
                    "output DISCOVERY_RESULT:\\nNONE"
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

        string|error body = httpGetBodyPartial(url, 100000);
        if body is error {
            log:printInfo("  [step4] content fetch failed — skipping");
            continue;
        }

        if !looksLikeOpenApiSpec(body) {
            log:printInfo("  [step4] content is not an OpenAPI/Swagger spec — skipping");
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
// Validates that a file is an OpenAPI/Swagger spec (NOT AsyncAPI or other formats).
// Checks for openapi:/swagger: as ROOT-LEVEL keys.

isolated function looksLikeOpenApiSpec(string content) returns boolean {
    string t = content.trim();

    // ── Explicit rejections ──────────────────────────────────────────────────
    // AsyncAPI specs — reject even if they contain the word "openapi" elsewhere
    if t.startsWith("asyncapi:") { return false; }
    if t.includes("\"asyncapi\":") {
        // JSON AsyncAPI — check it appears near the start (root-level key)
        string head = t.length() > 500 ? t.substring(0, 500) : t;
        if head.includes("\"asyncapi\"") { return false; }
    }
    if t.includes("\nasyncapi:") { return false; }

    // ── OpenAPI/Swagger YAML ─────────────────────────────────────────────────
    // Root-level openapi: or swagger: key (YAML)
    if t.startsWith("openapi:") { return true; }
    if t.startsWith("swagger:") { return true; }
    if t.includes("\nopenapi:") { return true; }
    if t.includes("\nswagger:") { return true; }

    // ── OpenAPI/Swagger JSON ─────────────────────────────────────────────────
    // Root-level "openapi" or "swagger" key in JSON
    if t.startsWith("{") {
        string head = t.length() > 500 ? t.substring(0, 500) : t;
        // Must be a root key: appears right after { or after another root key
        if head.includes("\"openapi\"") { return true; }
        if head.includes("\"swagger\"") { return true; }
        // Large alphabetically-ordered JSON (e.g. Jira) starts with {"components":
        // and "openapi" appears much later — check "components" as root key signal
        if head.includes("\"components\"") { return true; }
    }

    // ── Large YAML specs (e.g. Stripe) start with components: ────────────────
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
