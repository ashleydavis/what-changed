const std = @import("std");
const value = @import("value.zig");
const json = @import("json.zig");
const files = @import("files.zig");
const config = @import("config.zig");
const failure = @import("failure.zig");
const Failure = failure.Failure;
const testing = std.testing;

//
// Parses a config in a test, so each case is one line rather than four.
//
fn parseForTest(allocator: std.mem.Allocator, raw_text: []const u8, format: config.ConfigFormat) !config.Config {
    var fail = Failure.init(allocator);
    return config.parseConfig(allocator, raw_text, format, &fail) catch |err| {
        std.debug.print("config error: {s}\n", .{fail.text()});
        return err;
    };
}

//
// Parses a config expecting it to fail, and hands back the message it failed with.
//
fn failureFor(allocator: std.mem.Allocator, raw_text: []const u8, format: config.ConfigFormat) ![]const u8 {
    var fail = Failure.init(allocator);
    const parsed = config.parseConfig(allocator, raw_text, format, &fail);
    try testing.expectError(error.Failed, parsed);
    return fail.text();
}

test "formatForPath reads the format off the extension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try testing.expectEqual(config.ConfigFormat.yaml, try config.formatForPath(allocator, "/x/what-changed.yaml", &fail));
    try testing.expectEqual(config.ConfigFormat.yaml, try config.formatForPath(allocator, "/x/what-changed.yml", &fail));
    try testing.expectEqual(config.ConfigFormat.json, try config.formatForPath(allocator, "/x/what-changed.json", &fail));
}

test "formatForPath ignores the case of the extension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try testing.expectEqual(config.ConfigFormat.yaml, try config.formatForPath(allocator, "/x/WHAT-CHANGED.YAML", &fail));
    try testing.expectEqual(config.ConfigFormat.json, try config.formatForPath(allocator, "/x/What-Changed.Json", &fail));
}

test "formatForPath refuses an unrecognised extension rather than guessing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try testing.expectError(error.Failed, config.formatForPath(allocator, "/x/what-changed.toml", &fail));
    try testing.expectEqualStrings(
        "what-changed config \"/x/what-changed.toml\" has an unrecognised extension \".toml\". Use .yaml, .yml or .json.",
        fail.text(),
    );
}

test "formatForPath refuses a file with no extension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try testing.expectError(error.Failed, config.formatForPath(allocator, "/x/what-changed", &fail));
}

test "parseConfigText reads both formats into the same structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    const from_json = try config.parseConfigText(allocator, "{\"targets\": [{\"name\": \"a\"}]}", .json, &fail);
    const from_yaml = try config.parseConfigText(allocator, "targets:\n  - name: a\n", .yaml, &fail);

    try testing.expectEqualStrings("a", value.get(value.get(from_json, "targets").?.array.items[0], "name").?.string);
    try testing.expectEqualStrings("a", value.get(value.get(from_yaml, "targets").?.array.items[0], "name").?.string);
}

test "parseConfigText names the format that failed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var yaml_fail = Failure.init(allocator);
    try testing.expectError(error.Failed, config.parseConfigText(allocator, "targets:\n  - a\n   b: c\n", .yaml, &yaml_fail));
    try testing.expect(std.mem.indexOf(u8, yaml_fail.text(), "not valid YAML") != null);

    var json_fail = Failure.init(allocator);
    try testing.expectError(error.Failed, config.parseConfigText(allocator, "{ not json", .json, &json_fail));
    try testing.expect(std.mem.indexOf(u8, json_fail.text(), "not valid JSON") != null);
}

test "parseConfig reads a minimal config and fills in the defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseForTest(allocator, "targets:\n  - name: unit\n    paths:\n      - src\n", .yaml);

    try testing.expectEqualStrings(config.DEFAULT_CACHE_DIR, parsed.cache_dir);
    try testing.expectEqualStrings(config.DEFAULT_BASELINE_PATH, parsed.baseline_path);
    try testing.expectEqual(@as(usize, 0), parsed.always.len);
    try testing.expectEqual(@as(usize, 0), parsed.ignore.len);
    try testing.expectEqual(@as(usize, 1), parsed.targets.len);
    try testing.expectEqualStrings("unit", parsed.targets[0].name);
    try testing.expectEqualStrings("src", parsed.targets[0].paths[0]);
    try testing.expectEqual(@as(usize, 0), parsed.targets[0].platforms.len);
}

test "parseConfig reads every field when they are all given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseForTest(allocator,
        \\{
        \\  "cacheDir": "tmp/cache",
        \\  "baselinePath": "tmp/baseline.json",
        \\  "always": ["package.json"],
        \\  "ignore": [".md", ".txt"],
        \\  "targets": [
        \\    { "name": "unit", "paths": ["src"] },
        \\    { "name": "mobile", "paths": ["mobile"], "platforms": ["linux", "darwin"] }
        \\  ]
        \\}
    , .json);

    try testing.expectEqualStrings("tmp/cache", parsed.cache_dir);
    try testing.expectEqualStrings("tmp/baseline.json", parsed.baseline_path);
    try testing.expectEqualStrings("package.json", parsed.always[0]);
    try testing.expectEqual(@as(usize, 2), parsed.ignore.len);
    try testing.expectEqual(@as(usize, 2), parsed.targets.len);
    try testing.expectEqual(@as(usize, 2), parsed.targets[1].platforms.len);
    try testing.expectEqualStrings("darwin", parsed.targets[1].platforms[1]);
}

test "parseConfig keeps the targets in the order the config lists them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseForTest(allocator,
        \\targets:
        \\  - name: compile
        \\    paths: [src]
        \\  - name: test
        \\    paths: [src]
        \\  - name: smoke
        \\    paths: [src]
    , .yaml);

    try testing.expectEqualStrings("compile", parsed.targets[0].name);
    try testing.expectEqualStrings("test", parsed.targets[1].name);
    try testing.expectEqualStrings("smoke", parsed.targets[2].name);
}

test "parseConfig refuses a document that is not an object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config must be a JSON object, got []",
        try failureFor(allocator, "[]", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config must be a YAML object, got null",
        try failureFor(allocator, "", .yaml),
    );
}

test "parseConfig refuses a bad cacheDir and names the field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config field \"cacheDir\" must be a non-empty string, got 5",
        try failureFor(allocator, "{\"cacheDir\": 5, \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config field \"cacheDir\" must be a non-empty string, got \"\"",
        try failureFor(allocator, "{\"cacheDir\": \"\", \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
}

test "parseConfig refuses a bad baselinePath and names the field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config field \"baselinePath\" must be a non-empty string, got true",
        try failureFor(allocator, "{\"baselinePath\": true, \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
}

test "parseConfig refuses an always that is not an array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config field \"always\" must be an array, got \"package.json\"",
        try failureFor(allocator, "{\"always\": \"package.json\", \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
}

test "parseConfig refuses an absolute or climbing always path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config field \"always\" must hold relative paths, got \"/etc/passwd\"",
        try failureFor(allocator, "{\"always\": [\"/etc/passwd\"], \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config field \"always\" must not contain a \"..\" segment, got \"../outside\"",
        try failureFor(allocator, "{\"always\": [\"../outside\"], \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
}

test "parseConfig refuses a non-string always entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config field \"always\" must hold non-empty strings, got 7",
        try failureFor(allocator, "{\"always\": [7], \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
}

test "parseConfig refuses a bad ignore entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config field \"ignore\" entries must start with a dot, got \"md\"",
        try failureFor(allocator, "{\"ignore\": [\"md\"], \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config field \"ignore\" entries must have something after the dot, got \".\"",
        try failureFor(allocator, "{\"ignore\": [\".\"], \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config field \"ignore\" holds extensions, not paths, got \".md/x\"",
        try failureFor(allocator, "{\"ignore\": [\".md/x\"], \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config field \"ignore\" must be an array, got \".md\"",
        try failureFor(allocator, "{\"ignore\": \".md\", \"targets\": [{\"name\": \"a\", \"paths\": [\"b\"]}]}", .json),
    );
}

test "parseConfig refuses a missing or empty targets list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config field \"targets\" must be a non-empty array, got []",
        try failureFor(allocator, "targets: []", .yaml),
    );
    try testing.expectEqualStrings(
        "what-changed config field \"targets\" must be a non-empty array, got undefined",
        try failureFor(allocator, "{}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config field \"targets\" must be a non-empty array, got \"unit\"",
        try failureFor(allocator, "{\"targets\": \"unit\"}", .json),
    );
}

test "parseConfig refuses a target that is not an object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config target must be an object, got \"unit\"",
        try failureFor(allocator, "{\"targets\": [\"unit\"]}", .json),
    );
}

test "parseConfig refuses a target with no name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config target field \"name\" must be a non-empty string, got undefined",
        try failureFor(allocator, "{\"targets\": [{\"paths\": [\"src\"]}]}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config target field \"name\" must be a non-empty string, got \"\"",
        try failureFor(allocator, "{\"targets\": [{\"name\": \"\", \"paths\": [\"src\"]}]}", .json),
    );
}

test "parseConfig refuses a duplicate target name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config has a duplicate target name \"unit\"",
        try failureFor(allocator, "{\"targets\": [{\"name\": \"unit\", \"paths\": [\"a\"]}, {\"name\": \"unit\", \"paths\": [\"b\"]}]}", .json),
    );
}

test "parseConfig refuses a target with no paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config target \"unit\" field \"paths\" must be a non-empty array, got []",
        try failureFor(allocator, "{\"targets\": [{\"name\": \"unit\", \"paths\": []}]}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config target \"unit\" field \"paths\" must be a non-empty array, got undefined",
        try failureFor(allocator, "{\"targets\": [{\"name\": \"unit\"}]}", .json),
    );
}

test "parseConfig refuses a bad path inside a target and names the target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config field \"target \"unit\" paths\" must not contain a \"..\" segment, got \"../x\"",
        try failureFor(allocator, "{\"targets\": [{\"name\": \"unit\", \"paths\": [\"../x\"]}]}", .json),
    );
}

test "parseConfig refuses bad platforms and names the target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings(
        "what-changed config target \"unit\" field \"platforms\" must be an array, got \"linux\"",
        try failureFor(allocator, "{\"targets\": [{\"name\": \"unit\", \"paths\": [\"src\"], \"platforms\": \"linux\"}]}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config target \"unit\" field \"platforms\" must hold non-empty strings, got 3",
        try failureFor(allocator, "{\"targets\": [{\"name\": \"unit\", \"paths\": [\"src\"], \"platforms\": [3]}]}", .json),
    );
    try testing.expectEqualStrings(
        "what-changed config target \"unit\" field \"platforms\" must hold non-empty strings, got \"\"",
        try failureFor(allocator, "{\"targets\": [{\"name\": \"unit\", \"paths\": [\"src\"], \"platforms\": [\"\"]}]}", .json),
    );
}

test "parseConfig accepts an empty platforms list, which means every platform" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseForTest(allocator, "{\"targets\": [{\"name\": \"unit\", \"paths\": [\"src\"], \"platforms\": []}]}", .json);
    try testing.expectEqual(@as(usize, 0), parsed.targets[0].platforms.len);
}

test "validateWatchedPath accepts a relative path inside the project" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try config.validateWatchedPath("src", "always", &fail);
    try config.validateWatchedPath("packages/a/src", "always", &fail);
    try config.validateWatchedPath("a..b", "always", &fail);
    try config.validateWatchedPath("package.json", "always", &fail);
}

test "validateIgnoreExtension accepts a dotted extension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try config.validateIgnoreExtension(".md", &fail);
    try config.validateIgnoreExtension(".test.ts", &fail);
}

test "resolveConfigPath uses the named config, resolved against the working directory" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try testing.expectEqualStrings("/work/custom.yaml", try config.resolveConfigPath(io, allocator, "custom.yaml", "/work", &fail));
    try testing.expectEqualStrings("/other/custom.yaml", try config.resolveConfigPath(io, allocator, "/other/custom.yaml", "/work", &fail));
    try testing.expectEqualStrings("/work/nested/custom.yaml", try config.resolveConfigPath(io, allocator, "nested/custom.yaml", "/work", &fail));
}

test "findConfig names every name it looked for when there is none" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    var fail = Failure.init(allocator);
    try testing.expectError(error.Failed, config.findConfig(io, allocator, temporary.path, &fail));
    try testing.expect(std.mem.indexOf(u8, fail.text(), "what-changed.yaml") != null);
    try testing.expect(std.mem.indexOf(u8, fail.text(), "what-changed.yml") != null);
    try testing.expect(std.mem.indexOf(u8, fail.text(), "what-changed.json") != null);
}

test "findConfig prefers the names in the order they are listed" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    try temporary.write("what-changed.json", "{}");
    var fail = Failure.init(allocator);
    const found_json = try config.findConfig(io, allocator, temporary.path, &fail);
    try testing.expect(std.mem.endsWith(u8, found_json, "what-changed.json"));

    try temporary.write("what-changed.yaml", "targets: []");
    const found_yaml = try config.findConfig(io, allocator, temporary.path, &fail);
    try testing.expect(std.mem.endsWith(u8, found_yaml, "what-changed.yaml"));
}

test "loadConfig reads a config off disk" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    try temporary.write("what-changed.yaml", "targets:\n  - name: unit\n    paths:\n      - src\n");

    var fail = Failure.init(allocator);
    const parsed = try config.loadConfig(io, allocator, try temporary.join(allocator, "what-changed.yaml"), &fail);
    try testing.expectEqualStrings("unit", parsed.targets[0].name);
}

test "loadConfig names the path when the file is not there" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    var fail = Failure.init(allocator);
    try testing.expectError(error.Failed, config.loadConfig(io, allocator, try temporary.join(allocator, "missing.yaml"), &fail));
    try testing.expect(std.mem.startsWith(u8, fail.text(), "Failed to read the what-changed config at \""));
    try testing.expect(std.mem.indexOf(u8, fail.text(), "missing.yaml") != null);

    //
    // Worded exactly as Node words it, so a build log reads the same whichever port produced it.
    //
    try testing.expect(std.mem.indexOf(u8, fail.text(), "ENOENT: no such file or directory, open '") != null);
}

test "parseTarget reads one target on its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw = try json.parse(allocator, "{\"name\": \"unit\", \"paths\": [\"src\"], \"platforms\": [\"linux\"]}");

    var seen_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    var fail = Failure.init(allocator);
    const target = try config.parseTarget(allocator, raw, &seen_names, &fail);

    try testing.expectEqualStrings("unit", target.name);
    try testing.expectEqualStrings("src", target.paths[0]);
    try testing.expectEqualStrings("linux", target.platforms[0]);
}

test "parseTarget records the name it saw, so the next duplicate is caught" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw = try json.parse(allocator, "{\"name\": \"unit\", \"paths\": [\"src\"]}");

    var seen_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    var fail = Failure.init(allocator);

    _ = try config.parseTarget(allocator, raw, &seen_names, &fail);
    try testing.expect(seen_names.contains("unit"));

    //
    // The same name a second time is refused. The caller keeps one set across every target, which
    // is what makes this the check for a duplicate rather than a check against itself.
    //
    try testing.expectError(error.Failed, config.parseTarget(allocator, raw, &seen_names, &fail));
    try testing.expectEqualStrings("what-changed config has a duplicate target name \"unit\"", fail.text());
}

test "parseTarget defaults an absent platforms list to every platform" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw = try json.parse(allocator, "{\"name\": \"unit\", \"paths\": [\"src\"]}");

    var seen_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    var fail = Failure.init(allocator);
    const target = try config.parseTarget(allocator, raw, &seen_names, &fail);

    try testing.expectEqual(@as(usize, 0), target.platforms.len);
}

test "parseTarget refuses anything that is not an object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var seen_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    var fail = Failure.init(allocator);

    try testing.expectError(error.Failed, config.parseTarget(allocator, value.str("unit"), &seen_names, &fail));
    try testing.expectEqualStrings("what-changed config target must be an object, got \"unit\"", fail.text());
}
