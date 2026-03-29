// types.bal

public type Connector record {|
    string name;
    string docsUrl;
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
    string docsUrl;
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
