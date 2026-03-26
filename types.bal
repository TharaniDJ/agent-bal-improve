// types.bal

public type Connector record {|
    string name;
    string docsUrl;
    string? targetTitle;
|};

public type SpecResult record {|
    string specUrl;
    string? title;
    string? apiVersion;
    string format;          // "yaml" | "json"
|};

public type ResultEntry record {|
    string name;
    string docsUrl;
    string? targetTitle;
    string? specUrl;
    string? title;
    string? apiVersion;
    string? format;
    string status;          // "found" | "not_found"
    string checkedAt;
    decimal elapsedSeconds;
|};
