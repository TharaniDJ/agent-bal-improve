// main.bal
// Entry point — runs the agent for each connector.
//
// The agent always re-checks every connector, even if a URL already
// exists in the output file. This ensures we always find the latest.
//
// Usage:
//   ANTHROPIC_API_KEY=sk-...  bal run .
//   ANTHROPIC_API_KEY=sk-...  FILTER=github bal run .
//   ANTHROPIC_API_KEY=sk-...  GITHUB_TOKEN=ghp_...  bal run .
//   DRY_RUN=true bal run .

import ballerina/io;
import ballerina/log;
import ballerina/os;
import ballerina/time;
import ballerina/file;

configurable string outputFile = "openapi_specs.json";

const string BAR  = "================================================================";
const string DASH = "----------------------------------------------------------------";

public function main() returns error? {
    string apiKey    = os:getEnv("ANTHROPIC_API_KEY");
    string filterStr = os:getEnv("FILTER").toLowerAscii();
    boolean dryRun   = os:getEnv("DRY_RUN").toLowerAscii() == "true";
    string outFile   = os:getEnv("OUTPUT").length() > 0 ? os:getEnv("OUTPUT") : outputFile;
    string ghToken   = os:getEnv("GITHUB_TOKEN");
    string model     = os:getEnv("CLAUDE_MODEL").length() > 0 ? os:getEnv("CLAUDE_MODEL") : "claude-sonnet-4-6";

    Connector[] connectors = filterStr.length() > 0
        ? ALL_CONNECTORS.filter(c => c.name.toLowerAscii().includes(filterStr))
        : ALL_CONNECTORS;

    // Dry run
    if dryRun {
        io:println(BAR);
        io:println(string `  OpenAPI Spec Finder — ${connectors.length()} connector(s)`);
        io:println(DASH);
        int i = 1;
        foreach Connector c in connectors {
            string t = c.targetTitle is string ? string ` [${c.targetTitle ?: ""}]` : "";
            io:println(string `  ${lp(i.toString(), 2)}. ${pad(c.name, 30)} ${c.docsUrl}${t}`);
            i += 1;
        }
        io:println(BAR);
        return;
    }

    if apiKey.length() == 0 {
        io:println("ERROR: set ANTHROPIC_API_KEY");
        return;
    }

    io:println(BAR);
    io:println("  OpenAPI Spec Finder");
    io:println(string `  Model  : ${model}`);
    io:println(string `  GitHub : ${ghToken.length() > 0 ? "token set" : "no token (rate limit: 60/hr)"}`);
    io:println(string `  Output : ${outFile}`);
    io:println(string `  APIs   : ${connectors.length()}`);
    io:println(BAR);
    io:println("");

    // Load existing results to merge into
    ResultEntry[] existing = loadResults(outFile);
    map<int> existingIdx = {};
    int ei = 0;
    foreach ResultEntry r in existing {
        existingIdx[r.name] = ei;
        ei += 1;
    }

    ResultEntry[] results = existing;
    time:Utc runStart = time:utcNow();
    int found = 0;
    int notFound = 0;

    int idx = 1;
    foreach Connector c in connectors {
        string label = c.targetTitle is string ? string `${c.name} / ${c.targetTitle ?: ""}` : c.name;
        io:println(string `[${lp(idx.toString(), 2)}/${connectors.length()}] ${label}`);

        string? knownUrl = ();
        string? knownRepo = ();
        if existingIdx.hasKey(c.name) {
            ResultEntry prev = results[existingIdx.get(c.name)];
            knownUrl  = prev.specUrl;
            knownRepo = prev.specRepo;
        }
        if knownUrl is string {
            io:println(string `         prev: ${knownUrl}`);
        }

        time:Utc t0 = time:utcNow();
        SpecResult? finalResult = ();

        if knownUrl is string {
            // ── Path A: We have a known URL ──────────────────────────────────────

            if !knownUrl.includes("raw.githubusercontent.com") {
                // A1: Stable direct endpoint (Candid, Elastic, Mailchimp, Trello etc.)
                // HEAD check + content sniff is enough — these always serve current version
                log:printInfo("  [pipeline] path=stable-endpoint");
                finalResult = stepQuickVerify(knownUrl, knownRepo);

                if finalResult is () {
                    // URL is dead — fall through to full re-discovery
                    log:printInfo("  [pipeline] stable URL dead — re-discovering");
                    DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo);
                    finalResult = stepContentVerify(disc);
                }

            } else {
                // A2: GitHub raw URL — must check for newer version in parent folder
                log:printInfo("  [pipeline] path=github-version-check");
                SpecResult?|string checkResult = stepGithubVersionCheck(knownUrl, knownRepo, apiKey);

                if checkResult is SpecResult {
                    // Got a valid result (same or newer URL)
                    finalResult = checkResult;
                } else {
                    // "DEAD" or () — need full re-discovery
                    log:printInfo("  [pipeline] GitHub check failed — re-discovering");
                    DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo);
                    finalResult = stepContentVerify(disc);
                }
            }

        } else {
            // ── Path B: No known URL — full discovery ────────────────────────────
            log:printInfo("  [pipeline] path=full-discovery");
            DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo);
            finalResult = stepContentVerify(disc);
        }

        decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));

        ResultEntry entry;
        if finalResult is SpecResult {
            found += 1;
            io:println(string `  => ${finalResult.specUrl}`);
            io:println(string `     format=${finalResult.format} | ${elapsed}s`);
            entry = {
                name:          c.name,
                docsUrl:       c.docsUrl,
                targetTitle:   c.targetTitle,
                specUrl:       finalResult.specUrl,
                specRepo:      finalResult.specRepo,
                title:         finalResult.title,
                apiVersion:    finalResult.apiVersion,
                format:        finalResult.format,
                status:        "found",
                checkedAt:     time:utcToString(time:utcNow()),
                elapsedSeconds: elapsed
            };
        } else {
            notFound += 1;
            io:println(string `  => NOT FOUND [${elapsed}s]`);
            entry = {
                name:          c.name,
                docsUrl:       c.docsUrl,
                targetTitle:   c.targetTitle,
                specUrl:       (),
                specRepo:      (),
                title:         (),
                apiVersion:    (),
                format:        (),
                status:        "not_found",
                checkedAt:     time:utcToString(time:utcNow()),
                elapsedSeconds: elapsed
            };
        }
        io:println("");

        if existingIdx.hasKey(c.name) {
            int eIdx = existingIdx.get(c.name);
            results[eIdx] = entry;
        } else {
            existingIdx[c.name] = results.length();
            results.push(entry);
        }

        check saveResults(results, outFile);
        idx += 1;
    }

    decimal total = rd(time:utcDiffSeconds(time:utcNow(), runStart));
    io:println(BAR);
    io:println(string `  Done in ${<int>total}s  |  found=${found}  not_found=${notFound}`);
    io:println(string `  Saved to ${outFile}`);
    io:println(BAR);
}

// ─── Persistence ──────────────────────────────────────────────────────────────

function loadResults(string path) returns ResultEntry[] {
    do {
        boolean exists = check file:test(path, file:EXISTS);
        if !exists { return []; }
        string content = check io:fileReadString(path);
        ResultEntry[]|error parsed = content.fromJsonStringWithType();
        if parsed is ResultEntry[] { return parsed; }
    } on fail { }
    return [];
}

function saveResults(ResultEntry[] results, string path) returns error? {
    check io:fileWriteString(path, results.toJson().toJsonString());
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

isolated function pad(string s, int w) returns string {
    string r = s;
    int i = s.length();
    while i < w { r += " "; i += 1; }
    return r;
}

isolated function lp(string s, int w) returns string {
    string r = "";
    int i = s.length();
    while i < w { r += " "; i += 1; }
    return r + s;
}

isolated function rd(decimal d) returns decimal {
    return <decimal>(<int>(d * 10d)) / 10d;
}
