// types.bal

public type Connector record {|
    string name;
    string docsUrl;
    string? targetTitle;
|};

public type SpecResult record {|
    string specUrl;
    string? specRepo;       // e.g. "owner/repo" if hosted on GitHub — used for update checks
    string? title;
    string? apiVersion;
    string format;          // "yaml" | "json"
|};

public type ResultEntry record {|
    string name;
    string docsUrl;
    string? targetTitle;
    string? specUrl;
    string? specRepo;       // GitHub repo path, populated when spec is GitHub-hosted
    string? title;
    string? apiVersion;
    string? format;
    string status;          // "found" | "not_found"
    string checkedAt;
    decimal elapsedSeconds;
|};
