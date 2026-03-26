// memory.bal
// Persistent memory stored in search_memory.json.
//
// Key   = netloc + path of the docs URL, trailing slash stripped.
//         e.g. "developers.asana.com/reference/rest-api-reference"
//
// Value = MemoryEntry
//   specUrlHistory : newest URL first, max 5 entries
//   lastVersion    : openapi version string of the last found spec
//   lastSearched   : ISO-8601 timestamp
//   lastOutcome    : "found" | "not_found"
//
// On each successful run the new spec URL is prepended to specUrlHistory.
// This lets the agent quickly re-validate previously known URLs first.

import ballerina/file;
import ballerina/io;
import ballerina/log;
import ballerina/time;

const string MEMORY_FILE = "search_memory.json";
const int MAX_HISTORY = 5;

// ---------------------------------------------------------------------------
// Key derivation
// ---------------------------------------------------------------------------

public isolated function memoryKey(string docsUrl) returns string {
    string s = docsUrl;
    if s.startsWith("https://") {
        s = s.substring(8);
    } else if s.startsWith("http://") {
        s = s.substring(7);
    }
    int? qi = s.indexOf("?");
    if qi is int {
        s = s.substring(0, qi);
    }
    int? hi = s.indexOf("#");
    if hi is int {
        s = s.substring(0, hi);
    }
    if s.endsWith("/") {
        s = s.substring(0, s.length() - 1);
    }
    return s;
}

// ---------------------------------------------------------------------------
// Load / save
// ---------------------------------------------------------------------------

function loadMemory() returns map<MemoryEntry> {
    boolean exists = false;
    do {
        exists = check file:test(MEMORY_FILE, file:EXISTS);
    } on fail {
        return {};
    }
    if !exists {
        return {};
    }
    string content = "";
    do {
        content = check io:fileReadString(MEMORY_FILE);
    } on fail error e {
        log:printWarn("memory: cannot read file", 'error = e);
        return {};
    }
    map<MemoryEntry>|error parsed = content.fromJsonStringWithType();
    if parsed is error {
        log:printWarn("memory: cannot parse JSON, starting fresh");
        return {};
    }
    return parsed;
}

function saveMemory(map<MemoryEntry> mem) {
    string|error s = mem.toJsonString();
    if s is error {
        log:printWarn("memory: cannot serialise");
        return;
    }
    error? w = io:fileWriteString(MEMORY_FILE, s);
    if w is error {
        log:printWarn("memory: cannot write file", 'error = w);
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

public function getMemory(string docsUrl) returns MemoryEntry? {
    return loadMemory()[memoryKey(docsUrl)];
}

// Called after a successful find().  Prepends the new URL to history.
public function updateMemory(string docsUrl, string specUrl, string version) {
    map<MemoryEntry> mem = loadMemory();
    string key = memoryKey(docsUrl);

    MemoryEntry entry = mem.hasKey(key) ? mem.get(key) : {
        specUrlHistory: [],
        lastVersion: (),
        lastSearched: "",
        lastOutcome: ()
    };

    // Prepend if different from current top; deduplicate; cap at MAX_HISTORY
    string[] history = entry.specUrlHistory;
    if history.length() == 0 || history[0] != specUrl {
        string[] updated = [specUrl];
        foreach string u in history {
            if u != specUrl && updated.length() < MAX_HISTORY {
                updated.push(u);
            }
        }
        entry.specUrlHistory = updated;
    }

    entry.lastVersion = version;
    entry.lastSearched = time:utcToString(time:utcNow());
    entry.lastOutcome = "found";
    mem[key] = entry;
    saveMemory(mem);
}

// Called when no spec was found after all strategies.
public function markNotFound(string docsUrl) {
    map<MemoryEntry> mem = loadMemory();
    string key = memoryKey(docsUrl);
    MemoryEntry entry = mem.hasKey(key) ? mem.get(key) : {
        specUrlHistory: [],
        lastVersion: (),
        lastSearched: "",
        lastOutcome: ()
    };
    entry.lastSearched = time:utcToString(time:utcNow());
    entry.lastOutcome = "not_found";
    mem[key] = entry;
    saveMemory(mem);
}
