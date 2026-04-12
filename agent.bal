// agent.bal
// Shared utilities used by all pipeline steps:
//   - executeFetchPage()          — tool handler (HTML/JSON/YAML fetch + parse)
//   - callClaude()                — Anthropic API call with timing logs
//   - httpGetBody()               — raw HTTP GET, SPA fallback via browser service
//   - httpGetBodyPartial()        — partial HTTP GET; handles large GitHub files via Git Blobs API
//   - headOk()                    — HEAD check with fallback GET
//   - parseGitHubRawUrl()         — decomposes raw.githubusercontent.com URLs
//   - fetchViaGitBlobsApi()       — uses Git Data API for files > 1 MB (avoids CDN SSL issues)
//   - HTML / string utilities
//
// TIMEOUTS (all HTTP):
//   Raw / spec files          : 25 s  (up from 20 s)
//   HTML docs pages (plain)   : 15 s  (up from 12 s)
//   Browser service           : 30 s
//   HEAD checks               : 12 s  (up from 10 s)
//   Claude API                : 120 s (up from 90 s)
//   Git Blobs API fallback    : 30 s
//
// Enable debug mode: bal run --log-level=DEBUG
// or set LOG_LEVEL=DEBUG in your environment and pass --log-level=$LOG_LEVEL

import ballerina/http;
import ballerina/lang.'array as langarray;
import ballerina/log;
import ballerina/os;
import ballerina/time;
import ballerina/url;

// ─── Tool definition ─────────────────────────────────────────────────────────

final json FETCH_PAGE_TOOL = {
    "name": "fetch_page",
    "description":
        "Fetches a URL and returns its content. " +
        "HTML → {spec_links, page_text, other_links}. " +
        "JSON/YAML → {type, content} with up to 12 KB of file content. " +
        "Never fetch github.com/blob or github.com/tree pages. " +
        "Use api.github.com/repos/OWNER/REPO/contents/PATH to list a folder. " +
        "Use api.github.com/repos/OWNER/REPO/git/trees/HEAD?recursive=1 for full flat listing (may truncate on large repos).",
    "input_schema": {
        "type": "object",
        "properties": {
            "url": {"type": "string", "description": "Full URL to fetch (https://...)"}
        },
        "required": ["url"]
    }
};

// ─── fetch_page tool handler ──────────────────────────────────────────────────

const string EMPTY_HTML_RESULT = "{\"type\":\"html\",\"spec_links\":[],\"page_text\":\"\",\"other_links\":[]}";

function executeFetchPage(string fetchUrl) returns string {
    log:printInfo(string `    [fetch] ${fetchUrl}`);
    log:printDebug(string `    [fetch:debug] starting fetch at ${timeNow()}`);

    do {
        time:Utc t0 = time:utcNow();
        string|error body = httpGetBody(fetchUrl);
        decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));

        if body is error {
            log:printInfo(string `      error: ${body.message()}`);
            log:printDebug(string `    [fetch:debug] fetch failed after ${elapsed}s — url=${fetchUrl} err=${body.message()}`);
            if !isRawContentUrl(fetchUrl) {
                return EMPTY_HTML_RESULT;
            }
            return string `{"error":"fetch failed: ${jsonEsc(body.message())}"}`;
        }

        log:printDebug(string `    [fetch:debug] fetch succeeded in ${elapsed}s — bytes=${body.length()}`);

        string lo = fetchUrl.toLowerAscii();

        // YAML
        if lo.endsWith(".yaml") || lo.endsWith(".yml") {
            string snippet = body.length() > 12000 ? body.substring(0, 12000) : body;
            log:printDebug("    [fetch:debug] detected YAML content");
            return string `{"type":"yaml","content":${jsonStr(snippet)}}`;
        }

        // JSON / GitHub API — use 100 KB cap for GitHub Contents API directory listings
        if lo.endsWith(".json") || lo.includes("api.github.com") || lo.includes("application/json") {
            int jsonCap = lo.includes("api.github.com") ? 100000 : 12000;
            string snippet = body.length() > jsonCap ? body.substring(0, jsonCap) : body;
            log:printDebug(string `    [fetch:debug] detected JSON content, cap=${jsonCap}`);
            return string `{"type":"json","content":${jsonStr(snippet)}}`;
        }

        // Detect by content if extension is ambiguous
        string trimmed = body.trim();
        if trimmed.startsWith("openapi:") || trimmed.startsWith("swagger:") || trimmed.startsWith("---") {
            string snippet = body.length() > 12000 ? body.substring(0, 12000) : body;
            log:printDebug("    [fetch:debug] detected YAML by content sniff");
            return string `{"type":"yaml","content":${jsonStr(snippet)}}`;
        }
        if trimmed.startsWith("{") || trimmed.startsWith("[") {
            string snippet = body.length() > 12000 ? body.substring(0, 12000) : body;
            log:printDebug("    [fetch:debug] detected JSON by content sniff");
            return string `{"type":"json","content":${jsonStr(snippet)}}`;
        }

        // HTML — extract links and text
        log:printDebug("    [fetch:debug] treating as HTML, extracting links");
        string[] specLinks = [];
        string[] otherLinks = [];
        string[] allLinks = extractHrefs(body, fetchUrl);

        foreach string lnk in allLinks {
            if isSpecLink(lnk) {
                specLinks.push(lnk);
            } else {
                otherLinks.push(lnk);
            }
        }

        string txt = htmlText(body);
        string txtSnippet = txt.length() > 3000 ? txt.substring(0, 3000) : txt;
        int otherCap = otherLinks.length() > 60 ? 60 : otherLinks.length();
        log:printDebug(string `    [fetch:debug] HTML: specLinks=${specLinks.length()} otherLinks=${otherLinks.length()} textLen=${txt.length()}`);

        return string `{"type":"html","spec_links":${jsonArr(specLinks)},"page_text":${jsonStr(txtSnippet)},"other_links":${jsonArr(otherLinks.slice(0, otherCap))}}`;
    } on fail error e {
        log:printWarn(string `      [fetch] unexpected error: ${e.message()}`);
        log:printDebug(string `    [fetch:debug] panic/unexpected error — url=${fetchUrl} err=${e.message()}`);
        return EMPTY_HTML_RESULT;
    }
}

// ─── GitHub raw URL decomposition ────────────────────────────────────────────

// Parsed components of a raw.githubusercontent.com URL.
type GitHubRawUrl record {|
    string owner;
    string repo;
    string branch;
    string path;       // path/to/file.yaml
|};

// Decomposes https://raw.githubusercontent.com/OWNER/REPO/BRANCH/path/to/file
// Returns () if the URL is not a raw GitHub URL or is malformed.
isolated function parseGitHubRawUrl(string rawUrl) returns GitHubRawUrl? {
    string prefix = "raw.githubusercontent.com/";
    int? pi = rawUrl.indexOf(prefix);
    if pi is () { return (); }
    string rest = rawUrl.substring(pi + prefix.length());

    int? s1 = rest.indexOf("/");
    if s1 is () { return (); }
    string owner = rest.substring(0, s1);
    string rem1 = rest.substring(s1 + 1);

    int? s2 = rem1.indexOf("/");
    if s2 is () { return (); }
    string repo = rem1.substring(0, s2);
    string rem2 = rem1.substring(s2 + 1);

    int? s3 = rem2.indexOf("/");
    if s3 is () { return (); }
    string branch = rem2.substring(0, s3);
    string path = rem2.substring(s3 + 1);

    return {owner, repo, branch, path};
}

// ─── Git Blobs API fallback for files > 1 MB ─────────────────────────────────
//
// GitHub's Contents API returns an error for files > 1 MB even with
// "Accept: application/vnd.github.raw". This function uses the Git Data API
// (blobs endpoint) which handles files up to 100 MB, all from api.github.com
// so it avoids the raw.githubusercontent.com CDN SSL issues in this environment.
//
// Two-step process:
//   1. GET /repos/OWNER/REPO/contents/PATH?ref=BRANCH  → extract blob SHA
//   2. GET /repos/OWNER/REPO/git/blobs/SHA with Accept: raw → return content

function fetchViaGitBlobsApi(string rawUrl, int maxBytes, string ghToken) returns string|error {
    log:printDebug(string `    [blobs-api] starting Git Blobs API fallback for: ${rawUrl}`);

    GitHubRawUrl? parsed = parseGitHubRawUrl(rawUrl);
    if parsed is () {
        return error("fetchViaGitBlobsApi: cannot parse raw GitHub URL");
    }
    string owner = parsed.owner;
    string repo = parsed.repo;
    string branch = parsed.branch;
    string path = parsed.path;

    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
    if ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

    // ── Step 1: Get blob SHA from Contents API metadata ──────────────────────
    // (Without Accept: raw — returns JSON metadata including sha for any size)
    string metaUrl = string `https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${branch}`;
    log:printDebug(string `    [blobs-api:step1] fetching metadata: ${metaUrl}`);
    time:Utc t0 = time:utcNow();

    http:Client metaClient = check new (metaUrl, {
        followRedirects: {enabled: true, maxCount: 3},
        timeout: 20,
        secureSocket: {enable: true}
    });
    http:Response metaResp = check metaClient->get("", headers);
    decimal metaElapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));
    log:printDebug(string `    [blobs-api:step1] status=${metaResp.statusCode} elapsed=${metaElapsed}s`);

    if metaResp.statusCode != 200 {
        return error(string `Git Blobs API step1: HTTP ${metaResp.statusCode}`);
    }

    string metaBody = check metaResp.getTextPayload();
    json|error metaJson = metaBody.fromJsonString();
    if metaJson is error {
        return error(string `Git Blobs API step1: cannot parse metadata JSON: ${metaJson.message()}`);
    }

    string sha = "";
    int fileSize = 0;
    if metaJson is map<json> {
        json? shaVal = metaJson["sha"];
        if shaVal is string { sha = shaVal; }
        json? sizeVal = metaJson["size"];
        if sizeVal is int { fileSize = sizeVal; }
    }
    if sha.length() == 0 {
        return error("Git Blobs API step1: could not extract blob SHA from metadata");
    }
    log:printDebug(string `    [blobs-api:step1] blob SHA=${sha} size=${fileSize}`);

    // ── Step 2: Fetch raw blob content via Git Data API ───────────────────────
    //
    // Correct media type for the Git Blobs endpoint is "application/vnd.github.raw+json"
    // (NOT "application/vnd.github.raw" which is for the Contents API).
    // If GitHub still returns the default base64 JSON envelope, we decode it below.
    string blobUrl = string `https://api.github.com/repos/${owner}/${repo}/git/blobs/${sha}`;
    map<string|string[]> blobHeaders = {
        "User-Agent": "openapi-spec-finder/1.0",
        "Accept":     "application/vnd.github.raw+json"
    };
    if ghToken.length() > 0 {
        blobHeaders["Authorization"] = string `Bearer ${ghToken}`;
    }

    log:printDebug(string `    [blobs-api:step2] fetching raw blob: ${blobUrl}`);
    time:Utc t1 = time:utcNow();

    http:Client blobClient = check new (blobUrl, {
        followRedirects: {enabled: true, maxCount: 5},
        timeout: 30,
        secureSocket: {enable: true}
    });
    http:Response blobResp = check blobClient->get("", blobHeaders);
    decimal blobElapsed = rd(time:utcDiffSeconds(time:utcNow(), t1));
    log:printDebug(string `    [blobs-api:step2] status=${blobResp.statusCode} elapsed=${blobElapsed}s`);

    if blobResp.statusCode != 200 {
        return error(string `Git Blobs API step2: HTTP ${blobResp.statusCode}`);
    }

    string blobBody = check blobResp.getTextPayload();
    log:printDebug(string `    [blobs-api:step2] received ${blobBody.length()} bytes`);

    // ── Base64 fallback ───────────────────────────────────────────────────────
    // If GitHub returned the default JSON blob envelope (encoding: base64) instead
    // of raw content, decode the base64 content ourselves.
    // This happens when the Accept header isn't honoured or the response is the
    // default format: {"sha":"...","content":"base64...","encoding":"base64"}
    if blobBody.trim().startsWith("{") && blobBody.includes("\"encoding\"") {
        log:printDebug("    [blobs-api:step2] response looks like JSON blob envelope — attempting base64 decode");
        string? decoded = decodeGitHubBlobBase64(blobBody, maxBytes);
        if decoded is string {
            log:printInfo(string `    [blobs-api:step2] base64 decode succeeded — returning ${decoded.length()} bytes`);
            return decoded;
        }
        log:printWarn("    [blobs-api:step2] base64 decode failed — returning raw response (looksLikeSpec may reject it)");
    }

    string result = blobBody.length() > maxBytes ? blobBody.substring(0, maxBytes) : blobBody;
    log:printDebug(string `    [blobs-api:step2] returning ${result.length()} bytes (raw)`);
    return result;
}

// ─── Base64 blob decoder ──────────────────────────────────────────────────────
//
// GitHub's default Blobs API response wraps content as base64:
//   { "sha": "...", "content": "eyJzd2FnZ2VyIjog...\n...", "encoding": "base64" }
//
// This function parses that envelope and returns the decoded string content,
// capped at maxBytes. Returns () if the body is not a base64 blob envelope or
// if decoding fails.

function decodeGitHubBlobBase64(string jsonBody, int maxBytes) returns string? {
    do {
        json parsed = check jsonBody.fromJsonString();
        if !(parsed is map<json>) { return (); }

        json? enc = parsed["encoding"];
        json? cnt = parsed["content"];

        if enc != "base64" { return (); }
        if !(cnt is string) { return (); }

        // GitHub chunks base64 with embedded newlines — strip them before decoding
        string cleanB64 = re `[\n\r\s]`.replaceAll(<string>cnt, "");
        log:printDebug(string `    [base64-decode] clean base64 length: ${cleanB64.length()}`);

        // To get maxBytes of decoded content we need at most ceil(maxBytes/3)*4 base64 chars
        // (4 base64 chars → 3 decoded bytes). Add a small margin.
        int b64Limit = (maxBytes / 3 + 1) * 4 + 4;
        string b64Slice = cleanB64.length() > b64Limit ? cleanB64.substring(0, b64Limit) : cleanB64;

        byte[] decoded = check langarray:fromBase64(b64Slice);
        string rawStr = check string:fromBytes(decoded);
        string capped = rawStr.length() > maxBytes ? rawStr.substring(0, maxBytes) : rawStr;
        log:printDebug(string `    [base64-decode] decoded ${decoded.length()} bytes, returning ${capped.length()}`);
        return capped;
    } on fail error e {
        log:printDebug(string `    [base64-decode] failed: ${e.message()}`);
        return ();
    }
}

// ─── Claude API call ──────────────────────────────────────────────────────────

function callClaude(string apiKey, string model, json[] messages, string systemPrompt) returns json|error {
    log:printDebug(string `    [claude] calling API model=${model} messages=${messages.length()} promptLen=${systemPrompt.length()}`);
    time:Utc t0 = time:utcNow();

    http:Client cl = check new ("https://api.anthropic.com", {
        timeout: 120,
        secureSocket: {enable: true}
    });

    json body = {
        "model": model,
        "max_tokens": 1024,
        "temperature": 0,
        "system": systemPrompt,
        "tools": [FETCH_PAGE_TOOL],
        "messages": messages
    };

    http:Response resp = check cl->post("/v1/messages", body, {
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json"
    });

    decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));
    log:printDebug(string `    [claude] response status=${resp.statusCode} elapsed=${elapsed}s`);

    if resp.statusCode != 200 {
        string errBody = check resp.getTextPayload();
        int cap = errBody.length() > 300 ? 300 : errBody.length();
        return error(string `Claude API ${resp.statusCode}: ${errBody.substring(0, cap)}`);
    }

    return check resp.getJsonPayload();
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

// Returns true for raw spec/API file URLs (GitHub API, .yaml, .yml, .json).
isolated function isRawContentUrl(string rawUrl) returns boolean {
    string lo = rawUrl.toLowerAscii();
    if lo.includes("api.github.com") { return true; }
    if lo.endsWith(".yaml") || lo.endsWith(".yml") { return true; }
    if lo.endsWith(".json") { return true; }
    return false;
}

// Fetches a URL via the local browser service (browser-service/server.js).
// The service uses Playwright/Chromium to render JS-heavy SPAs.
// Endpoint: GET http://localhost:3456/fetch?url=<encoded-url>
function httpGetBodyViaBrowserService(string targetUrl) returns string|error {
    log:printInfo(string `    [browser-service] ${targetUrl}`);
    log:printDebug(string `    [browser-service:debug] connecting to localhost:3456`);
    time:Utc t0 = time:utcNow();

    http:Client cl = check new ("http://localhost:3456", {timeout: 30});

    string encodedUrl = check url:encode(targetUrl, "UTF-8");
    http:Response resp = check cl->get(string `/fetch?url=${encodedUrl}`);

    decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));
    log:printDebug(string `    [browser-service:debug] response status=${resp.statusCode} elapsed=${elapsed}s`);

    if resp.statusCode != 200 {
        string errBody = check resp.getTextPayload();
        int cap = errBody.length() > 200 ? 200 : errBody.length();
        return error(string `BrowserService ${resp.statusCode}: ${errBody.substring(0, cap)}`);
    }

    json respJson = check resp.getJsonPayload();
    map<json> respMap = check respJson.cloneWithType();

    json errField = respMap["error"];
    if errField != () && errField.toString().length() > 0 {
        return error(string `BrowserService error: ${errField.toString()}`);
    }

    json htmlField = respMap["html"];
    if htmlField == () {
        return error("BrowserService: missing html field in response");
    }

    string html = htmlField.toString();
    string capped = html.length() > 500000 ? html.substring(0, 500000) : html;
    log:printInfo(string `    [browser-service] OK — ${html.length()} bytes (capped to ${capped.length()})`);
    log:printDebug(string `    [browser-service:debug] received ${html.length()} bytes in ${elapsed}s`);
    return capped;
}

// Minimum visible text length to consider a plain-HTTP response "useful".
const int MIN_USEFUL_TEXT_LENGTH = 500;

function httpGetBody(string fetchUrl) returns string|error {
    string ghToken = os:getEnv("GITHUB_TOKEN");
    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
    if (fetchUrl.includes("api.github.com") || fetchUrl.includes("raw.githubusercontent.com")) && ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

    // Raw content (GitHub API, spec files): plain HTTP only, no browser needed.
    if isRawContentUrl(fetchUrl) {
        log:printDebug(string `    [httpGetBody:debug] raw-content URL — direct fetch: ${fetchUrl}`);
        time:Utc t0 = time:utcNow();
        http:Client cl = check new (fetchUrl, {
            followRedirects: {enabled: true, maxCount: 5},
            timeout: 25,
            secureSocket: {enable: true}
        });
        http:Response resp = check cl->get("", headers);
        decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));
        log:printDebug(string `    [httpGetBody:debug] raw response status=${resp.statusCode} elapsed=${elapsed}s`);
        if resp.statusCode != 200 {
            return error(string `HTTP ${resp.statusCode}`);
        }
        string body = check resp.getTextPayload();
        log:printDebug(string `    [httpGetBody:debug] raw body length=${body.length()}`);
        return body;
    }

    // HTML docs pages:
    //   1. Try plain HTTP first (fast, static sites)
    //   2. If < MIN_USEFUL_TEXT_LENGTH chars → SPA → try browser service
    //   3. Fall back to plain HTTP result if browser service fails
    log:printDebug(string `    [httpGetBody:debug] HTML page — trying plain HTTP: ${fetchUrl}`);
    string|error plainResult = httpGetBodyPlain(fetchUrl, headers, 100000);

    if plainResult is string {
        string textContent = htmlText(plainResult);
        if textContent.length() >= MIN_USEFUL_TEXT_LENGTH {
            log:printInfo(string `    [plain-http] OK — ${plainResult.length()} bytes (${textContent.length()} chars text)`);
            log:printDebug(string `    [httpGetBody:debug] plain HTTP succeeded, text=${textContent.length()} chars`);
            return plainResult;
        }
        log:printInfo(string `    [plain-http] SPA detected (only ${textContent.length()} chars text) — trying browser service`);
        log:printDebug(string `    [httpGetBody:debug] SPA shell detected — body=${plainResult.length()} bytes, text=${textContent.length()} chars`);
    } else {
        log:printInfo(string `    [plain-http] failed: ${plainResult.message()} — trying browser service`);
        log:printDebug(string `    [httpGetBody:debug] plain HTTP failed: ${plainResult.message()}`);
    }

    string|error browserResult = httpGetBodyViaBrowserService(fetchUrl);
    if browserResult is string {
        log:printDebug(string `    [httpGetBody:debug] browser service succeeded, body=${browserResult.length()} bytes`);
        return browserResult;
    }
    log:printInfo(string `    [browser-service] also failed: ${browserResult.message()} — using plain HTTP fallback`);
    log:printDebug(string `    [httpGetBody:debug] browser service failed: ${browserResult.message()} — falling back to plain HTTP result`);

    if plainResult is string {
        return plainResult;
    }
    return plainResult;
}

// Plain HTTP fetch with body cap.
function httpGetBodyPlain(string fetchUrl, map<string|string[]> headers, int maxBytes) returns string|error {
    log:printDebug(string `    [plain-http:debug] GET ${fetchUrl} maxBytes=${maxBytes}`);
    time:Utc t0 = time:utcNow();

    http:Client cl = check new (fetchUrl, {
        followRedirects: {enabled: true, maxCount: 5},
        timeout: 15,
        secureSocket: {enable: true}
    });
    http:Response resp = check cl->get("", headers);
    decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));
    log:printDebug(string `    [plain-http:debug] status=${resp.statusCode} elapsed=${elapsed}s`);

    if resp.statusCode != 200 {
        return error(string `HTTP ${resp.statusCode}`);
    }
    string body = check resp.getTextPayload();
    string result = body.length() > maxBytes ? body.substring(0, maxBytes) : body;
    log:printDebug(string `    [plain-http:debug] body=${body.length()} capped=${result.length()}`);
    return result;
}

function headOk(string headUrl) returns boolean {
    log:printDebug(string `    [headOk:debug] HEAD ${headUrl}`);
    time:Utc t0 = time:utcNow();
    do {
        string ghToken = os:getEnv("GITHUB_TOKEN");
        map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
        if (headUrl.includes("api.github.com") || headUrl.includes("raw.githubusercontent.com")) && ghToken.length() > 0 {
            headers["Authorization"] = string `Bearer ${ghToken}`;
        }
        http:Client cl = check new (headUrl, {
            followRedirects: {enabled: true, maxCount: 5},
            timeout: 12,
            secureSocket: {enable: true}
        });
        http:Response r = check cl->head("", headers);
        decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));
        log:printDebug(string `    [headOk:debug] status=${r.statusCode} elapsed=${elapsed}s`);
        if r.statusCode == 200 { return true; }
        if r.statusCode == 405 || r.statusCode == 501 {
            log:printDebug("    [headOk:debug] HEAD not allowed, trying GET");
            http:Response r2 = check cl->get("", headers);
            log:printDebug(string `    [headOk:debug] GET fallback status=${r2.statusCode}`);
            return r2.statusCode == 200;
        }
        log:printDebug(string `    [headOk:debug] HEAD returned ${r.statusCode} — not OK`);
        return false;
    } on fail error e {
        decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));
        log:printDebug(string `    [headOk:debug] HEAD failed after ${elapsed}s: ${e.message()}`);
        return false;
    }
}

// ─── Partial fetch with large-file GitHub awareness ───────────────────────────
//
// For raw.githubusercontent.com URLs:
//   1. Convert to GitHub Contents API URL and set Accept: vnd.github.raw
//   2. Fetch — works for files up to 1 MB
//   3. If the response contains the GitHub "too large" error, fall back to
//      the Git Blobs API (handles up to 100 MB) to get the first maxBytes
//
// This fixes the Slack / large-spec failure where the Contents API returned
// an error JSON instead of spec content.

function httpGetBodyPartial(string rawUrl, int maxBytes) returns string|error {
    string ghToken = os:getEnv("GITHUB_TOKEN");
    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};

    string fetchUrl = rawUrl;
    boolean isGitHubRaw = rawUrl.includes("raw.githubusercontent.com/");

    if isGitHubRaw {
        fetchUrl = rawUrlToApiUrl(rawUrl);
        headers["Accept"] = "application/vnd.github.raw";
        log:printDebug(string `    [partial-fetch:debug] GitHub raw → Contents API: ${fetchUrl}`);
    }

    if (fetchUrl.includes("api.github.com") || rawUrl.includes("raw.githubusercontent.com")) && ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

    log:printDebug(string `    [partial-fetch:debug] fetching ${fetchUrl} maxBytes=${maxBytes}`);
    time:Utc t0 = time:utcNow();

    http:Client cl = check new (fetchUrl, {
        followRedirects: {enabled: true, maxCount: 5},
        timeout: 25,
        secureSocket: {enable: true}
    });
    http:Response resp = check cl->get("", headers);
    decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));
    log:printDebug(string `    [partial-fetch:debug] status=${resp.statusCode} elapsed=${elapsed}s`);

    if resp.statusCode != 200 {
        return error(string `HTTP ${resp.statusCode}`);
    }
    string body = check resp.getTextPayload();
    log:printDebug(string `    [partial-fetch:debug] body length=${body.length()}`);

    // ── Detect GitHub "blob too large" error ─────────────────────────────────
    // The Contents API returns this JSON for files > 1 MB even with Accept: raw:
    //   {"message":"This API returns blobs up to 1 MB...","errors":[{"code":"too_large"}]}
    if isGitHubRaw && isGitHubTooLargeError(body) {
        log:printInfo(string `    [partial-fetch] Contents API: file too large (>1 MB) — switching to Git Blobs API`);
        log:printDebug(string `    [partial-fetch:debug] too-large error body snippet: ${body.substring(0, body.length() > 200 ? 200 : body.length())}`);
        return fetchViaGitBlobsApi(rawUrl, maxBytes, ghToken);
    }

    string result = body.length() > maxBytes ? body.substring(0, maxBytes) : body;
    log:printDebug(string `    [partial-fetch:debug] returning ${result.length()} bytes`);
    return result;
}

// Detects GitHub's "blob too large for Contents API" error in the response body.
isolated function isGitHubTooLargeError(string body) returns boolean {
    if body.includes("\"too_large\"") { return true; }
    if body.includes("too large to fetch via the API") { return true; }
    if body.includes("larger than") && body.includes("blob") { return true; }
    // Contents API returns metadata JSON (with empty "content") for files 1-100 MB
    // Detect: content field is empty but size is large
    if body.includes("\"encoding\":\"none\"") && body.includes("\"content\":\"\"") { return true; }
    return false;
}

// Converts a raw.githubusercontent.com URL to a GitHub Contents API URL.
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

// Returns the Content-Length of a URL from a HEAD request, or 0 if unavailable.
function getContentLength(string contentUrl) returns int {
    log:printDebug(string `    [content-length:debug] checking ${contentUrl}`);
    do {
        string ghToken = os:getEnv("GITHUB_TOKEN");
        map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
        if (contentUrl.includes("api.github.com") || contentUrl.includes("raw.githubusercontent.com")) && ghToken.length() > 0 {
            headers["Authorization"] = string `Bearer ${ghToken}`;
        }
        http:Client cl = check new (contentUrl, {
            followRedirects: {enabled: true, maxCount: 5},
            timeout: 12,
            secureSocket: {enable: true}
        });
        http:Response r = check cl->head("", headers);
        if r.statusCode == 200 {
            string clHeader = check r.getHeader("content-length");
            int|error parsed = int:fromString(clHeader);
            if parsed is int {
                log:printDebug(string `    [content-length:debug] Content-Length=${parsed}`);
                return parsed;
            }
        }
    } on fail error e {
        log:printDebug(string `    [content-length:debug] failed: ${e.message()}`);
    }
    return 0;
}

// ─── Inference helper ─────────────────────────────────────────────────────────

isolated function inferRepoFromRawUrl(string rawUrl) returns string? {
    string prefix = "raw.githubusercontent.com/";
    int? pi = rawUrl.indexOf(prefix);
    if pi is () { return (); }
    string rest = rawUrl.substring(pi + prefix.length());
    string[] parts = splitOn(rest, "/");
    if parts.length() >= 2 {
        return parts[0] + "/" + parts[1];
    }
    return ();
}

// ─── Parse SPEC_CANDIDATES output ────────────────────────────────────────────

function pickBestCandidate(string text) returns SpecResult? {
    log:printDebug("    [pickBestCandidate:debug] parsing SPEC_CANDIDATES block");
    int? idx = text.indexOf("SPEC_CANDIDATES:");
    if idx is () { return (); }
    string after = text.substring(idx + 16);

    string? specRepo = ();
    int? repoIdx = text.indexOf("SPEC_REPO:");
    if repoIdx is int {
        string repoLine = text.substring(repoIdx + 10);
        string[] repoLines = splitLines(repoLine);
        if repoLines.length() > 0 {
            string repo = repoLines[0].trim();
            if repo.length() > 0 { specRepo = repo; }
        }
    }

    string[] urls = [];
    map<boolean> seen = {};

    foreach string line in splitLines(after) {
        string t = line.trim();
        if t.startsWith("SPEC_REPO:") { break; }
        if !t.startsWith("http") { continue; }

        string candidateUrl = t;
        if candidateUrl.includes("github.com/") && candidateUrl.includes("/blob/") {
            int? ghIdx = candidateUrl.indexOf("github.com/");
            if ghIdx is int {
                string rest = candidateUrl.substring(ghIdx + 11);
                string[] parts = splitOn(rest, "/blob/");
                if parts.length() == 2 {
                    candidateUrl = "https://raw.githubusercontent.com/" + parts[0] + "/" + parts[1];
                }
            }
        }

        if !seen.hasKey(candidateUrl) { seen[candidateUrl] = true; urls.push(candidateUrl); }

        if candidateUrl.includes("raw.githubusercontent.com/") {
            if specRepo is () {
                specRepo = inferRepoFromRawUrl(candidateUrl);
            }
            string alt = "";
            if candidateUrl.includes("/main/") {
                int? mi = candidateUrl.indexOf("/main/");
                if mi is int { alt = candidateUrl.substring(0, mi) + "/master/" + candidateUrl.substring(mi + 6); }
            } else if candidateUrl.includes("/master/") {
                int? mi = candidateUrl.indexOf("/master/");
                if mi is int { alt = candidateUrl.substring(0, mi) + "/main/" + candidateUrl.substring(mi + 8); }
            }
            if alt.length() > 0 && !seen.hasKey(alt) { seen[alt] = true; urls.push(alt); }
        }
    }

    log:printDebug(string `    [pickBestCandidate:debug] found ${urls.length()} candidate URLs to try`);
    foreach string candidateUrl in urls {
        log:printInfo(string `  [check] ${candidateUrl}`);
        if headOk(candidateUrl) {
            string fmt = candidateUrl.toLowerAscii().endsWith(".json") ? "json" : "yaml";
            log:printInfo(string `  [ok] ${candidateUrl}`);
            return {specUrl: candidateUrl, specRepo: specRepo, title: (), apiVersion: (), format: fmt};
        }
        log:printInfo(string `  [dead] ${candidateUrl}`);
    }

    log:printInfo("  [agent] all candidate URLs failed HEAD check");
    return ();
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

isolated function isSpecLink(string linkUrl) returns boolean {
    string lo = linkUrl.toLowerAscii();
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

isolated function origin(string urlStr) returns string {
    string[] p = splitOn(urlStr, "://");
    if p.length() < 2 { return ""; }
    int? si = p[1].indexOf("/");
    return si is int ? p[0] + "://" + p[1].substring(0, si) : p[0] + "://" + p[1];
}

isolated function dir(string urlStr) returns string {
    int i = urlStr.length() - 1;
    while i >= 0 { if urlStr[i] == "/" { return urlStr.substring(0, i + 1); } i -= 1; }
    return urlStr + "/";
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

isolated function jsonStr(string s) returns string {
    return "\"" + jsonEsc(s) + "\"";
}

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

// Returns a compact timestamp string for debug logs.
isolated function timeNow() returns string {
    // Uses wall-clock seconds as a simple prefix; full timestamps appear in the log framework.
    return time:utcToString(time:utcNow());
}

isolated function rd(decimal d) returns decimal {
    return <decimal>(<int>(d * 10d)) / 10d;
}
