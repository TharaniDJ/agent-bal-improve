// types.bal
// Shared record types used across all files in this package.

// A validated OpenAPI spec candidate — returned by the validator after
// successfully parsing a downloaded spec file.
public type ValidatedCandidate record {|
    string url;
    string openapiVersion;  // e.g. "3.0.0", "3.1.0", "2.0"
    string? apiVersion;     // from info.version
    string? title;          // from info.title
    string format;          // "yaml" | "json"
    float score;            // higher = preferred (used to pick best among many)
|};

// The final result returned by SpecFinderAgent.find()
public type SpecResult record {|
    string specUrl;
    string openapiVersion;
    string? apiVersion;
    string? title;
    string format;
    boolean isNewVersion;
    string strategyUsed;
|};

// One entry stored per docs URL in search_memory.json
public type MemoryEntry record {|
    string[] specUrlHistory;  // newest first, max 5
    string? lastVersion;
    string lastSearched;
    string? lastOutcome;      // "found" | "not_found"
|};

// A connector whose spec we want to track
public type Connector record {|
    string name;
    string docsUrl;
    string? targetTitle;  // for multi-spec pages (e.g. Candid)
|};

// One row in the output openapi_specs.json
public type ResultEntry record {|
    string name;
    string docsUrl;
    string? targetTitle;
    string? specUrl;
    string? openapiVersion;
    string? apiVersion;
    string? format;
    string? title;
    string status;          // "found" | "not_found"
    boolean isNewVersion;
    string? strategyUsed;
    string? foundAt;
    decimal elapsedSeconds;
|};
