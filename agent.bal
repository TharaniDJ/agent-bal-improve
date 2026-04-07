// agent.bal
// Shared utilities used by all pipeline steps:
//   - executeFetchPage()        — tool handler (HTML/JSON/YAML fetch + parse)
//   - callClaude()              — Anthropic API call
//   - httpGetBody()             — raw HTTP GET, with Browserless fallback for SPAs
//   - headOk()                  — HEAD check
//   - HTML/string utils
//
// Fetching strategy for HTML docs pages:
//   1. Try plain HTTP first (fast, no cost, works for static sites)
//   2. If result has < 500 chars of visible text → SPA detected → use Browserless
//   3. Browserless retries up to 3x with backoff on 429 (rate limit)
//   4. If Browserless also fails → return whatever plain HTTP gave us
//
// Set BROWSERLESS_TOKEN env var. Free tier at https://browserless.io

import ballerina/http;
import ballerina/log;
import ballerina/os;
import ballerina/lang.runtime as runtime;

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

function executeFetchPage(string url) returns string {
    log:printInfo(string `    [fetch] ${url}`);

    do {
        string|error body = httpGetBody(url);
        if body is error {
            log:printInfo(string `      error: ${body.message()}`);
            if !isRawContentUrl(url) {
                return EMPTY_HTML_RESULT;
            }
            return string `{"error":"fetch failed: ${jsonEsc(body.message())}"}`;
        }

        string lo = url.toLowerAscii();

        // YAML
        if lo.endsWith(".yaml") || lo.endsWith(".yml") {
            string snippet = body.length() > 12000 ? body.substring(0, 12000) : body;
            return string `{"type":"yaml","content":${jsonStr(snippet)}}`;
        }

        // JSON / GitHub API — use 100KB cap for GitHub Contents API directory listings
        // (12KB truncates large folders like HubSpot CRM which has 50+ entries)
        if lo.endsWith(".json") || lo.includes("api.github.com") || lo.includes("application/json") {
            int jsonCap = lo.includes("api.github.com") ? 100000 : 12000;
            string snippet = body.length() > jsonCap ? body.substring(0, jsonCap) : body;
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
        int otherCap = otherLinks.length() > 60 ? 60 : otherLinks.length();

        return string `{"type":"html","spec_links":${jsonArr(specLinks)},"page_text":${jsonStr(txtSnippet)},"other_links":${jsonArr(otherLinks.slice(0, otherCap))}}`;
    } on fail error e {
        log:printInfo(string `      [fetch] unexpected error: ${e.message()}`);
        return EMPTY_HTML_RESULT;
    }
}

// ─── Parse SPEC_CANDIDATES output ────────────────────────────────────────────

function pickBestCandidate(string text) returns SpecResult? {
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

        string url = t;
        if url.includes("github.com/") && url.includes("/blob/") {
            int? ghIdx = url.indexOf("github.com/");
            if ghIdx is int {
                string rest = url.substring(ghIdx + 11);
                string[] parts = splitOn(rest, "/blob/");
                if parts.length() == 2 {
                    url = "https://raw.githubusercontent.com/" + parts[0] + "/" + parts[1];
                }
            }
        }

        if !seen.hasKey(url) { seen[url] = true; urls.push(url); }

        if url.includes("raw.githubusercontent.com/") {
            if specRepo is () {
                specRepo = inferRepoFromRawUrl(url);
            }
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
            return {specUrl: url, specRepo: specRepo, title: (), apiVersion: (), format: fmt};
        }
        log:printInfo(string `  [dead] ${url}`);
    }

    log:printInfo("  [agent] all candidate URLs failed HEAD check");
    return ();
}

isolated function inferRepoFromRawUrl(string url) returns string? {
    string prefix = "raw.githubusercontent.com/";
    int? pi = url.indexOf(prefix);
    if pi is () { return (); }
    string rest = url.substring(pi + prefix.length());
    string[] parts = splitOn(rest, "/");
    if parts.length() >= 2 {
        return parts[0] + "/" + parts[1];
    }
    return ();
}

// ─── Claude API call ──────────────────────────────────────────────────────────

function callClaude(string apiKey, string model, json[] messages, string systemPrompt) returns json|error {
    http:Client cl = check new ("https://api.anthropic.com", {
        timeout: 90,
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

    if resp.statusCode != 200 {
        string errBody = check resp.getTextPayload();
        int cap = errBody.length() > 300 ? 300 : errBody.length();
        return error(string `Claude API ${resp.statusCode}: ${errBody.substring(0, cap)}`);
    }

    return check resp.getJsonPayload();
}

// ─── HTTP helpers ─────────────────────────────────────────────────────────────

// Returns true for raw spec/API file URLs (GitHub API, .yaml, .yml, .json).
isolated function isRawContentUrl(string url) returns boolean {
    string lo = url.toLowerAscii();
    if lo.includes("api.github.com") { return true; }
    if lo.endsWith(".yaml") || lo.endsWith(".yml") { return true; }
    if lo.endsWith(".json") { return true; }
    return false;
}

// Fetches a URL via the Browserless.io /content REST API.
// Renders the page in a real headless Chrome instance — handles JS/SPAs,
// returns fully-rendered HTML including dynamically injected content and links.
//
// Retries up to 3x on 429 (Too Many Requests) with increasing backoff.
// Docs: https://docs.browserless.io/rest-apis/content
function httpGetBodyViaBrowserless(string url) returns string|error {
    string token = os:getEnv("BROWSERLESS_TOKEN");
    if token.length() == 0 {
        return error("BROWSERLESS_TOKEN not set");
    }

    int maxAttempts = 3;
    int attempt = 0;
    int[] backoffMs = [5000, 15000, 30000];

    while attempt < maxAttempts {
        attempt += 1;
        log:printInfo(string `    [browserless] ${url}${attempt > 1 ? string ` (attempt ${attempt})` : ""}`);

        string|error result = doSingleBrowserlessFetch(url, token);
        if result is string {
            return result;
        }

        string errMsg = result.message();
        if errMsg.includes("429") && attempt < maxAttempts {
            int waitMs = backoffMs[attempt - 1];
            log:printInfo(string `    [browserless] 429 rate limited — waiting ${waitMs}ms before retry`);
            runtime:sleep(<decimal>waitMs / 1000d);
            continue;
        }

        log:printInfo(string `    [browserless] failed: ${errMsg}`);
        return result;
    }

    return error("Browserless: max retries exceeded");
}

function doSingleBrowserlessFetch(string url, string token) returns string|error {
    http:Client cl = check new ("https://production-sfo.browserless.io", {
        timeout: 35,
        secureSocket: {enable: true}
    });

    json payload = {
        "url": url,
        "gotoOptions": {
            "waitUntil": "networkidle2",
            "timeout": 30000
        },
        "bestAttempt": true
    };

    http:Response resp = check cl->post(
        string `/content?token=${token}`,
        payload,
        {
            "Content-Type": "application/json",
            "Cache-Control": "no-cache"
        }
    );

    if resp.statusCode != 200 {
        string errBody = check resp.getTextPayload();
        int cap = errBody.length() > 200 ? 200 : errBody.length();
        return error(string `Browserless ${resp.statusCode}: ${errBody.substring(0, cap)}`);
    }

    string body = check resp.getTextPayload();
    // Cap at 500KB — large enough to capture spec links deep in long pages
    // (e.g. Mailchimp's spec link appears after ~200KB of endpoint docs)
    string capped = body.length() > 500000 ? body.substring(0, 500000) : body;
    log:printInfo(string `    [browserless] OK — ${body.length()} bytes (capped to ${capped.length()})`);
    return capped;
}

// Minimum visible text length to consider a plain-HTTP response "useful".
// Pages below this threshold are treated as SPA shells and retried via Browserless.
// 500 chars is enough to detect a real page vs an empty React/Vue container.
const int MIN_USEFUL_TEXT_LENGTH = 500;

function httpGetBody(string url) returns string|error {
    string ghToken = os:getEnv("GITHUB_TOKEN");
    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
    if url.includes("api.github.com") && ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

    // Raw content (GitHub API, spec files): plain HTTP only, no browser needed.
    if isRawContentUrl(url) {
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

    // HTML docs pages strategy:
    //   1. Try plain HTTP with a generous 500KB cap
    //   2. Check if the response has enough visible text to be useful
    //   3. If not (SPA shell) — use Browserless for full JS rendering
    //
    // The 500KB cap is important: some pages (like Mailchimp) embed the spec
    // version link deep in the body, after hundreds of KB of endpoint docs.
    string|error plainResult = httpGetBodyPlain(url, headers, 500000);

    if plainResult is string {
        string textContent = htmlText(plainResult);
        if textContent.length() >= MIN_USEFUL_TEXT_LENGTH {
            // Plain HTTP returned a real page with enough content
            log:printInfo(string `    [plain-http] OK — ${plainResult.length()} bytes (${textContent.length()} chars text)`);
            return plainResult;
        }
        log:printInfo(string `    [plain-http] SPA detected (only ${textContent.length()} chars text) — trying Browserless`);
    } else {
        log:printInfo(string `    [plain-http] failed: ${plainResult.message()} — trying Browserless`);
    }

    // Use Browserless for full JS rendering
    string browserlessToken = os:getEnv("BROWSERLESS_TOKEN");
    if browserlessToken.length() > 0 {
        string|error browserResult = httpGetBodyViaBrowserless(url);
        if browserResult is string {
            return browserResult;
        }
        log:printInfo(string `    [browserless] also failed: ${browserResult.message()} — using plain HTTP fallback`);
    } else {
        log:printInfo("    [browser-warn] BROWSERLESS_TOKEN not set — SPA pages may have missing content.");
    }

    // Last resort: return whatever plain HTTP gave us
    if plainResult is string {
        return plainResult;
    }
    return plainResult;
}

// Plain HTTP fetch. maxBytes controls how much of the response body we keep.
// Using 500KB instead of the old 150KB to avoid cutting off content in long pages.
function httpGetBodyPlain(string url, map<string|string[]> headers, int maxBytes) returns string|error {
    return httpGetBodyPlainInner(url, headers, maxBytes);
}

function httpGetBodyPlainInner(string url, map<string|string[]> headers, int maxBytes) returns string|error {
    http:Client cl = check new (url, {
        followRedirects: {enabled: true, maxCount: 5},
        timeout: 12,
        secureSocket: {enable: true}
    });
    http:Response resp = check cl->get("", headers);
    if resp.statusCode != 200 {
        return error(string `HTTP ${resp.statusCode}`);
    }
    string body = check resp.getTextPayload();
    return body.length() > maxBytes ? body.substring(0, maxBytes) : body;
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
