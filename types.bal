// types.bal

public type Connector record {|
    string name;
    string sourceUrl;         // renamed from docsUrl — the starting URL for discovery
    string? targetTitle;
|};

public type SpecResult record {|
    string specUrl;
    string? specRepo;
    string? title;
    string? apiVersion;
    string format;
|};

public type ResultEntry record {|
    string name;
    string sourceUrl;         // renamed from docsUrl
    string? targetTitle;
    string? specUrl;
    string? specRepo;
    string? title;
    string? apiVersion;
    string? format;
    string status;
    string checkedAt;
    decimal elapsedSeconds;
|};

// Output of the discovery step
public type DiscoveryResult record {|
    string[] candidateUrls;   // raw downloadable URLs to try in order
    string? specRepo;         // github owner/repo if found
    string discoveryMethod;   // "discovered" | "none"
|};
