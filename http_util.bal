// http_util.bal
// Low-level HTTP helpers shared by all strategy functions.

import ballerina/http;
import ballerina/log;
import ballerina/mime;

// Sent with every outgoing request.
final map<string|string[]> & readonly REQUEST_HEADERS = {
    "User-Agent": "OpenAPI-Spec-Finder/5.0"
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

public type FetchResult record {|
    int status;
    string body;
    string contentType;
|};

// ---------------------------------------------------------------------------
// HTTP GET
// Follows redirects (up to 5).  Returns FetchResult on HTTP 200, error otherwise.
// ---------------------------------------------------------------------------

public function httpGet(string url) returns FetchResult|error {
    http:Client cl = check new (url, {
        followRedirects: {enabled: true, maxCount: 5},
        timeout: 20,
        secureSocket: {enable: true}
    });
    http:Response resp = check cl->get("", REQUEST_HEADERS);
    string body = check resp.getTextPayload();
    string ct = "";
    string|http:HeaderNotFoundError ctHeader = resp.getHeader(mime:CONTENT_TYPE);
    if ctHeader is string {
        ct = ctHeader;
    }
    return {status: resp.statusCode, body, contentType: ct};
}

// ---------------------------------------------------------------------------
// HEAD check — fast reachability probe.
// Falls back to GET (stream) when server returns 405 Method Not Allowed.
// Returns true only on HTTP 200.
// ---------------------------------------------------------------------------

public function headOk(string url) returns boolean {
    do {
        http:Client cl = check new (url, {
            followRedirects: {enabled: true, maxCount: 5},
            timeout: 10,
            secureSocket: {enable: true}
        });
        http:Response resp = check cl->head("", REQUEST_HEADERS);
        if resp.statusCode == 200 {
            return true;
        }
        if resp.statusCode == 405 || resp.statusCode == 501 {
            // Server doesn't allow HEAD — try GET
            http:Response getResp = check cl->get("", REQUEST_HEADERS);
            return getResp.statusCode == 200;
        }
        return false;
    } on fail error e {
        log:printDebug(string `headOk failed for ${url}: ${e.message()}`);
        return false;
    }
}

// ---------------------------------------------------------------------------
// Convert a github.com blob URL to a raw.githubusercontent.com URL.
//   https://github.com/owner/repo/blob/branch/path/file.yaml
//   -> https://raw.githubusercontent.com/owner/repo/branch/path/file.yaml
// ---------------------------------------------------------------------------

public isolated function blobToRaw(string url) returns string {
    string result = url;
    if result.startsWith("https://github.com/") {
        result = "https://raw.githubusercontent.com/" + result.substring(19);
    }
    int? blobIdx = result.indexOf("/blob/");
    if blobIdx is int {
        result = result.substring(0, blobIdx) + "/" + result.substring(blobIdx + 6);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

public isolated function startsWithHttp(string s) returns boolean {
    return s.startsWith("http://") || s.startsWith("https://");
}

// Returns true if the URL looks like it might be an OpenAPI spec file.
public isolated function looksLikeSpecUrl(string url) returns boolean {
    string lo = url.toLowerAscii();
    string[] keywords = [
        "openapi", "swagger", "api-spec", "apispec",
        ".yaml", ".yml",
        "raw.githubusercontent", "spec3", "rest-api-description", "/defs/"
    ];
    foreach string kw in keywords {
        if lo.includes(kw) {
            return true;
        }
    }
    // .json only if paired with an API keyword to avoid false positives
    if lo.endsWith(".json") && (lo.includes("api") || lo.includes("spec")) {
        return true;
    }
    return false;
}
