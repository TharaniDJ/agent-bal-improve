// validator.bal
// Programmatic OpenAPI / Swagger spec validation.
// Zero LLM involvement — every candidate URL is:
//   1. HEAD-checked (fast, no body download)
//   2. Downloaded with GET
//   3. Format-detected (yaml / json)
//   4. Parsed with minimal JSON / YAML key scanners
//   5. Checked for "openapi" or "swagger" root key
//   6. info.title and info.version extracted
//
// bestResult() tries a list of candidates and returns the highest-scoring
// valid one (higher OpenAPI version wins; YAML preferred over JSON).

import ballerina/log;

// ---------------------------------------------------------------------------
// Internal string helpers
// ---------------------------------------------------------------------------

isolated function splitOnChar(string text, string sep) returns string[] {
    string[] parts = [];
    string rem = text;
    while rem.length() > 0 {
        int? idx = rem.indexOf(sep);
        if idx is int {
            parts.push(rem.substring(0, idx));
            rem = rem.substring(idx + sep.length());
        } else {
            parts.push(rem);
            break;
        }
    }
    return parts;
}

isolated function splitLines(string text) returns string[] {
    return splitOnChar(text, "\n");
}

isolated function stripQuotes(string s) returns string {
    if s.length() > 1 {
        if (s.startsWith("\"") && s.endsWith("\"")) ||
           (s.startsWith("'") && s.endsWith("'")) {
            return s.substring(1, s.length() - 1);
        }
    }
    return s;
}

// ---------------------------------------------------------------------------
// Minimal JSON top-level key extractor
// Handles:  "key": "string_value"   and   "key": numeric_value
// ---------------------------------------------------------------------------

isolated function jsonString(string text, string key) returns string? {
    string pat = "\"" + key + "\"";
    int? idx = text.indexOf(pat);
    if idx is () {
        return ();
    }
    int pos = idx + pat.length();

    // Skip whitespace and the colon separator
    while pos < text.length() {
        string ch = text[pos];
        if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == ":" {
            pos += 1;
        } else {
            break;
        }
    }
    if pos >= text.length() {
        return ();
    }

    if text[pos] == "\"" {
        // Quoted string value — read until unescaped closing quote
        int valueStart = pos + 1;
        int end = valueStart;
        while end < text.length() {
            if text[end] == "\"" && (end == valueStart || text[end - 1] != "\\") {
                break;
            }
            end += 1;
        }
        return text.substring(valueStart, end);
    } else {
        // Numeric / boolean — read until delimiter
        int valueStart = pos;
        int end = valueStart;
        while end < text.length() {
            string ch = text[end];
            if ch == "," || ch == "}" || ch == "\n" || ch == "\r" {
                break;
            }
            end += 1;
        }
        string val = text.substring(valueStart, end).trim();
        return val.length() > 0 ? val : ();
    }
}

// ---------------------------------------------------------------------------
// Minimal YAML top-level key extractor
// Finds lines of the form:   key: value   (leading spaces OK)
// ---------------------------------------------------------------------------

isolated function yamlString(string text, string key) returns string? {
    string prefix = key + ":";
    foreach string raw in splitLines(text) {
        string line = raw.trim();
        if line.startsWith(prefix) {
            string val = line.substring(prefix.length()).trim();
            // Strip inline YAML comment
            int? commentIdx = val.indexOf(" #");
            if commentIdx is int {
                val = val.substring(0, commentIdx).trim();
            }
            if val.length() > 0 {
                return stripQuotes(val);
            }
        }
    }
    return ();
}

// ---------------------------------------------------------------------------
// Format detection
// ---------------------------------------------------------------------------

isolated function detectFormat(string url, string contentType, string body) returns string {
    string lo = url.toLowerAscii();
    if lo.endsWith(".yaml") || lo.endsWith(".yml") || contentType.includes("yaml") {
        return "yaml";
    }
    if lo.endsWith(".json") || contentType.includes("json") {
        return "json";
    }
    string t = body.trim();
    if t.startsWith("openapi:") || t.startsWith("swagger:") || t.startsWith("---") {
        return "yaml";
    }
    return t.startsWith("{") ? "json" : "yaml";
}

// ---------------------------------------------------------------------------
// Extract OpenAPI metadata from spec body
// Returns [openapiVersion, title, apiVersion]  (all nullable)
// ---------------------------------------------------------------------------

isolated function extractMeta(string body, string fmt) returns [string?, string?, string?] {
    string? openapiVer = ();
    string? title = ();
    string? apiVersion = ();

    if fmt == "json" {
        openapiVer = jsonString(body, "openapi") ?: jsonString(body, "swagger");
        int? infoIdx = body.indexOf("\"info\"");
        if infoIdx is int {
            int endPos = infoIdx + 3000 < body.length() ? infoIdx + 3000 : body.length();
            string snippet = body.substring(infoIdx, endPos);
            title = jsonString(snippet, "title");
            apiVersion = jsonString(snippet, "version");
        }
    } else {
        // YAML
        openapiVer = yamlString(body, "openapi") ?: yamlString(body, "swagger");

        // Walk lines to extract info.title and info.version from the info block
        boolean inInfo = false;
        foreach string rawLine in splitLines(body) {
            string trimmed = rawLine.trim();

            if trimmed.startsWith("info:") {
                inInfo = true;
                continue;
            }
            if !inInfo {
                continue;
            }
            if trimmed.length() == 0 || trimmed.startsWith("#") {
                continue;
            }

            // Detect end of info block: a non-blank, non-comment line with zero indent
            int indent = 0;
            foreach string ch in rawLine {
                if ch == " " || ch == "\t" {
                    indent += 1;
                } else {
                    break;
                }
            }
            if indent == 0 {
                inInfo = false;
                continue;
            }

            if trimmed.startsWith("title:") {
                title = stripQuotes(trimmed.substring(6).trim());
            } else if trimmed.startsWith("version:") {
                apiVersion = stripQuotes(trimmed.substring(8).trim());
            }
        }
    }
    return [openapiVer, title, apiVersion];
}

// ---------------------------------------------------------------------------
// Version scoring — used to rank multiple valid candidates
// "3.1.0" -> 3.01  (higher is better)
// YAML gets a small bonus over JSON at the same version
// ---------------------------------------------------------------------------

isolated function versionScore(string ver) returns float {
    float score = 0.0;
    float mult = 1.0;
    foreach string part in splitOnChar(ver, ".") {
        float|error n = float:fromString(part.trim());
        if n is float {
            score += n * mult;
        }
        mult /= 100.0;
    }
    return score;
}

// ---------------------------------------------------------------------------
// validateSpec — download and validate a single URL
// Returns ValidatedCandidate on success, () on any failure
// ---------------------------------------------------------------------------

public function validateSpec(string url) returns ValidatedCandidate? {
    log:printInfo(string `    [validate] ${url}`);

    FetchResult|error fr = httpGet(url);
    if fr is error {
        log:printInfo(string `      fail: ${fr.message()}`);
        return ();
    }
    if fr.status != 200 {
        log:printInfo(string `      fail: HTTP ${fr.status}`);
        return ();
    }

    string fmt = detectFormat(url, fr.contentType, fr.body);
    var [openapiVer, title, apiVersion] = extractMeta(fr.body, fmt);

    if openapiVer is () {
        log:printInfo("      fail: no openapi/swagger key");
        return ();
    }

    float score = versionScore(openapiVer) + (fmt == "yaml" ? 0.01 : 0.0);
    log:printInfo(string `      ok: openapi=${openapiVer} title=${title ?: "?"} fmt=${fmt}`);
    return {url, openapiVersion: openapiVer, apiVersion, title, format: fmt, score};
}

// ---------------------------------------------------------------------------
// bestResult — HEAD-check then validate a list of candidate URLs.
// Returns the highest-scoring valid result, or () if none pass.
// ---------------------------------------------------------------------------

public function bestResult(string[] candidates) returns ValidatedCandidate? {
    ValidatedCandidate[] valid = [];
    map<boolean> seen = {};

    foreach string rawUrl in candidates {
        string url = rawUrl.trim();
        if url.length() == 0 || !startsWithHttp(url) {
            continue;
        }
        // Normalise GitHub blob links to raw URLs
        if url.includes("github.com") && url.includes("/blob/") {
            url = blobToRaw(url);
        }
        if seen.hasKey(url) {
            continue;
        }
        seen[url] = true;

        log:printInfo(string `    [head] ${url}`);
        if !headOk(url) {
            log:printInfo("      unreachable");
            continue;
        }

        ValidatedCandidate? vc = validateSpec(url);
        if vc is ValidatedCandidate {
            valid.push(vc);
        }
    }

    if valid.length() == 0 {
        return ();
    }

    // Sort descending by score; pick the best
    ValidatedCandidate[] sorted = valid.sort(
        "descending",
        isolated function(ValidatedCandidate c) returns float => c.score
    );
    return sorted[0];
}
