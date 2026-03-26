// agent.bal
// Agentic OpenAPI spec finder powered by Claude.
//
// The agent uses Claude's tool-use capability with a single `fetch_page` tool.
// Claude navigates from the docs URL to the actual raw spec file URL.
// Ballerina then does a fast HEAD check to confirm the URL is reachable.
//
// Design choices:
//   - Claude fetches and *reads* the spec content in its loop — so by the time
//     it outputs SPEC_CANDIDATES the URL is already confirmed to contain a spec.
//   - Ballerina only does a HEAD check (no full download). No validator needed.
//   - No memory / caching — every run is fresh so we always find the latest.

import ballerina/http;
import ballerina/io;
import ballerina/log;
import ballerina/os;

// ─── System prompt ────────────────────────────────────────────────────────────
//
// This is the core of the agent. It tells Claude exactly:
//   1. What it is looking for
//   2. What tool it has
//   3. Step-by-step how to navigate
//   4. API-specific shortcuts for each known connector
//   5. How to output results

const string SYSTEM_PROMPT = "You are an expert at locating the LATEST official OpenAPI (or Swagger) " +
    "specification file for REST APIs.\n" +
    "\n" +
    "## What you need to find\n" +
    "A publicly accessible, directly downloadable YAML or JSON file whose first " +
    "meaningful content starts with `openapi:` (e.g. `openapi: 3.1.0`) or `swagger:` " +
    "(e.g. `swagger: '2.0'`). It must be the LATEST published version.\n" +
    "\n" +
    "## Your tool: fetch_page\n" +
    "Use it to retrieve any URL. It returns:\n" +
    "  - HTML pages  → { spec_links, page_text, other_links }\n" +
    "  - JSON files  → { type:'json', content:'...' }  (first 12 KB)\n" +
    "  - YAML files  → { type:'yaml', content:'...' }  (first 12 KB)\n" +
    "\n" +
    "Hard rules:\n" +
    "  - Max 6 fetch_page calls total. Plan carefully.\n" +
    "  - NEVER fetch the same URL twice.\n" +
    "  - NEVER fetch github.com/blob or github.com/tree URLs (HTML wrappers).\n" +
    "    To list files in a GitHub repo always use:\n" +
    "      https://api.github.com/repos/OWNER/REPO/git/trees/HEAD?recursive=1\n" +
    "\n" +
    "## Strategy\n" +
    "\n" +
    "### STEP 0 — Check the previously found URL first (if provided)\n" +
    "If the user message includes a 'Previously found URL', fetch it FIRST.\n" +
    "  - If it responds with valid spec content (starts with `openapi:` or `swagger:`) → output it immediately.\n" +
    "  - If it fails (404 / wrong content) → the spec moved; continue to STEP 1 to find the new location.\n" +
    "This saves fetches when the URL hasn't changed since last run.\n" +
    "\n" +
    "### STEP 1 — Use API-specific knowledge (for known APIs)\n" +
    "Go directly to the known location. Skip the docs page unless the known location fails.\n" +
    "\n" +
    "  GitHub REST API\n" +
    "    Known URL: https://raw.githubusercontent.com/github/rest-api-description/main/descriptions/api.github.com/api.github.com.yaml\n" +
    "    Fetch it. If it starts with `openapi:` → output immediately.\n" +
    "\n" +
    "  Asana\n" +
    "    Repo tree: https://api.github.com/repos/Asana/openapi/git/trees/HEAD?recursive=1\n" +
    "    Look for files under defs/ ending in .yaml → build raw URL with branch 'master'.\n" +
    "\n" +
    "  DocuSign Admin API, DocuSign Click API, DocuSign eSign API\n" +
    "    ALL DocuSign specs live in ONE repo: https://github.com/docusign/OpenAPI-Specifications\n" +
    "    Fetch the tree: https://api.github.com/repos/docusign/OpenAPI-Specifications/git/trees/HEAD?recursive=1\n" +
    "    The files are at the repo root. Find the correct file by API name:\n" +
    "      Admin API  → file containing 'admin'   (e.g. admin.rest.swagger-v2.1.json)\n" +
    "      Click API  → file containing 'click'   (e.g. click.rest.swagger-v2.json)\n" +
    "      eSign API  → file containing 'esign' or 'esignature' (e.g. esignature.rest.swagger-v2.1.json)\n" +
    "    Build raw URL: https://raw.githubusercontent.com/docusign/OpenAPI-Specifications/master/FILENAME\n" +
    "    Fetch the file to verify it has `swagger:` or `openapi:` content.\n" +
    "\n" +
    "  Candid (CharityCheckPdf, Essentials, Premier API)\n" +
    "    Fetch: https://developer.candid.org/openapi\n" +
    "    Page lists multiple specs with links like /openapi/<id>.\n" +
    "    Fetch the link whose surrounding text matches the target title exactly.\n" +
    "    Verify the fetched content has `\"title\"` matching the target.\n" +
    "\n" +
    "  Discord\n" +
    "    Repo tree: https://api.github.com/repos/discord/discord-api-spec/git/trees/HEAD?recursive=1\n" +
    "    Look for openapi.json or openapi.yaml in /specs/ → build raw URL with branch 'main'.\n" +
    "\n" +
    "### STEP 2 — Fall back: fetch the docs page\n" +
    "  1. Scan spec_links for: raw.githubusercontent.com, .yaml, .yml, github.com/OWNER/REPO, openapi, swagger\n" +
    "  2. GitHub repo link → use the API tree (never the HTML page)\n" +
    "  3. Direct file URL → fetch to verify content\n" +
    "  4. Internal reference/download link → follow it\n" +
    "\n" +
    "### STEP 3 — Always verify before outputting\n" +
    "Fetch the candidate URL. Confirm it starts with `openapi:` or `swagger:` (or `\"openapi\":` for JSON).\n" +
    "Only output SPEC_CANDIDATES after you have seen and confirmed the file content.\n" +
    "\n" +
    "## Selecting the best when multiple exist\n" +
    "  - Highest version (3.1 > 3.0 > 2.0)\n" +
    "  - YAML preferred over JSON\n" +
    "  - main/master branch preferred over release tags\n" +
    "\n" +
    "## Output format — ONLY these two options, no other text\n" +
    "\n" +
    "Found:\n" +
    "SPEC_CANDIDATES:\n" +
    "https://primary-url\n" +
    "https://alternate-branch-url\n" +
    "\n" +
    "Not found:\n" +
    "NO_SPEC_FOUND\n" +
    "\n" +
    "Rules: raw download URLs only (never github.com/blob/), include main+master variants for GitHub raw URLs.\n";

// ─── Tool definition ─────────────────────────────────────────────────────────

final json FETCH_PAGE_TOOL = {
    "name": "fetch_page",
    "description":
        "Fetches a URL and returns its content. " +
        "HTML → {spec_links, page_text, other_links}. " +
        "JSON/YAML → {type, content} with up to 12 KB of file content. " +
        "Never fetch github.com/blob or github.com/tree pages. " +
        "Use api.github.com/repos/OWNER/REPO/git/trees/HEAD?recursive=1 to list repo files.",
    "input_schema": {
        "type": "object",
        "properties": {
            "url": {"type": "string", "description": "Full URL to fetch (https://...)"}
        },
        "required": ["url"]
    }
};

// ─── fetch_page tool handler ─────────────────────────────────────────────────

function executeFetchPage(string url) returns string {
    log:printInfo(string `    [fetch] ${url}`);

    string|error body = httpGetBody(url);
    if body is error {
        log:printInfo(string `      error: ${body.message()}`);
        return string `{"error":"fetch failed: ${jsonEsc(body.message())}"}`;
    }

    // Detect content type from URL extension
    string lo = url.toLowerAscii();

    // YAML — return first 12 KB
    if lo.endsWith(".yaml") || lo.endsWith(".yml") {
        string snippet = body.length() > 12000 ? body.substring(0, 12000) : body;
        return string `{"type":"yaml","content":${jsonStr(snippet)}}`;
    }

    // JSON — return first 12 KB (covers GitHub API tree responses fully for most repos)
    if lo.endsWith(".json") || lo.includes("api.github.com") || lo.includes("application/json") {
        string snippet = body.length() > 12000 ? body.substring(0, 12000) : body;
        return string `{"type":"json","content":${jsonStr(snippet)}}`;
    }

    // Detect by content if extension is ambiguous
    string trimmed = body.trim();
    if trimmed.startsWith("openapi:") || trimmed.startsWith("swagger:") || trimmed.startsWith("---") {
        string snippet = body.length() > 12000 ? body.substring(0, 12000) : body;
        return string `{"type":"yaml","content":${jsonStr(snippet)}}`;
    }
    if trimmed.startsWith("{") || trimmed.startsWith("[") {
        string snippet = body.length() > 12000 ? body.substring(0, 12000) : body;
        return string `{"type":"json","content":${jsonStr(snippet)}}`;
    }

    // HTML — extract links and text
    string[] specLinks = [];
    string[] otherLinks = [];
    string[] allLinks = extractHrefs(body, url);

    foreach string lnk in allLinks {
        if isSpecLink(lnk) {
            specLinks.push(lnk);
        } else {
            otherLinks.push(lnk);
        }
    }

    string txt = htmlText(body);
    string txtSnippet = txt.length() > 3000 ? txt.substring(0, 3000) : txt;

    return string `{"type":"html","spec_links":${jsonArr(specLinks)},"page_text":${jsonStr(txtSnippet)},"other_links":${jsonArr(otherLinks.length() > 60 ? otherLinks.slice(0, 60) : otherLinks)}}`;
}

// ─── Agent loop ───────────────────────────────────────────────────────────────

public function runAgent(
    string docsUrl,
    string apiName,
    string? targetTitle,
    string anthropicKey,
    string? knownSpecUrl = ()   // previously found URL; agent verifies it first
) returns SpecResult? {

    if anthropicKey.length() == 0 {
        io:println("  ERROR: ANTHROPIC_API_KEY not set");
        return ();
    }

    string targetNote = targetTitle is string
        ? string `\n\nIMPORTANT — This page has multiple specs. Find ONLY the one titled '${targetTitle}'. Do not return any other spec.`
        : "";

    // Tell the agent about the previously found URL so it can verify it first (STEP 0).
    // This saves fetches when the location hasn't changed.
    string memoryNote = knownSpecUrl is string
        ? string `\n\nPreviously found URL: ${knownSpecUrl}\nStart by fetching this URL (STEP 0). If it is still a valid spec, return it immediately. If it fails or has moved, search for the new location.`
        : "";

    string userMsg = string `Find the latest OpenAPI spec file URL for the '${apiName}' API.
Docs URL: ${docsUrl}${targetNote}${memoryNote}

Follow the strategy in your instructions. Verify content before outputting SPEC_CANDIDATES.`;

    json[] messages = [{"role": "user", "content": userMsg}];
    map<boolean> fetched = {};
    string model = os:getEnv("CLAUDE_MODEL");
    if model.length() == 0 { model = "claude-sonnet-4-6"; }

    int turn = 0;
    while turn < 10 {
        turn += 1;
        log:printInfo(string `  [turn ${turn}]`);

        json|error resp = callClaude(anthropicKey, model, messages);
        if resp is error {
            log:printInfo(string `  [claude error] ${resp.message()}`);
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

        // Separate text and tool_use blocks
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
            int preview = text.length() > 600 ? 600 : text.length();
            log:printInfo(string `  [claude] ${text.substring(0, preview)}${text.length() > 600 ? "..." : ""}`);
        }

        // Done — found candidates
        if text.includes("SPEC_CANDIDATES:") {
            return pickBestCandidate(text);
        }
        if text.includes("NO_SPEC_FOUND") {
            log:printInfo("  [claude] declared no spec found");
            return ();
        }

        // Tool use turn
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
                                output = "{\"error\":\"already fetched this URL\"}";
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

        // end_turn without candidates — nudge once
        if stopReason == "end_turn" && turn < 9 {
            messages.push({"role": "assistant", "content": blocks});
            messages.push({
                "role": "user",
                "content": "Output your result now: SPEC_CANDIDATES: followed by the URL(s) you found, or NO_SPEC_FOUND."
            });
            continue;
        }

        break;
    }

    return ();
}

// Parse SPEC_CANDIDATES block, HEAD-check each URL, return first that's alive
function pickBestCandidate(string text) returns SpecResult? {
    int? idx = text.indexOf("SPEC_CANDIDATES:");
    if idx is () { return (); }
    string after = text.substring(idx + 16);

    string[] urls = [];
    map<boolean> seen = {};

    foreach string line in splitLines(after) {
        string t = line.trim();
        if !t.startsWith("http") { continue; }

        // Convert blob URLs to raw
        string url = t;
        if url.includes("github.com/") && url.includes("/blob/") {
            url = "https://raw.githubusercontent.com/" + url.substring(19);
            int? blobIdx = url.indexOf("/blob/");
            if blobIdx is int {
                url = url.substring(0, blobIdx) + "/" + url.substring(blobIdx + 6);
            }
        }

        if !seen.hasKey(url) { seen[url] = true; urls.push(url); }

        // Add alternate branch variant
        if url.includes("raw.githubusercontent.com/") {
            string alt = "";
            if url.includes("/main/") {
                int? mi = url.indexOf("/main/");
                if mi is int { alt = url.substring(0, mi) + "/master/" + url.substring(mi + 6); }
            } else if url.includes("/master/") {
                int? mi = url.indexOf("/master/");
                if mi is int { alt = url.substring(0, mi) + "/main/" + url.substring(mi + 8); }
            }
            if alt.length() > 0 && !seen.hasKey(alt) { seen[alt] = true; urls.push(alt); }
        }
    }

    foreach string url in urls {
        log:printInfo(string `  [check] ${url}`);
        if headOk(url) {
            string fmt = url.toLowerAscii().endsWith(".json") ? "json" : "yaml";
            log:printInfo(string `  [ok] ${url}`);
            return {specUrl: url, title: (), apiVersion: (), format: fmt};
        }
    }
    return ();
}

// ─── Claude API call ─────────────────────────────────────────────────────────

function callClaude(string apiKey, string model, json[] messages) returns json|error {
    http:Client cl = check new ("https://api.anthropic.com", {
        timeout: 90,
        secureSocket: {enable: true}
    });

    json body = {
        "model": model,
        "max_tokens": 2048,
        "system": SYSTEM_PROMPT,
        "tools": [FETCH_PAGE_TOOL],
        "messages": messages
    };

    http:Response resp = check cl->post("/v1/messages", body, {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json"
    });

    if resp.statusCode != 200 {
        string errBody = check resp.getTextPayload();
        int cap = errBody.length() > 300 ? 300 : errBody.length();
        return error(string `Claude API ${resp.statusCode}: ${errBody.substring(0, cap)}`);
    }

    return check resp.getJsonPayload();
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

// GET — returns body text or error
function httpGetBody(string url) returns string|error {
    string ghToken = os:getEnv("GITHUB_TOKEN");
    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
    if url.includes("api.github.com") && ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

    http:Client cl = check new (url, {
        followRedirects: {enabled: true, maxCount: 5},
        timeout: 20,
        secureSocket: {enable: true}
    });
    http:Response resp = check cl->get("", headers);
    if resp.statusCode != 200 {
        return error(string `HTTP ${resp.statusCode}`);
    }
    return check resp.getTextPayload();
}

// HEAD — returns true if the URL responds with HTTP 200
function headOk(string url) returns boolean {
    do {
        string ghToken = os:getEnv("GITHUB_TOKEN");
        map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
        if url.includes("api.github.com") && ghToken.length() > 0 {
            headers["Authorization"] = string `Bearer ${ghToken}`;
        }
        http:Client cl = check new (url, {
            followRedirects: {enabled: true, maxCount: 5},
            timeout: 10,
            secureSocket: {enable: true}
        });
        http:Response r = check cl->head("", headers);
        if r.statusCode == 200 { return true; }
        if r.statusCode == 405 || r.statusCode == 501 {
            http:Response r2 = check cl->get("", headers);
            return r2.statusCode == 200;
        }
        return false;
    } on fail {
        return false;
    }
}

// ─── HTML link extraction ─────────────────────────────────────────────────────

isolated function extractHrefs(string html, string baseUrl) returns string[] {
    string[] links = [];
    map<boolean> seen = {};
    string rem = html;

    while rem.length() > 0 && links.length() < 400 {
        string loRem = rem.toLowerAscii();
        int? idx = loRem.indexOf("href=");
        if idx is () { break; }
        int after = idx + 5;
        if after >= rem.length() { break; }
        string q = rem[after];
        if q != "\"" && q != "'" { rem = rem.substring(after); continue; }
        int valStart = after + 1;
        int valEnd = valStart;
        while valEnd < rem.length() && rem[valEnd] != q { valEnd += 1; }
        if valEnd >= rem.length() { rem = rem.substring(after); continue; }
        string href = rem.substring(valStart, valEnd);
        rem = rem.substring(valEnd + 1);
        string full = resolveUrl(href, baseUrl);
        if full.length() > 0 && !seen.hasKey(full) {
            seen[full] = true;
            links.push(full);
        }
    }
    return links;
}

isolated function isSpecLink(string url) returns boolean {
    string lo = url.toLowerAscii();
    if lo.endsWith(".yaml") || lo.endsWith(".yml") { return true; }
    if lo.includes("raw.githubusercontent.com") { return true; }
    if lo.includes("api.github.com") { return true; }
    if lo.includes("github.com/") { return true; }
    string[] kw = ["openapi", "swagger", "/spec", "/defs/", "api-description", "download", "reference"];
    foreach string k in kw {
        if lo.includes(k) { return true; }
    }
    if lo.endsWith(".json") && (lo.includes("api") || lo.includes("spec")) { return true; }
    return false;
}

isolated function htmlText(string html) returns string {
    string result = "";
    boolean inTag = false;
    boolean lastSpace = false;
    foreach string ch in html {
        if ch == "<" { inTag = true; continue; }
        if ch == ">" { inTag = false; result += " "; lastSpace = true; continue; }
        if inTag { continue; }
        boolean sp = ch == " " || ch == "\n" || ch == "\t" || ch == "\r";
        if sp { if !lastSpace { result += " "; lastSpace = true; } }
        else { result += ch; lastSpace = false; }
    }
    return result.trim();
}

isolated function resolveUrl(string href, string base) returns string {
    if href.length() == 0 { return ""; }
    if href.startsWith("http://") || href.startsWith("https://") { return href; }
    if href.startsWith("//") {
        string[] p = splitOn(base, "://");
        return (p.length() > 0 ? p[0] : "https") + ":" + href;
    }
    if href.startsWith("/") { return origin(base) + href; }
    if href.startsWith("#") || href.startsWith("javascript") || href.startsWith("mailto") || href.startsWith("data:") { return ""; }
    return dir(base) + href;
}

isolated function origin(string url) returns string {
    string[] p = splitOn(url, "://");
    if p.length() < 2 { return ""; }
    int? si = p[1].indexOf("/");
    return si is int ? p[0] + "://" + p[1].substring(0, si) : p[0] + "://" + p[1];
}

isolated function dir(string url) returns string {
    int i = url.length() - 1;
    while i >= 0 { if url[i] == "/" { return url.substring(0, i + 1); } i -= 1; }
    return url + "/";
}

// ─── String utilities ─────────────────────────────────────────────────────────

isolated function splitOn(string s, string sep) returns string[] {
    string[] parts = [];
    string rem = s;
    while rem.length() > 0 {
        int? idx = rem.indexOf(sep);
        if idx is int { parts.push(rem.substring(0, idx)); rem = rem.substring(idx + sep.length()); }
        else { parts.push(rem); break; }
    }
    return parts;
}

isolated function splitLines(string s) returns string[] {
    return splitOn(s, "\n");
}

// Escape a string value for JSON embedding
isolated function jsonEsc(string s) returns string {
    string r = "";
    foreach string ch in s {
        if ch == "\\" { r += "\\\\"; }
        else if ch == "\"" { r += "\\\""; }
        else if ch == "\n" { r += "\\n"; }
        else if ch == "\r" { r += "\\r"; }
        else if ch == "\t" { r += "\\t"; }
        else { r += ch; }
    }
    return r;
}

// JSON string literal
isolated function jsonStr(string s) returns string {
    return "\"" + jsonEsc(s) + "\"";
}

// JSON array of strings
isolated function jsonArr(string[] items) returns string {
    string r = "[";
    boolean first = true;
    foreach string item in items {
        if !first { r += ","; }
        r += jsonStr(item);
        first = false;
    }
    return r + "]";
}
