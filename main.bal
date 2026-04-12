// main.bal
// Entry point — runs the agent for each connector SEQUENTIALLY, one at a time.
//
// Sequential mode makes logs easy to read and failures easy to spot.
// With 500+ connectors the full run takes longer, but you get clean per-connector
// output and the file is saved after every single connector so no progress is lost.
//
// Usage:
//   ANTHROPIC_API_KEY=sk-...  bal run .
//   ANTHROPIC_API_KEY=sk-...  FILTER=github bal run .
//   ANTHROPIC_API_KEY=sk-...  GITHUB_TOKEN=ghp_...  bal run .
//   DRY_RUN=true bal run .
//
// Debug mode (verbose logs for every HTTP call, fetch timing, Claude turns):
//   bal run . --log-level=DEBUG
//
// The debug flag enables log:printDebug() calls throughout agent.bal and
// pipeline.bal so you can trace exactly where a connector hangs or fails.

import ballerina/io;
import ballerina/log;
import ballerina/os;
import ballerina/time;
import ballerina/file;

configurable string outputFile = "openapi_specs.json";

const string BAR  = "================================================================";
const string DASH = "----------------------------------------------------------------";

// Maximum wall-clock seconds allowed for a single connector (all steps combined).
// Override via MAX_CONNECTOR_SECONDS env var.  Default: 300 s (5 minutes).
const decimal DEFAULT_MAX_CONNECTOR_SECONDS = 300.0;

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

    // ── Dry run ───────────────────────────────────────────────────────────────
    if dryRun {
        io:println(BAR);
        io:println(string `  OpenAPI Spec Finder — ${connectors.length()} connector(s)`);
        io:println(DASH);
        int i = 1;
        foreach Connector c in connectors {
            string t = c.targetTitle is string ? string ` [${c.targetTitle ?: ""}]` : "";
            io:println(string `  ${lp(i.toString(), 3)}. ${pad(c.name, 32)} ${c.docsUrl}${t}`);
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
    io:println(string `  Mode   : sequential (one at a time)`);
    io:println(string `  Debug  : run with --log-level=DEBUG for verbose fetch/timing logs`);
    io:println(BAR);
    io:println("");

    // ── Load existing results to merge into ───────────────────────────────────
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
    int total = connectors.length();

    // ── Sequential loop — one connector at a time ─────────────────────────────
    int idx = 0;
    foreach Connector c in connectors {
        idx += 1;
        string progress = string `[${idx}/${total}]`;

        string? knownUrl  = ();
        string? knownRepo = ();
        if existingIdx.hasKey(c.name) {
            ResultEntry prev = results[existingIdx.get(c.name)];
            knownUrl  = prev.specUrl;
            knownRepo = prev.specRepo;
        }

        io:println(DASH);
        string label = c.targetTitle is string
            ? string `${c.name} / ${c.targetTitle ?: ""}`
            : c.name;

        if knownUrl is string {
            io:println(string `${progress} START  ${label}`);
            log:printInfo(string `${progress} known url: ${knownUrl}`);
        } else {
            io:println(string `${progress} START  ${label}  (no previous URL)`);
        }

        ResultEntry entry = processConnector(c, knownUrl, knownRepo, apiKey, progress);

        if entry.status == "found" {
            found += 1;
            io:println(string `${progress} PASS   ${label}`);
            io:println(string `         => ${entry.specUrl ?: ""}`);
            io:println(string `            format=${entry.format ?: "?"} | ${entry.elapsedSeconds}s`);
        } else {
            notFound += 1;
            io:println(string `${progress} FAIL   ${label}  [${entry.elapsedSeconds}s]`);
            log:printWarn(string `${progress} NOT FOUND: ${label} | docs=${c.docsUrl}`);
        }

        // Merge into results array
        if existingIdx.hasKey(entry.name) {
            results[existingIdx.get(entry.name)] = entry;
        } else {
            existingIdx[entry.name] = results.length();
            results.push(entry);
        }

        // Save after every single connector — no progress is lost
        error? saveErr = saveResults(results, outFile);
        if saveErr is error {
            log:printError(string `${progress} save failed: ${saveErr.message()}`);
        }

        io:println("");
    }

    decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), runStart));
    io:println(BAR);
    io:println(string `  Done in ${<int>elapsed}s`);
    io:println(string `  found=${found}  not_found=${notFound}  total=${total}`);
    io:println(string `  Saved to ${outFile}`);
    io:println(BAR);
}

// ─── Per-connector work ───────────────────────────────────────────────────────

function processConnector(
    Connector c,
    string? knownUrl,
    string? knownRepo,
    string apiKey,
    string progress    // e.g. "[3/500]" — threaded through for log prefixing
) returns ResultEntry {

    time:Utc t0 = time:utcNow();
    SpecResult? finalResult = ();

    if knownUrl is string {
        // ── Path A: We have a known URL from a previous run ──────────────────
        //
        // Sub-paths:
        //   A1 — stable direct endpoint (CDN, vendor portal): LLM validates + checks for newer
        //   A2 — raw.githubusercontent.com URL: LLM checks parent folder for newer version
        //
        // After any version-check step:
        //   • SpecResult  → confirmed (same or newer URL); done
        //   • "DEAD"      → URL is gone; re-discover from scratch (knownUrl not useful)
        //   • ()          → Claude API error / exhausted turns; the URL may still be valid:
        //                   first try a fast programmatic check of the known URL, and only
        //                   fall back to full re-discovery if that also fails.
        //                   In both re-discovery cases, pass knownUrl as a hint to Claude.

        if !knownUrl.includes("raw.githubusercontent.com") {
            // A1: Stable direct endpoint
            log:printInfo(string `${progress} path=stable-version-check`);
            SpecResult?|string stableResult = stepQuickVerify(knownUrl, knownRepo, c.docsUrl, apiKey);

            if stableResult is SpecResult {
                log:printInfo(string `${progress} stable-version-check => confirmed`);
                finalResult = stableResult;
            } else if stableResult is string {
                // URL confirmed dead — re-discover without the dead URL
                log:printWarn(string `${progress} stable URL is DEAD — re-discovering`);
                DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo);
                log:printInfo(string `${progress} discovery found ${disc.candidateUrls.length()} candidate(s)`);
                finalResult = stepContentVerify(disc);
            } else {
                // Claude API error / timeout — try the known URL directly first
                log:printWarn(string `${progress} stable-version-check inconclusive — trying direct verify of known URL`);
                finalResult = directVerifyKnownUrl(knownUrl, knownRepo);
                if finalResult is () {
                    log:printWarn(string `${progress} direct verify failed — re-discovering with known URL as hint`);
                    DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo, knownUrl);
                    log:printInfo(string `${progress} discovery found ${disc.candidateUrls.length()} candidate(s)`);
                    finalResult = stepContentVerify(disc);
                } else {
                    log:printInfo(string `${progress} direct verify succeeded — using known URL`);
                }
            }

        } else {
            // A2: GitHub raw URL
            log:printInfo(string `${progress} path=github-version-check`);
            SpecResult?|string checkResult = stepGithubVersionCheck(knownUrl, knownRepo, c.docsUrl, apiKey);

            if checkResult is SpecResult {
                log:printInfo(string `${progress} github-version-check => confirmed`);
                finalResult = checkResult;
            } else if checkResult is string {
                // URL confirmed dead — re-discover without the dead URL
                log:printWarn(string `${progress} GitHub URL is DEAD — re-discovering`);
                DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo);
                log:printInfo(string `${progress} discovery found ${disc.candidateUrls.length()} candidate(s)`);
                finalResult = stepContentVerify(disc);
            } else {
                // Claude API error / timeout — try the known URL directly first
                log:printWarn(string `${progress} github-version-check inconclusive — trying direct verify of known URL`);
                finalResult = directVerifyKnownUrl(knownUrl, knownRepo);
                if finalResult is () {
                    log:printWarn(string `${progress} direct verify failed — re-discovering with known URL as hint`);
                    DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo, knownUrl);
                    log:printInfo(string `${progress} discovery found ${disc.candidateUrls.length()} candidate(s)`);
                    finalResult = stepContentVerify(disc);
                } else {
                    log:printInfo(string `${progress} direct verify succeeded — using known URL`);
                }
            }
        }

    } else {
        // ── Path B: No known URL — full discovery from scratch ───────────────
        log:printInfo(string `${progress} path=full-discovery`);
        DiscoveryResult disc = stepDiscovery(c.docsUrl, c.name, c.targetTitle, apiKey, knownRepo);
        log:printInfo(string `${progress} discovery found ${disc.candidateUrls.length()} candidate(s)`);
        finalResult = stepContentVerify(disc);
    }

    decimal elapsed = rd(time:utcDiffSeconds(time:utcNow(), t0));

    if finalResult is SpecResult {
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

