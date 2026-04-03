// agent.bal
// Agentic OpenAPI spec finder powered by Claude.
//
// On every run the agent:
//   1. Navigates to find (or re-verify) the spec URL
//   2. Checks whether the previously found URL is still the LATEST version
//   3. Returns the confirmed latest URL
//
// Memory (knownSpecUrl + knownSpecRepo) is passed in from openapi_specs.json
// so the agent can go straight to the source and verify, not search blind.

import ballerina/http;
import ballerina/log;
import ballerina/os;
import ballerina/time;

// ─── System prompt ────────────────────────────────────────────────────────────

const string SYSTEM_PROMPT =
    "You are an expert at finding the LATEST publicly available OpenAPI or Swagger " +
    "specification file for any REST API. You run on a schedule and must verify on " +
    "every run that the spec URL you return is still the most recently updated one.\n" +
    "\n" +
    "## What you are looking for\n" +
    "A directly downloadable YAML or JSON file whose root-level content contains " +
    "`openapi:` (e.g. `openapi: 3.1.0`) or `swagger:` (e.g. `swagger: '2.0'`). " +
    "It must be publicly accessible without authentication.\n" +
    "\n" +
    "## Tool: fetch_page\n" +
    "Fetches any URL. Returns:\n" +
    "  - HTML page  → { spec_links: [...], page_text: \"...\", other_links: [...] }\n" +
    "  - JSON file  → { type: \"json\", content: \"<first 12 KB>\" }\n" +
    "  - YAML file  → { type: \"yaml\", content: \"<first 12 KB>\" }\n" +
    "\n" +
    "Strict rules — violations waste your limited fetches:\n" +
    "  - Maximum 8 fetch_page calls per task.\n" +
    "  - Never fetch the same URL twice.\n" +
    "  - Never fetch github.com/blob/ or github.com/tree/ pages (HTML, not files).\n" +
    "  - To list files in a GitHub repo folder, use the Contents API:\n" +
    "      https://api.github.com/repos/OWNER/REPO/contents/PATH\n" +
    "    This returns a JSON array of {name, type, path, download_url} entries.\n" +
    "  - Only use the recursive tree API when you need a full flat listing:\n" +
    "      https://api.github.com/repos/OWNER/REPO/git/trees/HEAD?recursive=1\n" +
    "    WARNING: large repos truncate this response. If truncated is true or " +
    "    expected paths are missing, switch to the Contents API to drill in folder by folder.\n" +
    "\n" +
    "## Known SPA domains — do NOT fetch docs page, go straight to GitHub\n" +
    "These docs pages are JavaScript SPAs that return no useful content.\n" +

    "\n" +
    "## How to find the spec (generic strategy)\n" +
    "\n" +
    "─────────────────────────────────────────────────────────────────\n" +
    "CASE A: A previously found spec URL is given in the user message\n" +
    "─────────────────────────────────────────────────────────────────\n" +
    "Your goal is to confirm the URL is still the LATEST version.\n" +
    "\n" +
    "  A1. Fetch the previously found URL.\n" +
    "      - If 404 or no spec content → spec moved; go to CASE B.\n" +
    "      - If valid spec content → proceed to A2.\n" +
    "\n" +
    "  A2. Check for newer versions based on hosting:\n" +
    "\n" +
    "      If URL is raw.githubusercontent.com/OWNER/REPO/...:\n" +
    "        - Use the Contents API to check the parent folder for newer siblings.\n" +
    "        - Prefer files whose name contains: openapi, swagger, api, spec.\n" +
    "        - Skip folders named: staging, prerelease, preview, draft, canary, beta, alpha, rc.\n" +
    "        - If something newer exists → return that. Otherwise → return original.\n" +
    "\n" +
    "      If URL is a direct API endpoint (not GitHub):\n" +
    "        - Stable URL always serves the current version.\n" +
    "        - If A1 confirmed valid → return immediately.\n" +
    "\n" +
    "─────────────────────────────────────────────────────────────────\n" +
    "CASE B: No previously found URL or previous URL is invalid\n" +
    "─────────────────────────────────────────────────────────────────\n" +
    "\n" +
    "  B1. Fetch the docs URL (unless it is a known SPA domain — see above).\n" +
    "      - If it returns nearly empty page_text (under 200 chars) or no spec_links\n" +
    "        and no github.com links → the page is likely a JavaScript SPA.\n" +
    "        In that case:\n" +
    "          * Check if the user message contains a knownSpecRepo — if so,\n" +
    "            go directly to the Contents API for that repo.\n" +
    "          * Otherwise infer the GitHub org/repo from the API name or docs URL\n" +
    "            and try: https://api.github.com/repos/<org>/<repo>/contents/\n" +
    "      - If it returns a GitHub repo URL → use Contents API, not HTML tree page.\n" +
    "      - If it returns direct spec links → follow them.\n" +
    "\n" +
    "  B2. Follow the most promising lead:\n" +
    "      - github.com/OWNER/REPO → Contents API → drill down → find spec file\n" +
    "      - Direct .yaml/.json URL → fetch and verify openapi:/swagger: content\n" +
    "      - Docs/reference/download page → follow → look for spec links\n" +
    "\n" +
    "  B3. When selecting among multiple spec files → prefer:\n" +
    "      - Names containing: openapi, swagger, api, spec\n" +
    "      - Root, /spec/, /openapi/, /defs/, /swagger/ over deeply nested paths\n" +
    "      - Avoid: test/, example/, archive/, staging/, preview/ directories\n" +
    "      - Highest OpenAPI/Swagger version wins (3.1.0 > 3.0.0 > 2.0)\n" +
    "      - YAML preferred over JSON at the same version\n" +
    "      - Default branch (main/master) preferred over tagged releases\n" +
    "\n" +
    "  B4. Always verify: fetch the candidate and confirm `openapi:` or `swagger:`.\n" +
    "\n" +
    "  B5. If the page lists multiple specs, the user message will name a Target spec.\n" +
    "      Match by title and fetch only that spec.\n" +
    "\n" +
    "─────────────────────────────────────────────────────────────────\n" +
    "Output format — output EXACTLY one of these blocks, nothing else\n" +
    "─────────────────────────────────────────────────────────────────\n" +
    "When you have found and verified the spec URL:\n" +
    "\n" +
    "SPEC_CANDIDATES:\n" +
    "https://primary-confirmed-url\n" +
    "https://alternate-branch-url\n" +
    "\n" +
    "Optionally add a SPEC_REPO line for GitHub-hosted specs:\n" +
    "SPEC_REPO: owner/repo\n" +
    "\n" +
    "When no publicly accessible spec exists after exhausting your search:\n" +
    "NO_SPEC_FOUND\n" +
    "\n" +
    "Rules:\n" +
    "  - Only raw download URLs (never github.com/blob/ links)\n" +
    "  - Include both /main/ and /master/ branch variants for raw.githubusercontent.com URLs\n" +
    "  - No explanatory text before or after the output block\n";

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

function executeFetchPage(string url) returns string {
    log:printInfo(string `    [fetch] ${url}`);

    string|error body = httpGetBody(url);
    if body is error {
        log:printInfo(string `      error: ${body.message()}`);
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
}

// ─── Agent loop ───────────────────────────────────────────────────────────────

public function runAgent(
    string docsUrl,
    string apiName,
    string? targetTitle,
    string anthropicKey,
    string? knownSpecUrl = (),
    string? knownSpecRepo = ()
) returns SpecResult? {

    if anthropicKey.length() == 0 {
        log:printInfo("  ERROR: ANTHROPIC_API_KEY not set");
        return ();
    }

    string targetNote = targetTitle is string
        ? string `\n\nTarget spec: This docs page lists multiple API specs. ` +
          string `Find ONLY the one titled '${targetTitle}'. Ignore all others.`
        : "";

    // Tell Claude explicitly when the docs URL is a known SPA so it skips the fetch
    string spaNote = isKnownSpa(docsUrl)
        ? string `\n\nNOTE: The docs URL (${docsUrl}) is a JavaScript SPA — do NOT fetch it. ` +
          "Go directly to the GitHub Contents API. " +
          "Infer the GitHub org/repo from the API name if knownSpecRepo is not provided."
        : "";

    string memoryNote = "";
    if knownSpecUrl is string {
        memoryNote = string `\n\nPreviously found spec URL: ${knownSpecUrl}`;
        if knownSpecRepo is string {
            memoryNote += string `\nGitHub repo: ${knownSpecRepo}`;
            memoryNote += string `\nUse CASE A: fetch the spec URL first to verify it's still valid, ` +
                          string `then use the Contents API on the parent folder to check for newer ` +
                          string `siblings. Return the latest confirmed URL.`;
        } else {
            memoryNote += string `\nUse CASE A: fetch this URL first. If valid and latest, return it. ` +
                          string `If it fails or you find a newer version, search from the docs URL.`;
        }
    }

    string userMsg = string `Find the latest OpenAPI spec file URL for: ${apiName}
Docs URL: ${docsUrl}${targetNote}${spaNote}${memoryNote}

Follow the strategy in your instructions. Always verify the file content before outputting SPEC_CANDIDATES.`;

    json[] messages = [{"role": "user", "content": userMsg}];
    map<boolean> fetched = {};
    string model = os:getEnv("CLAUDE_MODEL");
    if model.length() == 0 { model = "claude-sonnet-4-6"; }

    // Per-agent timeout
    time:Utc agentStart = time:utcNow();
    int maxTurns = 12;
    decimal maxSeconds = 180.0;

    int turn = 0;
    while turn < maxTurns {
        turn += 1;

        decimal agentElapsed = time:utcDiffSeconds(time:utcNow(), agentStart);
        if agentElapsed > maxSeconds {
            log:printInfo(string `  [agent] timeout after ${agentElapsed}s — giving up`);
            return ();
        }

        log:printInfo(string `  [turn ${turn}]`);

        json|error resp = callClaude(anthropicKey, model, messages);
        if resp is error {
            log:printInfo(string `  [claude error] ${resp.message()}`);
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
            int preview = text.length() > 600 ? 600 : text.length();
            log:printInfo(string `  [claude] ${text.substring(0, preview)}${text.length() > 600 ? "..." : ""}`);
        }

        // Done — found candidates
        if text.includes("SPEC_CANDIDATES:") {
            return pickBestCandidate(text);
        }
        if text.includes("NO_SPEC_FOUND") {
            log:printInfo("  [agent] declared no spec found");
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
                                output = "{\"error\":\"already fetched this URL — do not fetch the same URL twice\"}";
                                log:printInfo(string `    [skip-dup] ${urlVal}`);
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

        // end_turn without candidates — nudge once before giving up
        if stopReason == "end_turn" {
            if turn < maxTurns - 1 {
                log:printInfo("  [agent] end_turn without result — nudging");
                messages.push({"role": "assistant", "content": blocks});
                messages.push({
                    "role": "user",
                    "content": "Output your result now: SPEC_CANDIDATES: followed by the URL(s) you found, or NO_SPEC_FOUND."
                });
                continue;
            } else {
                log:printInfo("  [agent] end_turn without result after nudge — giving up");
                return ();
            }
        }

        // Unexpected stop reason
        log:printInfo(string `  [agent] unexpected stop_reason='${stopReason}' at turn ${turn} — giving up`);
        return ();
    }

    log:printInfo(string `  [agent] turn limit (${maxTurns}) reached without result`);
    return ();
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

        // Normalise any stray github.com/blob/ links to raw
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

        // Add alternate branch variant for raw GitHub URLs
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

// Returns true for raw spec/API file URLs (GitHub API, .yaml, .yml, .json).
// These get the full 20s timeout. HTML docs pages get 8s and a 150KB body cap.
isolated function isRawContentUrl(string url) returns boolean {
    string lo = url.toLowerAscii();
    if lo.includes("api.github.com") { return true; }
    if lo.endsWith(".yaml") || lo.endsWith(".yml") { return true; }
    if lo.endsWith(".json") { return true; }
    return false;
}

// Known SPA domains whose docs pages return no useful content.
// Claude is also told about these in the system prompt and user message,
// but this function lets us add the spaNote to the user message proactively.
isolated function isKnownSpa(string url) returns boolean {
    string lo = url.toLowerAscii();
    string[] spaDomains = [
        "docs.stripe.com",
        "developers.zoom.us",
        "developer.paypal.com",
        "developers.docusign.com",
        "developer.salesforce.com",
        "platform.openai.com",
        "developers.google.com",
        "learn.microsoft.com",
        "discord.com/developers",
        "developer.atlassian.com",
        "developer.x.com",
        "developer.twitter.com",
        "developers.hubspot.com"
    ];
    foreach string domain in spaDomains {
        if lo.includes(domain) { return true; }
    }
    return false;
}

function httpGetBody(string url) returns string|error {
    string ghToken = os:getEnv("GITHUB_TOKEN");
    map<string|string[]> headers = {"User-Agent": "openapi-spec-finder/1.0"};
    if url.includes("api.github.com") && ghToken.length() > 0 {
        headers["Authorization"] = string `Bearer ${ghToken}`;
    }

    // Raw content (GitHub API, spec files) gets 20s.
    // HTML docs pages get 8s — we only need enough to extract links.
    // SPAs will either timeout quickly or return a tiny shell we detect immediately.
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

    // For HTML docs pages cap at 150 KB — enough to extract all links,
    // but skips the megabytes of minified JS bundled into SPA pages.
    if !isRawContentUrl(url) {
        string t = body.trim();
        boolean looksLikeHtml = !t.startsWith("openapi:") && !t.startsWith("swagger:") &&
                                !t.startsWith("---") && !t.startsWith("{") && !t.startsWith("[");
        if looksLikeHtml && body.length() > 150000 {
            return body.substring(0, 150000);
        }
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
