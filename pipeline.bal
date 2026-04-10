// pipeline.bal
// Three-step chained pipeline for finding and verifying OpenAPI specs.
//
// Step 1: stepQuickVerify         — pure HTTP, stable/direct endpoints only
// Step 2: stepGithubVersionCheck  — Claude, GitHub-hosted specs with known URL
// Step 3: stepDiscovery           — Claude, find candidates from scratch
// Step 4: stepContentVerify       — pure HTTP, confirm discovered candidates
//
// SPA handling is transparent: httpGetBody() in agent.bal detects thin HTML
// responses and retries via the Browserless cloud API automatically.

import ballerina/http;
import ballerina/log;
import ballerina/os;

// ─── STEP 1: Quick Verify (stable/direct URLs only) ──────────────────────────

public function stepQuickVerify(
    string? knownSpecUrl,
    string? knownSpecRepo,
    string docsUrl,
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
    return stepStableVersionCheck(knownSpecUrl, docsUrl, knownSpecRepo, anthropicKey);
}

// ─── STEP 1b: Stable Version Check (LLM-assisted) ────────────────────────────

const string STABLE_CHECK_SYSTEM_PROMPT =
    "You are verifying whether a known OpenAPI/Swagger spec URL is still the LATEST STABLE version.\n" +
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
    "## Your task — follow these steps in order\n" +
    "\n" +
    "### Step 1: Validate the known URL\n" +
    "Fetch the known spec URL.\n" +
    "  - If the fetch fails (404, error) OR the content does not contain\n" +
    "    openapi:, swagger:, \"openapi\", or \"swagger\" → output DEAD immediately.\n" +
    "  - If valid → note the spec content and proceed to Step 2.\n" +
    "\n" +
    "### Step 2: Fetch the docs page\n" +
    "ALWAYS fetch the docs URL next — it is the authoritative source for the\n" +
    "current latest version.\n" +
    "  - Scan spec_links, other_links, and page_text for any URL ending in\n" +
    "    .yaml or .json, or containing: openapi, swagger, spec, reference, download\n" +
    "  - Read page text to identify which API versions are mentioned and which\n" +
    "    is marked as 'latest', 'current', 'stable', or 'GA'\n" +
    "  - If the page lists versioned spec URLs, identify the one with the\n" +
    "    highest stable version number\n" +
    "  - If there is a changelog or release-notes link, you MAY fetch it (counts\n" +
    "    toward your fetch budget) to confirm the current stable release\n" +
    "\n" +
    "### Step 3: Compare and decide\n" +
    "  - If the docs page reveals a NEWER stable spec URL than the known URL\n" +
    "    → return the newer URL\n" +
    "  - If the known URL is already the latest stable version\n" +
    "    → return the known URL unchanged\n" +
    "  - If the docs page yields no spec links at all\n" +
    "    → return the known URL unchanged (it was valid per Step 1)\n" +
    "\n" +
    "## Stability rules — apply to every URL you consider\n" +
    "NEVER return a URL that contains any of these labels:\n" +
    "  alpha, beta, rc, preview, dev, snapshot, canary, nightly,\n" +
    "  staging, draft, wip, experimental, pre-release, next, edge\n" +
    "Among multiple stable candidates, pick the best using this priority:\n" +
    "  1. Named semantic version (v3, v4, v2, etc.) — HIGHEST number wins\n" +
    "  2. Date-based version (2024-01, 20240101, etc.) — only if NO named\n" +
    "     version folders/files exist; dates can be prereleases or snapshots\n" +
    "  3. If both types are present, ALWAYS prefer the named version over any date.\n" +
    "\n" +
    "## Output format — EXACTLY one of these, no other text\n" +
    "\n" +
    "When a valid stable spec URL is confirmed:\n" +
    "STABLE_CHECK_RESULT:\n" +
    "URL: https://raw-or-direct-download-url\n" +
    "REPO: owner/repo\n" +
    "\n" +
    "(REPO line is optional — omit if not applicable)\n" +
    "\n" +
    "When the known URL is dead or content is not a spec:\n" +
    "STABLE_CHECK_RESULT:\n" +
    "DEAD\n";

public function stepStableVersionCheck(
    string knownSpecUrl,
    string docsUrl,
    string? knownSpecRepo,
    string anthropicKey
) returns SpecResult?|string {

    log:printInfo(string `  [step1b] stable version check: ${knownSpecUrl}`);

    string userMsg = string `Verify this OpenAPI spec URL and check if it is still the latest stable version.

Known spec URL: ${knownSpecUrl}
Docs URL: ${docsUrl}

Steps:
1. Fetch the known spec URL to confirm it is still a valid OpenAPI/Swagger spec.
   If it is dead or not a spec → output DEAD.
2. Fetch the docs URL to check for any newer stable spec version.
   Look for spec links (.yaml, .json, openapi, swagger) and version indicators.
3. Return the best stable URL found (newer if available, otherwise the known URL).

Return STABLE_CHECK_RESULT.`;

    json[] messages = [{"role": "user", "content": userMsg}];
    map<boolean> fetched = {};
    string model = os:getEnv("CLAUDE_MODEL");
    if model.length() == 0 { model = "claude-sonnet-4-6"; }
    int maxTurns = 9;
    int turn = 0;

    while turn < maxTurns {
        turn += 1;
        log:printInfo(string `  [step1b turn ${turn}/${maxTurns}]`);

        json|error resp = callClaude(anthropicKey, model, messages, STABLE_CHECK_SYSTEM_PROMPT);
        if resp is error {
            log:printWarn(string `  [step1b] Claude API error: ${resp.message()}`);
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

        log:printWarn(string `  [step1b] unexpected stop_reason='${stopReason}' at turn ${turn} — aborting`);
        break;
    }

    log:printWarn(string `  [step1b] exhausted ${maxTurns} turns without a result`);
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
        log:printWarn(string `  [step1b] returned URL failed HEAD check: ${url}`);
        return ();
    }

    string fmt = url.toLowerAscii().endsWith(".json") ? "json" : "yaml";
    log:printInfo(string `  [step1b] confirmed valid: ${url}`);
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
    "   - If multiple spec files or version folders exist, pick the best using\n" +
    "     this VERSION PRIORITY (apply in order):\n" +
    "       a. Named semantic version folders/files (v3, v4, v2 …) — highest wins\n" +
    "       b. Date-based folders/files (2024-01, 20240101 …) — only if NO\n" +
    "          named version siblings exist; dates can be prereleases or snapshots\n" +
    "       c. If both types present, ALWAYS prefer named version over any date\n" +
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
        log:printInfo(string `  [step2 turn ${turn}/${maxTurns}]`);

        json|error resp = callClaude(anthropicKey, model, messages, GITHUB_CHECK_SYSTEM_PROMPT);
        if resp is error {
            log:printWarn(string `  [step2] Claude API error: ${resp.message()}`);
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

        log:printWarn(string `  [step2] unexpected stop_reason='${stopReason}' at turn ${turn} — aborting`);
        break;
    }

    log:printWarn(string `  [step2] exhausted ${maxTurns} turns without a result`);
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
        log:printWarn(string `  [step2] returned URL failed HEAD check: ${url}`);
        return ();
    }

    string fmt = url.toLowerAscii().endsWith(".json") ? "json" : "yaml";
    log:printInfo(string `  [step2] confirmed valid: ${url}`);
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
    "You are an expert at finding publicly available latest updated OpenAPI/Swagger specification files.\n" +
    "\n" +
    "## Your ONLY job\n" +
    "Find the raw download URL(s) for the LATEST STABLE OpenAPI/Swagger spec file.\n" +
    "Always target the highest released stable version — never prereleases, betas, RCs, or in-progress specs.\n" +
    "Return a structured list of candidate URLs — do NOT verify content.\n" +
    "\n" +
    "## PRIORITY ORDER — follow this strictly, top to bottom\n" +
    "\n" +
    "### PRIORITY 1 (ALWAYS do this first): Official docs page\n" +
    "ALWAYS fetch the docs URL as your very first action (unless knownSpecRepo is given).\n" +
    "The docs page is the most authoritative source. It often has a visible\n" +
    "'Download OpenAPI', 'Download spec', or 'OpenAPI spec' link or button.\n" +
    "\n" +
    "When reading the docs page response:\n" +
    "  - Look in spec_links for any .yaml, .json, or openapi/swagger URLs\n" +
    "  - Look in other_links for links containing: download, openapi, swagger, spec, reference\n" +
    "  - Look in page_text for mentions of spec URLs or download buttons\n" +
    "  - IMPORTANT: If the page contains ANY URL ending in .yaml, .json, or containing\n" +
    "    'openapi', 'swagger', or 'spec' — add it as a candidate IMMEDIATELY.\n" +
    "    These vendor-hosted URLs (CDN, API gateway, static assets) are OFFICIAL and\n" +
    "    must be returned before any GitHub or APIs-guru link.\n" +
    "  - If the page has a 'Download OpenAPI' button link — that IS the answer, stop here.\n" +
    "\n" +
    "Version detection from the docs page:\n" +
    "  - Read the page text to identify which API versions are mentioned\n" +
    "    (look for version numbers in headings, navigation, URL paths, or page_text)\n" +
    "  - Identify the HIGHEST stable version — the one marked as 'latest', 'current',\n" +
    "    'stable', 'GA', or carrying the highest semver/date number\n" +
    "  - If the page lists versioned spec URLs, apply VERSION TYPE PRIORITY:\n" +
    "      Named versions (/v3/openapi.yaml, /v4/spec.json) ALWAYS beat date-based ones\n" +
    "      (/2024-01/openapi.yaml). Use date-based only when no named versions exist.\n" +
    "      Among the winning type, pick the highest/most-recent stable entry.\n" +
    "  - If there is a changelog or release-notes link on the page, fetch it to confirm\n" +
    "    which version is the current stable release before choosing a URL\n" +
    "  - NEVER return a URL that contains: alpha, beta, rc, preview, dev, snapshot,\n" +
    "    canary, nightly, staging, draft, wip, experimental, pre-release, or next\n" +
    "\n" +
    "### PRIORITY 2: Vendor's official GitHub repository\n" +
    "Only if the docs page yields nothing useful:\n" +
    "  1. If knownSpecRepo given → use Contents API on that repo directly\n" +
    "  2. Otherwise infer the GitHub org/repo from the API name or docs URL\n" +
    "     and try the Contents API on the most likely repo name\n" +
    "  3. Try common repo name patterns: {vendor}-openapi, {vendor}-api-spec,\n" +
    "     openapi-{vendor}, {vendor}-rest-api-specifications, {vendor}-swagger\n" +
    "  4. Drill into folders to find .yaml/.json spec files\n" +
    "  5. Prefer files whose name contains: openapi, swagger, api, spec\n" +
    "  6. Prefer files in root, /spec/, /openapi/, /defs/ over deeply nested paths\n" +
    "  7. Skip folders named: test, example, archive, staging, preview, draft\n" +
    "\n" +
    "Versioning strategy — ALWAYS do this when you have a vendor repo:\n" +
    "  a. Understand how the repo publishes spec versions before picking a file.\n" +
    "     Fetch the repo root via the Contents API and look for patterns such as:\n" +
    "       - Version-named folders (/v1/, /v2/, /2023-01/, etc.)\n" +
    "       - Version-named files (openapi-v3.yaml, openapi-2024-10.json)\n" +
    "       - Versioned branches (release/v2, v3-stable)\n" +
    "       - GitHub Releases/tags (fetch https://api.github.com/repos/OWNER/REPO/releases\n" +
    "         or /tags to see published versions)\n" +
    "  b. Once you understand the versioning pattern, identify the LATEST STABLE version.\n" +
    "     VERSION PRIORITY — apply in this order for every source:\n" +
    "       1. Named semantic version folders/files (v3, v4, v2, etc.):\n" +
    "          ALWAYS prefer these. Pick the highest number.\n" +
    "       2. Date-based folders/files (2024-01, 20240101, 2023-10, etc.):\n" +
    "          Use ONLY when no named-version siblings exist. Dates can represent\n" +
    "          prereleases, snapshots, or rolling work-in-progress cuts.\n" +
    "       3. If BOTH types are present in the same folder/repo, the named version\n" +
    "          ALWAYS wins regardless of which date is more recent.\n" +
    "     Apply this to specific repo layouts:\n" +
    "       - For folder-per-version repos: pick the highest named-version folder\n" +
    "         first; fall back to the latest date folder only if no named ones exist\n" +
    "       - For release/tag-based repos: fetch /releases and pick the latest non-prerelease\n" +
    "         (prerelease: false in the GitHub API response) or the highest semver tag\n" +
    "         that does NOT contain: alpha, beta, rc, preview, dev, snapshot, canary, next\n" +
    "       - For single-file repos that update in place (main/master branch): that file\n" +
    "         IS the latest version — use it\n" +
    "  c. Always use raw.githubusercontent.com download URLs pointing at the\n" +
    "     latest stable commit/tag — NEVER github.com/blob/ links\n" +
    "  d. If the repo uses GitHub Releases to publish spec files as release assets,\n" +
    "     use the browser_download_url of the latest non-prerelease release asset\n" +
    "\n" +
    "### PRIORITY 3: Other official vendor sources\n" +
    "Only if docs page AND GitHub both yield nothing:\n" +
    "  - Check vendor CDN or static asset URLs you know about for this vendor\n" +
    "  - Check the vendor's developer portal for a spec download endpoint\n" +
    "  - Try common CDN patterns: dac-static.{vendor}.com, developer.{vendor}.com/openapi/\n" +
    "\n" +
    "### PRIORITY 4 (ABSOLUTE LAST RESORT ONLY): APIs-guru directory\n" +
    "CRITICAL: Only check APIs-guru AFTER you have:\n" +
    "  (a) fetched the docs page AND found no spec links, AND\n" +
    "  (b) tried at least one vendor GitHub repo AND found no spec file.\n" +
    "Do NOT jump to APIs-guru early. APIs-guru specs are often outdated mirrors.\n" +
    "The official vendor source is ALWAYS preferred over APIs-guru.\n" +
    "\n" +
    "When you must fall back to APIs-guru:\n" +
    "  https://api.github.com/repos/APIs-guru/openapi-directory/contents/APIs\n" +
    "  Find the folder matching the API provider name (e.g. zoom.us, stripe.com).\n" +
    "  Drill into the version subfolder and get the download_url of openapi.yaml.\n" +
    "\n" +
    "## Tool: fetch_page\n" +
    "Fetches a URL. Returns:\n" +
    "  - HTML page  → { spec_links: [...], page_text: \"...\", other_links: [...] }\n" +
    "  - JSON file  → { type: \"json\", content: \"<first 4 KB>\" }\n" +
    "  - YAML file  → { type: \"yaml\", content: \"<first 4 KB>\" }\n" +
    "\n" +
    "Rules:\n" +
    "  - Maximum 8 fetch_page calls total\n" +
    "  - Never fetch the same URL twice\n" +
    "  - Never fetch github.com/blob/ or github.com/tree/ (use Contents API instead)\n" +
    "  - GitHub Contents API: https://api.github.com/repos/OWNER/REPO/contents/PATH\n" +
    "\n" +
    "## Version detection summary\n" +
    "For ANY source (docs page, GitHub repo, CDN), apply these rules:\n" +
    "  1. Read the source to understand its versioning scheme before picking a URL\n" +
    "  2. Always select the HIGHEST stable released version available\n" +
    "  3. A version is stable if it does NOT carry any of these labels:\n" +
    "       alpha, beta, rc, preview, dev, snapshot, canary, nightly,\n" +
    "       staging, draft, wip, experimental, pre-release, next, edge\n" +
    "  4. VERSION TYPE PRIORITY — when comparing candidates across version types:\n" +
    "       a. Named semantic versions (v3, v4, v2 …) ALWAYS beat date-based ones\n" +
    "          (2024-01, 20240101 …). Dates can be prereleases or unstable snapshots.\n" +
    "       b. Use date-based versions ONLY if no named-version folders/files exist.\n" +
    "       c. When only date-based versions exist, pick the most recent stable date.\n" +
    "  5. For GitHub repos use /releases (prefer prerelease:false) or /tags\n" +
    "     to find the latest stable tag when the repo uses explicit release tags\n" +
    "  6. For versioned-folder repos, apply rule 4 first (named > date), then\n" +
    "     pick the highest within the winning type\n" +
    "  7. The returned URL must resolve to the spec at that stable version —\n" +
    "     never return a URL that might point to work-in-progress content\n" +
    "\n" +
    "## File selection preferences\n" +
    "  - Prefer highest OpenAPI/Swagger version (3.1.0 > 3.0.0 > 2.0)\n" +
    "  - Prefer YAML over JSON at the same version\n" +
    "  - Prefer the latest stable release tag over the default branch when the repo\n" +
    "    uses explicit versioned releases; prefer default branch otherwise\n" +
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
    "Only raw download URLs. Never github.com/blob/ links. No other text.\n" +
    "IMPORTANT: List official vendor URLs BEFORE any APIs-guru URLs.";

public function stepDiscovery(
    string docsUrl,
    string apiName,
    string? targetTitle,
    string anthropicKey,
    string? knownSpecRepo
) returns DiscoveryResult {

    log:printInfo(string `  [step3] starting discovery for: ${apiName}`);

    string targetNote = targetTitle is string
        ? string `\nTarget: find ONLY the spec titled '${targetTitle}'.`
        : "";

    string repoHint = knownSpecRepo is string
        ? string `\nKnown GitHub repo: ${knownSpecRepo} — start here with Contents API.`
        : "";

    string userMsg = string `Find the OpenAPI spec download URL for: ${apiName}
Docs URL: ${docsUrl}${targetNote}${repoHint}

STRICT PRIORITY ORDER:
1. ALWAYS fetch the docs URL first — it often has a direct download link or an embedded spec URL.
   If the docs page contains ANY URL ending in .yaml/.json or containing 'openapi'/'swagger', that is the official spec — return it immediately.
2. Only if docs page is empty/useless → check the vendor's official GitHub repo.
3. ONLY as an absolute last resort, after docs page AND vendor GitHub have both failed → check APIs-guru.
   Never jump to APIs-guru early. Official vendor sources are always preferred.

Return DISCOVERY_RESULT with raw download URLs only. List official vendor URLs before any APIs-guru URLs.`;

    json[] messages = [{"role": "user", "content": userMsg}];
    map<boolean> fetched = {};
    string model = os:getEnv("CLAUDE_MODEL");
    if model.length() == 0 { model = "claude-sonnet-4-6"; }

    int maxTurns = 10;
    int turn = 0;

    while turn < maxTurns {
        turn += 1;
        log:printInfo(string `  [step3 turn ${turn}/${maxTurns}]`);

        json|error resp = callClaude(anthropicKey, model, messages, DISCOVERY_SYSTEM_PROMPT);
        if resp is error {
            log:printWarn(string `  [step3] Claude API error: ${resp.message()}`);
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
                    "IMPORTANT: Have you checked the docs page AND the vendor's official GitHub repo?\n" +
                    "If not, do that first — official vendor sources must be tried before APIs-guru.\n" +
                    "Only fall back to APIs-guru if both the docs page and vendor GitHub have been tried and yielded nothing.\n" +
                    "Return whatever official URLs you found, even if you are not 100% certain they are specs.\n" +
                    "APIs-guru is acceptable ONLY as a last resort when all official sources are exhausted."
            });
            continue;
        }

        log:printWarn(string `  [step3] unexpected stop_reason='${stopReason}' at turn ${turn} — aborting`);
        break;
    }

    log:printWarn(string `  [step3] exhausted ${maxTurns} turns without a result`);
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
// For very large files (Content-Length > 5MB from HEAD response), we skip
// the content download and trust the HEAD check — these are known-large specs
// like Microsoft Graph (~300MB) or Stripe (~14MB) where downloading even
// 100KB can hang due to slow initial connection on oversized files.

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

        // HEAD check — optional fast pre-filter.
        // raw.githubusercontent.com does not reliably support HEAD; if HEAD fails
        // we still proceed to content fetch rather than skipping the URL.
        boolean headPassed = headOk(url);
        if headPassed {
            // Check Content-Length from HEAD to detect very large files.
            // For files > 5MB, skip content fetch and trust HEAD — downloading
            // even a small slice of a 300MB file (e.g. Microsoft Graph) can hang.
            int contentLength = getContentLength(url);
            if contentLength > 5000000 {
                log:printInfo(string `  [step4] large file (${contentLength} bytes) — skipping content fetch, trusting HEAD`);
                string fmt = url.toLowerAscii().endsWith(".json") ? "json" : "yaml";
                log:printInfo(string `  [step4] assumed valid (large known spec): ${url}`);
                return {
                    specUrl: url,
                    specRepo: discovery.specRepo,
                    title: (),
                    apiVersion: (),
                    format: fmt
                };
            }
        } else {
            log:printInfo("  [step4] HEAD failed — trying content fetch anyway");
        }

        // For normal-sized files, fetch 100KB and verify content
        string|error body = httpGetBodyPartial(url, 100000);
        if body is error {
            log:printWarn(string `  [step4] content fetch failed for ${url}: ${body.message()}`);
            continue;
        }

        if !looksLikeSpec(body) {
            log:printWarn(string `  [step4] content at ${url} is not a valid OpenAPI/Swagger spec — skipping`);
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

    log:printWarn(string `  [step4] all ${discovery.candidateUrls.length()} candidate(s) failed verification`);
    return ();
}

// Returns the Content-Length of a URL from a HEAD request, or 0 if unavailable.
function getContentLength(string url) returns int {
    do {
        string ghToken = os:getEnv("GITHUB_TOKEN");
        map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
        if (url.includes("api.github.com") || url.includes("raw.githubusercontent.com")) && ghToken.length() > 0 {
            headers["Authorization"] = string `Bearer ${ghToken}`;
        }
        http:Client cl = check new (url, {
            followRedirects: {enabled: true, maxCount: 5},
            timeout: 10,
            secureSocket: {enable: true}
        });
        http:Response r = check cl->head("", headers);
        if r.statusCode == 200 {
            string clHeader = check r.getHeader("content-length");
            int|error parsed = int:fromString(clHeader);
            if parsed is int { return parsed; }
        }
    } on fail {
        // Content-Length not available — return 0 (proceed with content fetch)
    }
    return 0;
}

// ─── Spec content detection ───────────────────────────────────────────────────

isolated function looksLikeSpec(string content) returns boolean {
    string t = content.trim();
    if t.startsWith("openapi:") { return true; }
    if t.startsWith("swagger:") { return true; }
    if t.includes("\"openapi\"") { return true; }
    if t.includes("\"swagger\"") { return true; }
    if t.includes("\nopenapi:") { return true; }
    if t.includes("\nswagger:") { return true; }
    if t.startsWith("components:") { return true; }
    string head = t.length() > 300 ? t.substring(0, 300) : t;
    if t.startsWith("{") && head.includes("\"components\"") { return true; }
    return false;
}

// ─── Shared HTTP helpers ──────────────────────────────────────────────────────

// Converts a raw.githubusercontent.com URL to a GitHub Contents API URL.
// raw.githubusercontent.com is unreliable for direct HTTP in this environment;
// the Contents API (which we know works) with Accept: application/vnd.github.raw
// returns the same raw file content.
//
// https://raw.githubusercontent.com/OWNER/REPO/BRANCH/path/to/file
// → https://api.github.com/repos/OWNER/REPO/contents/path/to/file?ref=BRANCH
isolated function rawUrlToApiUrl(string rawUrl) returns string {
    string prefix = "raw.githubusercontent.com/";
    int? pi = rawUrl.indexOf(prefix);
    if pi is () { return rawUrl; }
    string rest = rawUrl.substring(pi + prefix.length());

    int? s1 = rest.indexOf("/");
    if s1 is () { return rawUrl; }
    string owner = rest.substring(0, s1);
    string rem1 = rest.substring(s1 + 1);

    int? s2 = rem1.indexOf("/");
    if s2 is () { return rawUrl; }
    string repo = rem1.substring(0, s2);
    string rem2 = rem1.substring(s2 + 1);

    int? s3 = rem2.indexOf("/");
    if s3 is () { return rawUrl; }
    string branch = rem2.substring(0, s3);
    string path = rem2.substring(s3 + 1);

    return string `https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${branch}`;
}

function httpGetBodyPartial(string url, int maxBytes) returns string|error {
    string ghToken = os:getEnv("GITHUB_TOKEN");
    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};

    // raw.githubusercontent.com is unreliable for direct HTTP in this env.
    // Convert to the GitHub Contents API and request raw content via Accept header.
    string fetchUrl = url;
    if url.includes("raw.githubusercontent.com/") {
        fetchUrl = rawUrlToApiUrl(url);
        headers["Accept"] = "application/vnd.github.raw";
    }

    if (fetchUrl.includes("api.github.com") || url.includes("raw.githubusercontent.com")) && ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

    decimal timeoutSecs = 20;

    http:Client cl = check new (fetchUrl, {
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
