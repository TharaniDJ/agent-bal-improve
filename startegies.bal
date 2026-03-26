// strategies.bal
// Search strategies for the OpenAPI Spec Finder agent.
//
// Strategy order (stops at first success):
//   1. memory  — re-validate last known URL (fast path for daily runs)
//   2. agent   — agentic LLM loop with fetch_page tool use
//
// The agent (strategy 2) is the real intelligence:
//   - Gets the docs URL and a detailed reasoning prompt
//   - Uses fetch_page tool to navigate pages
//   - Reasons step-by-step: docs page → GitHub repo → raw file URL
//   - Outputs SPEC_CANDIDATES when confident
//   - Validation (validator.bal) is always programmatic — LLM only finds candidates

import ballerina/http;
import ballerina/log;

// ===========================================================================
// Strategy — Agentic LLM with fetch_page tool use
// This is the only strategy. It always runs on every execution.
// Memory context (lastKnownVersion) is passed in from agent.bal.
// ===========================================================================

// ---------------------------------------------------------------------------
// System prompt
// This is the core prompt engineering.
// The agent must reason carefully and use the tool to navigate to the spec.
// ---------------------------------------------------------------------------

const string AGENT_SYSTEM =
    "You are an expert at finding the MOST RECENTLY UPDATED OpenAPI specification\n" +
    "file for REST APIs. This runs as a daily job — your goal is to always return\n" +
    "the latest published version of the spec, not just any version.\n" +
    "\n" +
    "You have one tool: fetch_page. Use it to navigate the web.\n" +
    "\n" +
    "## Goal\n" +
    "Find the direct download URL of the LATEST official OpenAPI or Swagger spec\n" +
    "file for the given API. The file must be:\n" +
    "  - Publicly accessible without authentication\n" +
    "  - A raw downloadable JSON or YAML file\n" +
    "  - The most recently updated version (not an old or archived version)\n" +
    "  - Contains a root key of 'openapi' or 'swagger'\n" +
    "\n" +
    "## How to find it — follow this reasoning\n" +
    "\n" +
    "STEP 1 — Read the official docs page.\n" +
    "Fetch the given documentation URL. Carefully read the page text and ALL links.\n" +
    "Look for:\n" +
    "  - Any link with: openapi, swagger, .yaml, .yml, .json, spec, defs,\n" +
    "    raw.githubusercontent, download\n" +
    "  - Text like: 'OpenAPI', 'Swagger', 'Download spec', 'API spec', 'REST API spec'\n" +
    "  - Links to GitHub repositories (github.com/owner/repo)\n" +
    "  - Links to API catalog endpoints (e.g. api.hubspot.com/public/api/spec/v1/specs)\n" +
    "  - Any mention of where the spec is hosted\n" +
    "\n" +
    "STEP 2 — If you find a direct raw spec URL, output it immediately.\n" +
    "A direct raw URL looks like:\n" +
    "  https://raw.githubusercontent.com/owner/repo/branch/path/openapi.yaml\n" +
    "  https://someapi.com/openapi.json\n" +
    "Do not keep searching if you already have a direct download link.\n" +
    "\n" +
    "STEP 3 — If you find a GitHub repository link, use the GitHub API.\n" +
    "DO NOT fetch github.com/owner/repo/tree or /blob pages — they are HTML, not files.\n" +
    "Instead, list all files via the GitHub API:\n" +
    "  https://api.github.com/repos/OWNER/REPO/git/trees/HEAD?recursive=1\n" +
    "From the file list, find files whose name contains 'openapi' or 'swagger'\n" +
    "and ends in .yaml, .yml, or .json.\n" +
    "Then construct the raw download URL:\n" +
    "  https://raw.githubusercontent.com/OWNER/REPO/BRANCH/path/to/file.yaml\n" +
    "Try branch 'main' first, then 'master'.\n" +
    "If there are multiple spec files, pick the one with the highest version number\n" +
    "in its filename (e.g. v2.1 > v2) or the one in the root/main directory.\n" +
    "\n" +
    "STEP 4 — If the page links to an API catalog endpoint, fetch it.\n" +
    "Some APIs (like HubSpot) serve specs through a catalog API, for example:\n" +
    "  https://api.hubspot.com/public/api/spec/v1/specs\n" +
    "Fetch this URL. The JSON response will list available specs with download URLs.\n" +
    "Find the entry matching the API name and return its download URL.\n" +
    "\n" +
    "STEP 5 — Always return the most current version available.\n" +
    "If multiple versioned files exist:\n" +
    "  - Pick the highest version number (3.1 > 3.0 > 2.0, v2.1 > v2)\n" +
    "  - Prefer YAML over JSON at the same version\n" +
    "  - If a GitHub repo has a releases page, check it for the latest tag\n" +
    "  - If a GitHub repo has a default branch (main/master), that is usually\n" +
    "    the most current — prefer it over older tagged releases\n" +
    "  - IMPORTANT: Even if you were given a 'last known version', you must\n" +
    "    still check what the current latest version is. Do not assume the\n" +
    "    last known version is still the latest. Always verify.\n" +
    "\n" +
    "## Efficiency rules\n" +
    "  - Use at most 5 fetch_page calls total — plan them carefully\n" +
    "  - Never fetch the same URL twice\n" +
    "  - Stop and output as soon as you have a confident URL\n" +
    "  - github.com/tree and github.com/blob pages are HTML — never fetch them\n" +
    "    Use api.github.com instead\n" +
    "\n" +
    "## Output format — when you have found the spec\n" +
    "Output ONLY this block. No other text before or after:\n" +
    "\n" +
    "SPEC_CANDIDATES:\n" +
    "<url1>\n" +
    "<url2>\n" +
    "\n" +
    "Important:\n" +
    "  - Only raw download URLs — never github.com/blob/ URLs\n" +
    "  - List URLs one per line, most likely first\n" +
    "  - Include alternative branches (main/master) as fallback candidates\n" +
    "\n" +
    "## Output format — if no public spec exists\n" +
    "NO_SPEC_FOUND\n";

// ---------------------------------------------------------------------------
// fetch_page tool definition
// ---------------------------------------------------------------------------

final json FETCH_PAGE_TOOL = {
    "name": "fetch_page",
    "description": "Fetches a URL and returns its content. For HTML pages, returns page text and all links. For JSON/YAML files, returns the content directly. Do NOT use this to fetch github.com/tree or github.com/blob pages — use the GitHub API endpoint (api.github.com/repos/.../git/trees/HEAD?recursive=1) to list repo files instead.",
    "input_schema": {
        "type": "object",
        "properties": {
            "url": {
                "type": "string",
                "description": "The full URL to fetch"
            }
        },
        "required": ["url"]
    }
};

// ---------------------------------------------------------------------------
// Tool execution — runs when the LLM calls fetch_page
// ---------------------------------------------------------------------------

function executeFetchPage(string url) returns string {
    log:printInfo(string `    [fetch] ${url}`);

    FetchResult|error fr = httpGet(url);
    if fr is error {
        log:printInfo(string `      error: ${fr.message()}`);
        return string `{"error":"fetch failed: ${fr.message()}"}`;
    }
    if fr.status != 200 {
        log:printInfo(string `      HTTP ${fr.status}`);
        return string `{"error":"HTTP ${fr.status}"}`;
    }

    string ct = fr.contentType.toLowerAscii();
    string lo = url.toLowerAscii();

    // JSON or YAML — return content directly (truncated to save tokens)
    if ct.includes("json") || lo.endsWith(".json") {
        string body = fr.body.length() > 40000 ? fr.body.substring(0, 40000) : fr.body;
        return string `{"type":"json","content":${jsonEscape(body)}}`;
    }
    if ct.includes("yaml") || lo.endsWith(".yaml") || lo.endsWith(".yml") {
        string body = fr.body.length() > 40000 ? fr.body.substring(0, 40000) : fr.body;
        return string `{"type":"yaml","content":${jsonEscape(body)}}`;
    }

    // HTML — strip tags, extract links, return structured result
    string pageText = htmlToText(fr.body);
    string[] links = extractAllLinks(fr.body, url);

    string linksArr = buildJsonStringArray(links);
    string textTrunc = pageText.length() > 8000 ? pageText.substring(0, 8000) : pageText;

    return string `{"type":"html","url":${jsonEscape(url)},"text":${jsonEscape(textTrunc)},"links":${linksArr}}`;
}

// Strip HTML tags and collapse whitespace
isolated function htmlToText(string html) returns string {
    string result = "";
    boolean inTag = false;
    boolean lastWasSpace = false;
    foreach string ch in html {
        if ch == "<"  { inTag = true;  continue; }
        if ch == ">"  { inTag = false; continue; }
        if inTag { continue; }
        boolean isSpace = ch == " " || ch == "\n" || ch == "\t" || ch == "\r";
        if isSpace {
            if !lastWasSpace { result += " "; lastWasSpace = true; }
        } else {
            result += ch;
            lastWasSpace = false;
        }
    }
    return result.trim();
}

// Extract all href values, resolve to absolute URLs
isolated function extractAllLinks(string html, string baseUrl) returns string[] {
    string[] links = [];
    map<boolean> seen = {};
    string remaining = html;
    while remaining.length() > 0 && links.length() < 300 {
        string loRemain = remaining.toLowerAscii();
        int? hIdx = loRemain.indexOf("href=");
        if hIdx is () { break; }
        int after = hIdx + 5;
        if after >= remaining.length() { break; }
        string q = remaining.substring(after, after + 1);
        if q != "\"" && q != "'" { remaining = remaining.substring(after); continue; }
        int beginIdx = after + 1;
        if beginIdx >= remaining.length() { break; }

        string tail = remaining.substring(beginIdx);
        int? relCloseIdx = tail.indexOf(q);
        if relCloseIdx is () { remaining = remaining.substring(after); continue; }

        int closeIdx = beginIdx + relCloseIdx;
        string href = remaining.substring(beginIdx, closeIdx);
        remaining = remaining.substring(closeIdx + 1);
        string full = resolveUrl(href, baseUrl);
        if full.length() > 0 && !seen.hasKey(full) {
            seen[full] = true;
            links.push(full);
        }
    }
    return links;
}

isolated function resolveUrl(string href, string base) returns string {
    if href.length() == 0 { return ""; }
    if href.startsWith("http://") || href.startsWith("https://") { return href; }
    if href.startsWith("//") {
        string[] p = splitOnChar(base, "://");
        return p.length() > 0 ? p[0] + ":" + href : "https:" + href;
    }
    if href.startsWith("/") { return extractOrigin(base) + href; }
    if href.startsWith("#") || href.startsWith("javascript") || href.startsWith("mailto") {
        return "";
    }
    return extractDir(base) + href;
}

isolated function extractOrigin(string url) returns string {
    string[] p = splitOnChar(url, "://");
    if p.length() < 2 { return ""; }
    int? si = p[1].indexOf("/");
    return si is int ? p[0] + "://" + p[1].substring(0, si) : p[0] + "://" + p[1];
}

isolated function extractDir(string url) returns string {
    int i = url.length() - 1;
    while i >= 0 { if url[i] == "/" { return url.substring(0, i + 1); } i -= 1; }
    return url + "/";
}

// Escape a string for embedding inside a JSON value
isolated function jsonEscape(string s) returns string {
    string result = "\"";
    foreach string ch in s {
        if ch == "\\" { result += "\\\\"; }
        else if ch == "\"" { result += "\\\""; }
        else if ch == "\n" { result += "\\n"; }
        else if ch == "\r" { result += "\\r"; }
        else if ch == "\t" { result += "\\t"; }
        else { result += ch; }
    }
    result += "\"";
    return result;
}

// Build a JSON array of strings
isolated function buildJsonStringArray(string[] items) returns string {
    string result = "[";
    boolean first = true;
    foreach string item in items {
        if !first { result += ","; }
        result += jsonEscape(item);
        first = false;
    }
    result += "]";
    return result;
}

// ---------------------------------------------------------------------------
// Parse SPEC_CANDIDATES from agent output
// ---------------------------------------------------------------------------

isolated function parseCandidates(string text) returns string[] {
    string[] results = [];
    int? idx = text.indexOf("SPEC_CANDIDATES:");
    if idx is () { return results; }
    string after = text.substring(idx + 16);
    foreach string line in splitOnChar(after, "\n") {
        string t = line.trim();
        if startsWithHttp(t) {
            results.push(blobToRaw(t));
        }
    }
    return results;
}

// ---------------------------------------------------------------------------
// Main agent loop
// ---------------------------------------------------------------------------

public function strategyAgent(
    string docsUrl,
    string apiName,
    string? targetTitle,
    string apiKey,
    string? lastKnownVersion = ()
) returns ValidatedCandidate? {
    if apiKey.length() == 0 {
        log:printInfo("  [agent] ANTHROPIC_API_KEY not set — skipping");
        return ();
    }

    // Build context notes for the user message
    string targetNote = targetTitle is string
        ? string `\n\nThis docs page hosts multiple API specs. You must find specifically the one titled '${targetTitle}'. Ignore all other specs on the page.`
        : "";

    string versionNote = lastKnownVersion is string
        ? string `\n\nContext from previous run: The last time this ran, version '${lastKnownVersion}' was found. Your job today is to check whether a newer version has been published since then. If '${lastKnownVersion}' is still the latest, return it. If a newer version exists, return that instead. Always verify — do not assume the last known version is still current.`
        : "\n\nContext: This is the first run for this API. Find the latest published version of the spec.";

    string userMessage = string `Find the most recently updated OpenAPI specification file for the '${apiName}' API.

Official documentation URL: ${docsUrl}${targetNote}${versionNote}

Instructions:
1. Fetch the documentation URL above first.
2. Follow the reasoning steps in your instructions to locate the spec file.
3. Output SPEC_CANDIDATES: as soon as you have found the URL(s).`;

    log:printInfo(string `  [agent] starting for: ${apiName}${lastKnownVersion is string ? string ` (last known version: ${lastKnownVersion})` : " (first run)"}`);

    json[] messages = [{"role": "user", "content": userMessage}];
    map<boolean> fetchedUrls = {};
    int iteration = 0;
    string? candidatesText = ();

    while iteration < 6 {
        iteration += 1;
        log:printInfo(string `  [agent] iteration ${iteration}/6`);

        json|error apiResponse = callAnthropicWithTools(apiKey, messages);
        if apiResponse is error {
            log:printInfo(string `  [agent] API error: ${apiResponse.message()}`);
            break;
        }

        string stopReason = "";
        json[] contentBlocks = [];
        if apiResponse is map<json> {
            json? sr = apiResponse["stop_reason"];
            if sr is string { stopReason = sr; }
            json? cb = apiResponse["content"];
            if cb is json[] { contentBlocks = cb; }
        }

        log:printInfo(string `  [agent] stop_reason=${stopReason}`);

        // Collect text blocks and tool_use blocks
        string agentText = "";
        json[] toolUseBlocks = [];
        foreach json block in contentBlocks {
            if block is map<json> {
                json? bt = block["type"];
                if bt is string {
                    if bt == "text" {
                        json? tv = block["text"];
                        if tv is string { agentText += tv; }
                    } else if bt == "tool_use" {
                        toolUseBlocks.push(block);
                    }
                }
            }
        }

        if agentText.length() > 0 {
            string preview = agentText.length() > 400 ? agentText.substring(0, 400) + "..." : agentText;
            log:printInfo(string `  [agent] says: ${preview}`);
        }

        // Check terminal outputs
        if agentText.includes("SPEC_CANDIDATES:") {
            candidatesText = agentText;
            break;
        }
        if agentText.includes("NO_SPEC_FOUND") {
            log:printInfo("  [agent] no spec found");
            break;
        }

        // Handle tool use
        if stopReason == "tool_use" && toolUseBlocks.length() > 0 {
            messages.push({"role": "assistant", "content": contentBlocks});
            json[] toolResults = [];
            foreach json tb in toolUseBlocks {
                if tb is map<json> {
                    string toolId = "";
                    json? tid = tb["id"];
                    if tid is string { toolId = tid; }

                    string toolOutput = "{\"error\": \"invalid tool call\"}";
                    json? ti = tb["input"];
                    if ti is map<json> {
                        json? urlVal = ti["url"];
                        if urlVal is string {
                            if fetchedUrls.hasKey(urlVal) {
                                toolOutput = "{\"error\": \"already fetched — try a different URL\"}";
                            } else {
                                fetchedUrls[urlVal] = true;
                                toolOutput = executeFetchPage(urlVal);
                            }
                        }
                    }

                    toolResults.push({
                        "type": "tool_result",
                        "tool_use_id": toolId,
                        "content": toolOutput
                    });
                }
            }
            messages.push({"role": "user", "content": toolResults});
            continue;
        }

        // end_turn without candidates — nudge the agent to conclude
        if stopReason == "end_turn" {
            messages.push({"role": "assistant", "content": contentBlocks});
            messages.push({
                "role": "user",
                "content": "Please output your result now — either SPEC_CANDIDATES: followed by the URLs you found, or NO_SPEC_FOUND."
            });
            continue;
        }

        break;
    }

    if candidatesText is string {
        string[] candidates = parseCandidates(candidatesText);
        log:printInfo(string `  [agent] ${candidates.length()} candidate(s) to validate`);
        if candidates.length() == 0 { return (); }
        ValidatedCandidate? result = bestResult(candidates);
        if result is ValidatedCandidate {
            log:printInfo(string `  [agent] validated: ${result.url}`);
        }
        return result;
    }

    return ();
}

// ---------------------------------------------------------------------------
// Anthropic API call
// ---------------------------------------------------------------------------

function callAnthropicWithTools(string apiKey, json[] messages) returns json|error {
    http:Client cl = check new ("https://api.anthropic.com", {
        timeout: 120,
        secureSocket: {enable: true}
    });

    json requestBody = {
        "model": "claude-sonnet-4-20250514",
        "max_tokens": 1024,
        "system": AGENT_SYSTEM,
        "tools": [FETCH_PAGE_TOOL],
        "messages": messages
    };

    http:Response resp = check cl->post(
        "/v1/messages",
        requestBody,
        {
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json"
        }
    );

    if resp.statusCode != 200 {
        string errBody = check resp.getTextPayload();
        int previewLen = errBody.length() > 300 ? 300 : errBody.length();
        return error(string `Anthropic HTTP ${resp.statusCode}: ${errBody.substring(0, previewLen)}`);
    }

    return check resp.getJsonPayload();
}
