// agent.bal
// Shared utilities used by all pipeline steps:
//   - executeFetchPage()  — tool handler (HTML/JSON/YAML fetch + parse)
//   - callClaude()        — Anthropic API call
//   - httpGetBody()       — raw HTTP GET, with dynamic SPA detection + browser fallback
//   - headOk()            — HEAD check
//   - HTML/string utils

import ballerina/http;
import ballerina/log;
import ballerina/os;

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

// ─── Browser service port ─────────────────────────────────────────────────────
const int BROWSER_SERVICE_PORT = 3456;

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

        // JSON / GitHub API
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
        int otherCap = otherLinks.length() > 60 ? 60 : otherLinks.length();

        return string `{"type":"html","spec_links":${jsonArr(specLinks)},"page_text":${jsonStr(txtSnippet)},"other_links":${jsonArr(otherLinks.slice(0, otherCap))}}`;
    } on fail error e {
        log:printInfo(string `      [fetch] unexpected error: ${e.message()}`);
        return EMPTY_HTML_RESULT;
    }
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

isolated function isRawContentUrl(string url) returns boolean {
    string lo = url.toLowerAscii();
    if lo.includes("api.github.com") { return true; }
    if lo.endsWith(".yaml") || lo.endsWith(".yml") { return true; }
    if lo.endsWith(".json") { return true; }
    return false;
}

isolated function isBrowserServiceAvailable() returns boolean {
    do {
        http:Client cl = check new (string `http://localhost:${BROWSER_SERVICE_PORT}`, {timeout: 2});
        http:Response r = check cl->get("/health");
        return r.statusCode == 200;
    } on fail {
        return false;
    }
}

function httpGetBodyViaBrowser(string url) returns string|error {
    log:printInfo(string `    [browser-fetch] ${url}`);
    http:Client cl = check new (string `http://localhost:${BROWSER_SERVICE_PORT}`, {timeout: 20});
    http:Response resp = check cl->get(string `/fetch?url=${url}`);
    if resp.statusCode != 200 {
        string errBody = check resp.getTextPayload();
        return error(string `Browser service error ${resp.statusCode}: ${errBody}`);
    }
    json respJson = check resp.getJsonPayload();
    if respJson is map<json> {
        json? htmlVal = respJson["html"];
        if htmlVal is string {
            string capped = htmlVal.length() > 50000 ? htmlVal.substring(0, 50000) : htmlVal;
            log:printInfo(string `    [browser-fetch] OK — ${htmlVal.length()} bytes (capped to ${capped.length()})`);
            return capped;
        }
        json? errVal = respJson["error"];
        if errVal is string {
            return error(string `Browser service: ${errVal}`);
        }
    }
    return error("Browser service returned unexpected response");
}

function httpGetBody(string url) returns string|error {
    string ghToken = os:getEnv("GITHUB_TOKEN");
    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
    if url.includes("api.github.com") && ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

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

    if isBrowserServiceAvailable() {
        return httpGetBodyViaBrowser(url);
    }

    log:printInfo(string `    [browser-warn] browser service not running — plain HTTP fallback for ${url}`);
    log:printInfo("    [browser-warn] Start with: node browser-service/server.js");
    http:Client cl = check new (url, {
        followRedirects: {enabled: true, maxCount: 5},
        timeout: 8,
        secureSocket: {enable: true}
    });
    http:Response resp = check cl->get("", headers);
    if resp.statusCode != 200 {
        return error(string `HTTP ${resp.statusCode}`);
    }
    string body = check resp.getTextPayload();
    if body.length() > 150000 {
        return body.substring(0, 150000);
    }
    return body;
}

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
