// main.bal
// Entry point — runs the agent for each connector in parallel batches.
//
// Usage:
//   ANTHROPIC_API_KEY=sk-...  bal run .
//   ANTHROPIC_API_KEY=sk-...  FILTER=github bal run .
//   ANTHROPIC_API_KEY=sk-...  GITHUB_TOKEN=ghp_...  bal run .
//   ANTHROPIC_API_KEY=sk-...  CONCURRENCY=10 bal run .
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
    string apiKey      = os:getEnv("ANTHROPIC_API_KEY");
    string filterStr   = os:getEnv("FILTER").toLowerAscii();
    boolean dryRun     = os:getEnv("DRY_RUN").toLowerAscii() == "true";
    string outFile     = os:getEnv("OUTPUT").length() > 0 ? os:getEnv("OUTPUT") : outputFile;
    string ghToken     = os:getEnv("GITHUB_TOKEN");
    string model       = os:getEnv("CLAUDE_MODEL").length() > 0 ? os:getEnv("CLAUDE_MODEL") : "claude-sonnet-4-6";
    int    concurrency = 5;

    string concStr = os:getEnv("CONCURRENCY");
    if concStr.length() > 0 {
        int|error parsed = int:fromString(concStr);
        if parsed is int && parsed > 0 { concurrency = parsed; }
    }

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
            io:println(string `  ${lp(i.toString(), 2)}. ${pad(c.name, 30)} ${c.sourceUrl}${t}`);
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
    io:println(string `  Model       : ${model}`);
    io:println(string `  GitHub      : ${ghToken.length() > 0 ? "token set" : "no token (rate limit: 60/hr)"}`);
    io:println(string `  Output      : ${outFile}`);
    io:println(string `  APIs        : ${connectors.length()}`);
    io:println(string `  Concurrency : ${concurrency}`);
    io:println(BAR);
    io:println("");

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

    int batchStart = 0;
    while batchStart < connectors.length() {
        int batchEnd = batchStart + concurrency;
        if batchEnd > connectors.length() { batchEnd = connectors.length(); }

        Connector[] batch = connectors.slice(batchStart, batchEnd);
        io:println(string `--- batch ${batchStart + 1}–${batchEnd} of ${connectors.length()} ---`);

        future<ResultEntry>[] futures = [];
        Connector[] batchConnectors = [];
        foreach Connector c in batch {
            string? knownUrl = ();
            string? knownRepo = ();
            if existingIdx.hasKey(c.name) {
                ResultEntry prev = results[existingIdx.get(c.name)];
                knownUrl  = prev.specUrl;
                knownRepo = prev.specRepo;
            }
            future<ResultEntry> f = start processConnector(c, knownUrl, knownRepo, apiKey);
            futures.push(f);
            batchConnectors.push(c);
        }

        int fi = 0;
        foreach future<ResultEntry> f in futures {
            Connector bc = batchConnectors[fi];
            fi += 1;

            ResultEntry|error waitResult = wait f;
            ResultEntry entry;
            if waitResult is ResultEntry {
                entry = waitResult;
            } else {
                log:printInfo(string `  [${bc.name}] strand error: ${waitResult.message()}`);
                entry = {
                    name:           bc.name,
                    sourceUrl:      bc.sourceUrl,
                    targetTitle:    bc.targetTitle,
                    specUrl:        (),
                    specRepo:       (),
                    title:          (),
                    apiVersion:     (),
                    format:         (),
                    status:         "not_found",
                    checkedAt:      time:utcToString(time:utcNow()),
                    elapsedSeconds: 0d
                };
            }

            if entry.status == "found" {
                found += 1;
            } else {
                notFound += 1;
            }

            if existingIdx.hasKey(entry.name) {
                results[existingIdx.get(entry.name)] = entry;
            } else {
                existingIdx[entry.name] = results.length();
                results.push(entry);
            }
        }

        check saveResults(results, outFile);
        io:println("");
        batchStart = batchEnd;
    }

    decimal total = rd(time:utcDiffSeconds(time:utcNow(), runStart));
    io:println(BAR);
    io:println(string `  Done in ${<int>total}s  |  found=${found}  not_found=${notFound}`);
    io:println(string `  Saved to ${outFile}`);
    io:println(BAR);
}

// ─── Per-connector work ───────────────────────────────────────────────────────

function processConnector(
    Connector c,
    string? knownUrl,
    string? knownRepo,
    string apiKey
) returns ResultEntry {

    string label = c.targetTitle is string ? string `${c.name} / ${c.targetTitle ?: ""}` : c.name;

    if knownUrl is string {
        io:println(string `[start] ${label}  (prev: ${knownUrl})`);
    } else {
        io:println(string `[start] ${label}`);
    }

    time:Utc t0 = time:utcNow();
    SpecResult? finalResult = ();

    if knownUrl is string {
        if !knownUrl.includes("raw.githubusercontent.com") {
            log:printInfo(string `  [${c.name}] path=stable-version-check`);
            SpecResult?|string stableResult = stepQuickVerify(knownUrl, knownRepo, c.sourceUrl, apiKey);

            if stableResult is SpecResult {
                finalResult = stableResult;
            } else {
                log:printInfo(string `  [${c.name}] stable URL dead or outdated — re-discovering`);
                DiscoveryResult disc = stepDiscovery(c.sourceUrl, c.name, c.targetTitle, apiKey, knownRepo);
                finalResult = stepContentVerify(disc);
            }

        } else {
            log:printInfo(string `  [${c.name}] path=github-version-check`);
            SpecResult?|string checkResult = stepGithubVersionCheck(knownUrl, knownRepo, apiKey);

            if checkResult is SpecResult {
                finalResult = checkResult;
            } else {
                log:printInfo(string `  [${c.name}] GitHub check failed — re-discovering`);
                DiscoveryResult disc = stepDiscovery(c.sourceUrl, c.name, c.targetTitle, apiKey, knownRepo);
                finalResult = stepContentVerify(disc);
            }
        }

    } else {
        log:printInfo(string `  [${c.name}] path=full-discovery`);
        DiscoveryResult disc = stepDiscovery(c.sourceUrl, c.name, c.targetTitle, apiKey, knownRepo);
        finalResult = stepContentVerify(disc);
    }

    decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));

    if finalResult is SpecResult {
        io:println(string `[done ] ${label}`);
        io:println(string `  => ${finalResult.specUrl}`);
        io:println(string `     format=${finalResult.format} | ${elapsed}s`);
        return {
            name:           c.name,
            sourceUrl:      c.sourceUrl,
            targetTitle:    c.targetTitle,
            specUrl:        finalResult.specUrl,
            specRepo:       finalResult.specRepo,
            title:          finalResult.title,
            apiVersion:     finalResult.apiVersion,
            format:         finalResult.format,
            status:         "found",
            checkedAt:      time:utcToString(time:utcNow()),
            elapsedSeconds: elapsed
        };
    } else {
        io:println(string `[done ] ${label} => NOT FOUND [${elapsed}s]`);
        return {
            name:           c.name,
            sourceUrl:      c.sourceUrl,
            targetTitle:    c.targetTitle,
            specUrl:        (),
            specRepo:       (),
            title:          (),
            apiVersion:     (),
            format:         (),
            status:         "not_found",
            checkedAt:      time:utcToString(time:utcNow()),
            elapsedSeconds: elapsed
        };
    }
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
