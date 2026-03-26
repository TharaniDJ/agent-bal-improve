// agent.bal
// SpecFinderAgent — the main orchestrator.
//
// Correct design for a daily spec-update checker:
//
//   Every run:
//     1. Read memory  — get the last known spec URL and version (context only)
//     2. Run agent    — ALWAYS. Give it the last known version so it knows
//                       what to compare against and can find anything newer.
//     3. Compare      — if agent found same version as memory, no update needed.
//                       if agent found a newer version, update memory and flag it.
//     4. Fallback     — if agent fails completely, fall back to the cached URL
//                       from memory (at least return something rather than nothing).
//
// Memory is NEVER used to skip the agent. It is context that makes the agent
// smarter — it tells the agent "last time I found version X, look for anything newer".
//
// Validation is always programmatic (validator.bal).
// The LLM only finds candidate URLs — it never declares them valid.

import ballerina/log;

public class SpecFinderAgent {

    private final string anthropicApiKey;

    public function init(string anthropicApiKey = "") {
        self.anthropicApiKey = anthropicApiKey;
    }

    public function find(
        string docsUrl,
        string apiName = "",
        string? targetTitle = ()
    ) returns SpecResult? {

        string name = apiName.length() > 0 ? apiName : docsUrl;
        log:printInfo(repeatChar("-", 60));
        log:printInfo(string `  API: ${name}`);
        if targetTitle is string {
            log:printInfo(string `  Target: ${targetTitle}`);
        }

        // ── Step 1: Read memory for context ───────────────────────────────────
        // This does NOT skip the agent. It gives the agent the last known
        // version so it can check whether a newer one has been published.
        MemoryEntry? prevEntry = getMemory(docsUrl);
        string? prevVersion = prevEntry?.lastVersion;
        string[] cachedUrls = prevEntry?.specUrlHistory ?: [];

        if prevVersion is string {
            log:printInfo(string `  [memory] last known version: ${prevVersion}`);
        } else {
            log:printInfo("  [memory] no previous run — first time discovering this spec");
        }

        // ── Step 2: Run the agent (always) ────────────────────────────────────
        // The agent is told the last known version so it knows what to look for.
        // It will:
        //   - On first run: discover the latest spec from scratch
        //   - On subsequent runs: check whether a newer version was published
        //     since the last run, and return the latest one either way
        log:printInfo("  -> running agent");
        ValidatedCandidate? agentResult = strategyAgent(
            docsUrl,
            apiName,
            targetTitle,
            self.anthropicApiKey,
            lastKnownVersion = prevVersion
        );

        // ── Step 3: Determine what to return ─────────────────────────────────
        ValidatedCandidate? finalResult = ();
        string strategyUsed = "";

        if agentResult is ValidatedCandidate {
            // Agent succeeded — this is our result
            finalResult = agentResult;
            strategyUsed = "agent";
            log:printInfo(string `  [agent] found: ${agentResult.url} (v${agentResult.openapiVersion})`);
        } else {
            // Agent failed — fall back to cached URL from memory if available
            // This is a safety net: better to return a possibly-stale spec than nothing
            if cachedUrls.length() > 0 {
                log:printInfo("  [agent] failed — falling back to cached URL from memory");
                ValidatedCandidate? memResult = bestResult(cachedUrls);
                if memResult is ValidatedCandidate {
                    finalResult = memResult;
                    strategyUsed = "memory-fallback";
                    log:printInfo(string `  [memory-fallback] using cached: ${memResult.url}`);
                }
            }
        }

        // ── Step 4: Nothing found at all ──────────────────────────────────────
        if finalResult is () {
            log:printInfo("  FAIL: spec not found");
            markNotFound(docsUrl);
            return ();
        }

        ValidatedCandidate vc = finalResult;

        // ── Step 5: Detect version changes ────────────────────────────────────
        // Compare what we just found against what memory recorded last time.
        boolean isNew = false;
        if prevVersion is string && vc.openapiVersion != prevVersion {
            isNew = isNewerVersion(vc.openapiVersion, prevVersion);
            if isNew {
                log:printInfo(
                    string `  VERSION UPDATED: ${prevVersion} -> ${vc.openapiVersion}`
                );
            }
        }

        // ── Step 6: Update memory ─────────────────────────────────────────────
        // Always update — even if version is the same, the URL might have changed
        // (e.g. a new release tag). The new URL goes to the top of history.
        updateMemory(docsUrl, vc.url, vc.openapiVersion);

        log:printInfo(string `  OK [${strategyUsed}]: ${vc.url}`);

        return {
            specUrl:        vc.url,
            openapiVersion: vc.openapiVersion,
            apiVersion:     vc.apiVersion,
            title:          vc.title,
            format:         vc.format,
            isNewVersion:   isNew,
            strategyUsed:   strategyUsed
        };
    }
}

// ---------------------------------------------------------------------------
// Version comparison
// Returns true when newVer is strictly greater than oldVer numerically.
// "3.1.0" > "3.0.0"  → true
// "3.0.0" > "3.0.0"  → false (same version, no update)
// "2.0"   > "3.0.0"  → false
// ---------------------------------------------------------------------------

isolated function isNewerVersion(string newVer, string oldVer) returns boolean {
    int[] np = parseVersionParts(newVer);
    int[] op = parseVersionParts(oldVer);
    int maxLen = np.length() > op.length() ? np.length() : op.length();
    int i = 0;
    while i < maxLen {
        int n = i < np.length() ? np[i] : 0;
        int o = i < op.length() ? op[i] : 0;
        if n > o { return true; }
        if n < o { return false; }
        i += 1;
    }
    return false;
}

isolated function parseVersionParts(string ver) returns int[] {
    int[] parts = [];
    string rem = ver;
    while rem.length() > 0 {
        int? dot = rem.indexOf(".");
        string part = dot is int ? rem.substring(0, dot) : rem;
        rem = dot is int ? rem.substring(dot + 1) : "";
        int|error n = int:fromString(part.trim());
        parts.push(n is int ? n : 0);
    }
    return parts;
}

isolated function repeatChar(string ch, int n) returns string {
    string result = "";
    int i = 0;
    while i < n { result += ch; i += 1; }
    return result;
}
