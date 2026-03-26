// main.bal
// Batch runner.
//
// Environment variables:
//   ANTHROPIC_API_KEY   — required for LLM strategies
//   GITHUB_TOKEN        — optional; raises GitHub API rate limit 60 -> 5000/hr
//   FILTER              — run only connectors whose name contains this string
//   BATCH_SIZE          — how many connectors to run per execution (default: 10)
//   BATCH_OFFSET        — index of first connector in this batch (default: 0)
//                         Use BATCH_OFFSET=0,10,20,... on successive runs to work through all.
//   NO_LLM              — set to "true" to skip LLM strategies
//   OUTPUT              — output filename (default: openapi_specs.json)
//   DRY_RUN             — set to "true" to list connectors without running
//
// Examples:
//   # Run first 10 connectors
//   BATCH_SIZE=10 BATCH_OFFSET=0 bal run .
//
//   # Run next 10
//   BATCH_SIZE=10 BATCH_OFFSET=10 bal run .
//
//   # Run only HubSpot connectors
//   FILTER=hubspot bal run .
//
//   # Run everything (no limit)
//   BATCH_SIZE=0 bal run .

import ballerina/file;
import ballerina/io;
import ballerina/os;
import ballerina/time;

configurable string outputFile = "openapi_specs.json";

const string DIV  = "======================================================================";
const string DASH = "----------------------------------------------------------------------";

public function main() returns error? {

    string anthropicKey  = os:getEnv("ANTHROPIC_API_KEY");
    string filterStr     = os:getEnv("FILTER").toLowerAscii();
    boolean noLlm        = os:getEnv("NO_LLM").toLowerAscii() == "true";
    boolean dryRun       = os:getEnv("DRY_RUN").toLowerAscii() == "true";
    string outFile       = os:getEnv("OUTPUT").length() > 0 ? os:getEnv("OUTPUT") : outputFile;
    int batchSize        = intFromEnv("BATCH_SIZE", 10);
    int batchOffset      = intFromEnv("BATCH_OFFSET", 0);

    if noLlm {
        anthropicKey = "";
        io:println("LLM strategies disabled (NO_LLM=true)");
    }

    // ── Build connector list ──────────────────────────────────────────────────
    Connector[] filtered = filterStr.length() > 0
        ? ALL_CONNECTORS.filter(c => c.name.toLowerAscii().includes(filterStr))
        : ALL_CONNECTORS;

    // Apply offset and batch size
    int totalFiltered = filtered.length();
    int effectiveOffset = batchOffset < totalFiltered ? batchOffset : 0;
    Connector[] connectors;
    if batchSize <= 0 {
        // batchSize=0 means run all
        connectors = effectiveOffset > 0 ? filtered.slice(effectiveOffset) : filtered;
    } else {
        int endIdx = effectiveOffset + batchSize;
        endIdx = endIdx > totalFiltered ? totalFiltered : endIdx;
        connectors = filtered.slice(effectiveOffset, endIdx);
    }

    // ── Dry run ───────────────────────────────────────────────────────────────
    if dryRun {
        io:println(DIV);
        io:println(string `  Total available: ${totalFiltered} | Showing: ${connectors.length()} (offset=${effectiveOffset})`);
        io:println(DASH);
        int i = effectiveOffset + 1;
        foreach Connector c in connectors {
            string targetNote = c.targetTitle is string
                ? string ` [target: ${c.targetTitle ?: ""}]` : "";
            io:println(string `  ${padLeft(i.toString(), 3)}.  ${pad(c.name, 40)} ${c.docsUrl}${targetNote}`);
            i += 1;
        }
        return;
    }

    // ── Banner ────────────────────────────────────────────────────────────────
    io:println("");
    io:println(DIV);
    io:println(string `  OpenAPI Spec Finder — ${utcToDisplay(time:utcNow())}`);
    io:println(string `  Running connectors ${effectiveOffset + 1}–${effectiveOffset + connectors.length()} of ${totalFiltered}`);
    io:println(string `  LLM: ${anthropicKey.length() > 0 ? "enabled" : "disabled (set ANTHROPIC_API_KEY)"}`);
    io:println(string `  Output: ${outFile}`);
    io:println(DIV);

    // ── Load any existing results so we append rather than overwrite ───────────
    ResultEntry[] results = loadExistingResults(outFile);
    // Build a set of names already processed in a previous batch
    map<boolean> alreadyDone = {};
    foreach ResultEntry r in results {
        alreadyDone[r.name] = true;
    }

    SpecFinderAgent agent = new (anthropicApiKey = anthropicKey);
    time:Utc batchStart = time:utcNow();
    int idx = 1;

    foreach Connector connector in connectors {
        // Skip if this connector was already processed in a previous run
        if alreadyDone.hasKey(connector.name) {
            io:println(string `  [skip] ${connector.name} — already in ${outFile}`);
            idx += 1;
            continue;
        }

        io:println(string `\n[${idx}/${connectors.length()}] ${connector.name}`);

        time:Utc connStart = time:utcNow();
        SpecResult? result = agent.find(
            docsUrl     = connector.docsUrl,
            apiName     = connector.name,
            targetTitle = connector.targetTitle
        );
        decimal elapsed        = time:utcDiffSeconds(time:utcNow(), connStart);
        decimal elapsedDisplay = <decimal>(<int>(elapsed * 10d)) / 10d;

        ResultEntry entry;
        if result is SpecResult {
            entry = {
                name:           connector.name,
                docsUrl:        connector.docsUrl,
                targetTitle:    connector.targetTitle,
                specUrl:        result.specUrl,
                openapiVersion: result.openapiVersion,
                apiVersion:     result.apiVersion,
                format:         result.format,
                title:          result.title,
                status:         "found",
                isNewVersion:   result.isNewVersion,
                strategyUsed:   result.strategyUsed,
                foundAt:        time:utcToString(time:utcNow()),
                elapsedSeconds: elapsedDisplay
            };
            string newTag = result.isNewVersion ? " <-- NEW VERSION" : "";
            io:println(string `  OK   ${result.specUrl}${newTag}`);
            io:println(string `       [${elapsedDisplay}s | strategy: ${result.strategyUsed} | oas: ${result.openapiVersion}]`);
        } else {
            entry = {
                name:           connector.name,
                docsUrl:        connector.docsUrl,
                targetTitle:    connector.targetTitle,
                specUrl:        (),
                openapiVersion: (),
                apiVersion:     (),
                format:         (),
                title:          (),
                status:         "not_found",
                isNewVersion:   false,
                strategyUsed:   (),
                foundAt:        (),
                elapsedSeconds: elapsedDisplay
            };
            io:println(string `  FAIL not found [${elapsedDisplay}s]`);
        }

        results.push(entry);
        check saveResults(results, outFile);
        idx += 1;
    }

    decimal totalElapsed = time:utcDiffSeconds(time:utcNow(), batchStart);

    // ── Summary ───────────────────────────────────────────────────────────────
    // Count only the batch we just ran (not previously loaded results)
    int batchProcessed = results.length() - (alreadyDone.keys().length());
    ResultEntry[] batchResults = results.filter(
        r => !alreadyDone.hasKey(r.name)
    );
    ResultEntry[] found  = batchResults.filter(r => r.status == "found");
    ResultEntry[] failed = batchResults.filter(r => r.status == "not_found");
    ResultEntry[] newVer = batchResults.filter(r => r.isNewVersion);

    io:println("");
    io:println(DIV);
    io:println(string `  BATCH SUMMARY — ${<int>totalElapsed}s`);
    io:println(string `  Processed : ${batchProcessed}`);
    io:println(string `  Found     : ${found.length()}`);
    io:println(string `  Not found : ${failed.length()}`);
    io:println(string `  New ver   : ${newVer.length()}`);
    io:println(DIV);
    io:println("");

    if found.length() > 0 {
        io:println(string `  FOUND (${found.length()}):`);
        io:println(string `  ${pad("Name", 38)} ${pad("Fmt", 5)} ${pad("OAS", 6)} ${pad("Strategy", 14)} URL`);
        io:println(DASH);
        foreach ResultEntry r in found {
            string newMark = r.isNewVersion ? " <NEW" : "";
            string fmt     = (r.format ?: "?").toUpperAscii();
            string ver     = r.openapiVersion ?: "?";
            string strat   = r.strategyUsed ?: "?";
            string sUrl    = r.specUrl ?: "";
            io:println(string `  ${pad(r.name, 38)} ${pad(fmt, 5)} ${pad(ver, 6)} ${pad(strat, 14)} ${sUrl}${newMark}`);
        }
    }

    if failed.length() > 0 {
        io:println(string `\n  NOT FOUND (${failed.length()}):`);
        foreach ResultEntry r in failed {
            io:println(string `    - ${r.name}`);
            io:println(string `      ${r.docsUrl}`);
        }
    }

    // Tell user how to run the next batch
    int nextOffset = effectiveOffset + connectors.length();
    if nextOffset < totalFiltered {
        io:println(string `\n  To run the next batch:`);
        io:println(string `    BATCH_SIZE=${batchSize} BATCH_OFFSET=${nextOffset} bal run .`);
    } else {
        io:println("\n  All connectors have been processed.");
    }

    io:println(string `\n  Results -> ${outFile}`);
    io:println("  Memory  -> search_memory.json");
    io:println("");
}

// ---------------------------------------------------------------------------
// Load existing results from JSON file (for append behaviour across batches)
// ---------------------------------------------------------------------------

function loadExistingResults(string path) returns ResultEntry[] {
    ResultEntry[] empty = [];
    do {
        boolean exists = check file:test(path, file:EXISTS);
        if !exists { return empty; }
        string content = check io:fileReadString(path);
        ResultEntry[]|error parsed = content.fromJsonStringWithType();
        if parsed is ResultEntry[] { return parsed; }
    } on fail {
        // File missing or unreadable — start fresh
    }
    return empty;
}

// ---------------------------------------------------------------------------
// Save results to JSON
// ---------------------------------------------------------------------------

function saveResults(ResultEntry[] results, string path) returns error? {
    json output = results.toJson();
    check io:fileWriteString(path, output.toJsonString());
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

isolated function intFromEnv(string name, int defaultVal) returns int {
    string raw = os:getEnv(name);
    if raw.length() == 0 { return defaultVal; }
    int|error n = int:fromString(raw);
    return n is int ? n : defaultVal;
}

isolated function pad(string s, int width) returns string {
    if s.length() >= width { return s; }
    string result = s;
    int i = s.length();
    while i < width { result += " "; i += 1; }
    return result;
}

isolated function padLeft(string s, int width) returns string {
    if s.length() >= width { return s; }
    string padding = "";
    int i = s.length();
    while i < width { padding += " "; i += 1; }
    return padding + s;
}

isolated function utcToDisplay(time:Utc t) returns string {
    string s = time:utcToString(t);
    return s.length() > 19 ? s.substring(0, 10) + " " + s.substring(11, 19) : s;
}
