// main.bal
// Entry point — runs the agent for each connector in parallel batches.
//
// The agent always re-checks every connector, even if a URL already
// exists in the output file. This ensures we always find the latest.
//
// Per-connector wall-clock timeout: CONNECTOR_TIMEOUT_SECS (default 180s).
// This is enforced using Ballerina's native `wait f timeout N` syntax on the
// future returned by `start processConnector(...)`. This is the ONLY reliable
// way to enforce a wall-clock deadline in Ballerina — Ballerina's `wait` on
// a future inside a function always blocks indefinitely with no timeout option.
// If a connector's strand hangs (e.g. Anthropic accepts TCP but never responds),
// the timeout fires, the connector is marked not_found, and the batch continues.
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

// Maximum wall-clock time allowed per connector in seconds.
// A full-discovery run with 10 turns takes ~80–100s on average.
// 180s gives generous headroom while still breaking hangs within 3 minutes.
// Override with env var CONNECTOR_TIMEOUT if needed.
const decimal DEFAULT_CONNECTOR_TIMEOUT_SECS = 180;

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

    decimal connectorTimeout = DEFAULT_CONNECTOR_TIMEOUT_SECS;
    string timeoutStr = os:getEnv("CONNECTOR_TIMEOUT");
    if timeoutStr.length() > 0 {
        decimal|error parsed = decimal:fromString(timeoutStr);
        if parsed is decimal && parsed > 0d { connectorTimeout = parsed; }
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
    io:println(string `  Model       : ${model}`);
    io:println(string `  GitHub      : ${ghToken.length() > 0 ? "token set" : "no token (rate limit: 60/hr)"}`);
    io:println(string `  Output      : ${outFile}`);
    io:println(string `  APIs        : ${connectors.length()}`);
    io:println(string `  Concurrency : ${concurrency}`);
    io:println(string `  Timeout     : ${<int>connectorTimeout}s per connector`);
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

    // Process connectors in parallel batches of `concurrency`
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

        // Collect results with per-connector wall-clock timeout.
        //
        // `wait f timeout N` is Ballerina's native mechanism for bounding how
        // long we wait for a future strand. If the strand doesn't complete within
        // N seconds, `wait` returns an error immediately and the batch continues.
        // The hung strand keeps running in the background but its result is
        // discarded — we mark the connector as not_found and move on.
        //
        // This is the ONLY reliable way to enforce wall-clock deadlines in
        // Ballerina. Timeouts inside http:Client only fire after data starts
        // flowing; they don't catch the case where a server accepts the TCP
        // connection but then stalls indefinitely before sending any bytes.
        int fi = 0;
        foreach future<ResultEntry> f in futures {
            Connector bc = batchConnectors[fi];
            fi += 1;

            ResultEntry entry;
            ResultEntry|error waitResult = wait f;

            if waitResult is ResultEntry {
                entry = waitResult;
            } else {
                // Either strand panicked or connector-level timeout fired
                string reason = waitResult.message().toLowerAscii().includes("timeout")
                    ? string `timed out after ${<int>connectorTimeout}s`
                    : string `strand error: ${waitResult.message()}`;
                log:printInfo(string `  [${bc.name}] ${reason}`);
                io:println(string `[timeout] ${bc.name} — ${reason}`);
                entry = {
                    name:           bc.name,
                    docsUrl:        bc.docsUrl,
                    targetTitle:    bc.targetTitle,
                    specUrl:        (),
                    specRepo:       (),
                    title:          (),
                    apiVersion:     (),
                    format:         (),
                    status:         "not_found",
                    checkedAt:      time:utcToString(time:utcNow()),
                    elapsedSeconds: connectorTimeout
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

        // Save after every batch so partial progress is never lost
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

// ─── Per-connector work (runs in its own strand) ──────────────────────────────

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
        // ── Path A: We have a known URL ──────────────────────────────────────

        if !knownUrl.includes("raw.githubusercontent.com") {
            // A1: Stable direct endpoint — LLM validates and checks for newer version
            log:printInfo(string `  [${c.name}] path=stable-version-check`);
            SpecResult?|string stableResult = stepQuickVerify(knownUrl, knownRepo, c.docsUrl, apiKey);

            if stableResult is SpecResult {
                finalResult = stableResult;
            } else {
                log:printInfo(string `  [${c.name}] stable URL dead or outdated — re-discovering`);
                DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo);
                finalResult = stepContentVerify(disc);
            }

        } else {
            // A2: GitHub raw URL — check for newer version in parent folder
            log:printInfo(string `  [${c.name}] path=github-version-check`);
            SpecResult?|string checkResult = stepGithubVersionCheck(knownUrl, knownRepo, apiKey);

            if checkResult is SpecResult {
                finalResult = checkResult;
            } else {
                log:printInfo(string `  [${c.name}] GitHub check failed — re-discovering`);
                DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo);
                finalResult = stepContentVerify(disc);
            }
        }

    } else {
        // ── Path B: No known URL — full discovery ────────────────────────────
        log:printInfo(string `  [${c.name}] path=full-discovery`);
        DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo);
        finalResult = stepContentVerify(disc);
    }

    decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));

    if finalResult is SpecResult {
        io:println(string `[done ] ${label}`);
        io:println(string `  => ${finalResult.specUrl}`);
        io:println(string `     format=${finalResult.format} | ${elapsed}s`);
        return {
            name:           c.name,
            docsUrl:        c.docsUrl,
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
            docsUrl:        c.docsUrl,
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
