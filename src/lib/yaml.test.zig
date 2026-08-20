const std = @import("std");
const value = @import("value.zig");
const yaml = @import("yaml.zig");
const failure = @import("failure.zig");
const Value = value.Value;
const Failure = failure.Failure;
const testing = std.testing;

//
// Parses text in a test, failing the test with the syntax error's own words if it will not parse.
//
fn parseForTest(allocator: std.mem.Allocator, text: []const u8) !Value {
    var err: ?yaml.SyntaxError = null;
    return yaml.parse(allocator, text, &err) catch |caught| {
        if (err) |detail| std.debug.print("YAML error: {s} at line {d}\n", .{ detail.message, detail.line });
        return caught;
    };
}

test "isSequenceEntry recognises a dash that starts an item" {
    try testing.expect(yaml.isSequenceEntry("- item"));
    try testing.expect(yaml.isSequenceEntry("-"));
    try testing.expect(!yaml.isSequenceEntry("-5"));
    try testing.expect(!yaml.isSequenceEntry("key: value"));
    try testing.expect(!yaml.isSequenceEntry(""));
}

test "splitMappingEntry splits on a colon followed by a space or the end of the line" {
    const with_value = yaml.splitMappingEntry("name: alpha").?;
    try testing.expectEqualStrings("name", with_value.key);
    try testing.expectEqualStrings("alpha", with_value.rest);

    const without_value = yaml.splitMappingEntry("paths:").?;
    try testing.expectEqualStrings("paths", without_value.key);
    try testing.expectEqualStrings("", without_value.rest);

    try testing.expect(yaml.splitMappingEntry("just a scalar") == null);
    try testing.expect(yaml.splitMappingEntry("https://example.com") == null);
    try testing.expect(yaml.splitMappingEntry(": no key") == null);
}

test "splitMappingEntry ignores a colon inside quotes" {
    const entry = yaml.splitMappingEntry("\"a: b\": value").?;
    try testing.expectEqualStrings("\"a: b\"", entry.key);
    try testing.expectEqualStrings("value", entry.rest);
}

test "stripComment removes a comment but leaves a hash inside a word" {
    try testing.expectEqualStrings("name: alpha", yaml.stripComment("name: alpha # a comment"));
    try testing.expectEqualStrings("", yaml.stripComment("# whole line"));
    try testing.expectEqualStrings("name: a#b", yaml.stripComment("name: a#b"));
    try testing.expectEqualStrings("name: \"a # b\"", yaml.stripComment("name: \"a # b\" # gone"));
    try testing.expectEqualStrings("name: alpha", yaml.stripComment("name: alpha   "));
}

test "isNull, isTrue and isFalse read the words YAML gives a meaning to" {
    try testing.expect(yaml.isNull(""));
    try testing.expect(yaml.isNull("~"));
    try testing.expect(yaml.isNull("null"));
    try testing.expect(yaml.isNull("NULL"));
    try testing.expect(!yaml.isNull("nullish"));

    try testing.expect(yaml.isTrue("true"));
    try testing.expect(yaml.isTrue("True"));
    try testing.expect(!yaml.isTrue("yes"));

    try testing.expect(yaml.isFalse("false"));
    try testing.expect(yaml.isFalse("FALSE"));
    try testing.expect(!yaml.isFalse("no"));
}

test "looksLikeFloat accepts numbers and rejects words" {
    try testing.expect(yaml.looksLikeFloat("1.5"));
    try testing.expect(yaml.looksLikeFloat("-0.25"));
    try testing.expect(yaml.looksLikeFloat("2e10"));
    try testing.expect(yaml.looksLikeFloat("2.5E-3"));
    try testing.expect(yaml.looksLikeFloat("42"));
    try testing.expect(!yaml.looksLikeFloat("inf"));
    try testing.expect(!yaml.looksLikeFloat("nan"));
    try testing.expect(!yaml.looksLikeFloat("1.2.3"));
    try testing.expect(!yaml.looksLikeFloat(""));
    try testing.expect(!yaml.looksLikeFloat("1e"));
    try testing.expect(!yaml.looksLikeFloat(".md"));
}

test "parse reads the config the project ships with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseForTest(allocator,
        \\always:
        \\  - package.json
        \\  - mise.toml
        \\
        \\ignore:
        \\  - .md
        \\
        \\targets:
        \\  - name: compile
        \\    paths:
        \\      - src
        \\
        \\  - name: perf
        \\    paths:
        \\      - src
        \\      - perf-tests
    );

    const always = value.get(parsed, "always").?.array;
    try testing.expectEqual(@as(usize, 2), always.items.len);
    try testing.expectEqualStrings("package.json", always.items[0].string);

    const ignore = value.get(parsed, "ignore").?.array;
    try testing.expectEqualStrings(".md", ignore.items[0].string);

    const targets = value.get(parsed, "targets").?.array;
    try testing.expectEqual(@as(usize, 2), targets.items.len);
    try testing.expectEqualStrings("compile", value.get(targets.items[0], "name").?.string);
    try testing.expectEqualStrings("src", value.get(targets.items[0], "paths").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 2), value.get(targets.items[1], "paths").?.array.items.len);
}

test "parse reads a sequence written level with its key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(),
        \\targets:
        \\- name: alpha
        \\  paths:
        \\  - src
    );

    const targets = value.get(parsed, "targets").?.array;
    try testing.expectEqualStrings("alpha", value.get(targets.items[0], "name").?.string);
    try testing.expectEqualStrings("src", value.get(targets.items[0], "paths").?.array.items[0].string);
}

test "parse reads flow sequences and mappings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "targets: []\nignore: [.md, .txt]\ntarget: { name: alpha, paths: [src] }");

    try testing.expectEqual(@as(usize, 0), value.get(parsed, "targets").?.array.items.len);
    try testing.expectEqualStrings(".txt", value.get(parsed, "ignore").?.array.items[1].string);

    const target = value.get(parsed, "target").?;
    try testing.expectEqualStrings("alpha", value.get(target, "name").?.string);
    try testing.expectEqualStrings("src", value.get(target, "paths").?.array.items[0].string);
}

test "parse reads scalars as the types YAML gives them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(),
        \\yes: true
        \\no: false
        \\nothing: null
        \\tilde: ~
        \\whole: 42
        \\fraction: 1.5
        \\word: alpha
        \\quoted: "42"
        \\single: 'a b'
        \\empty:
    );

    try testing.expectEqual(true, value.get(parsed, "yes").?.bool);
    try testing.expectEqual(false, value.get(parsed, "no").?.bool);
    try testing.expect(value.get(parsed, "nothing").? == .null);
    try testing.expect(value.get(parsed, "tilde").? == .null);
    try testing.expectEqual(@as(i64, 42), value.get(parsed, "whole").?.integer);
    try testing.expectEqual(@as(f64, 1.5), value.get(parsed, "fraction").?.float);
    try testing.expectEqualStrings("alpha", value.get(parsed, "word").?.string);
    try testing.expectEqualStrings("42", value.get(parsed, "quoted").?.string);
    try testing.expectEqualStrings("a b", value.get(parsed, "single").?.string);
    try testing.expect(value.get(parsed, "empty").? == .null);
}

test "parse reads escapes in a double-quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "text: \"a\\nb\\t\\\"c\\\"\"");
    try testing.expectEqualStrings("a\nb\t\"c\"", value.get(parsed, "text").?.string);
}

test "parse reads a doubled quote inside a single-quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "text: 'it''s here'");
    try testing.expectEqualStrings("it's here", value.get(parsed, "text").?.string);
}

test "parse drops comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(),
        \\# what-changed's own configuration.
        \\
        \\ignore:
        \\  - .md   # markdown never affects a suite
        \\
    );

    try testing.expectEqualStrings(".md", value.get(parsed, "ignore").?.array.items[0].string);
}

test "parse accepts a leading document marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "---\nname: alpha\n...");
    try testing.expectEqualStrings("alpha", value.get(parsed, "name").?.string);
}

test "parse refuses a misaligned key under a sequence item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?yaml.SyntaxError = null;
    try testing.expectError(error.Syntax, yaml.parse(arena.allocator(),
        \\targets:
        \\  - name: alpha
        \\   paths: [bad indent]
    , &err));
    try testing.expectEqual(@as(usize, 3), err.?.line);
}

test "parse refuses a tab used for indentation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?yaml.SyntaxError = null;
    try testing.expectError(error.Syntax, yaml.parse(arena.allocator(), "targets:\n\t- name: alpha", &err));
    try testing.expectEqual(@as(usize, 2), err.?.line);
}

test "parse refuses an unterminated flow sequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?yaml.SyntaxError = null;
    try testing.expectError(error.Syntax, yaml.parse(arena.allocator(), "ignore: [.md, .txt", &err));
    try testing.expect(err != null);
}

test "parse refuses a second document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?yaml.SyntaxError = null;
    try testing.expectError(error.Syntax, yaml.parse(arena.allocator(), "name: a\n---\nname: b", &err));
}

test "parse refuses an unsupported YAML feature rather than guessing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?yaml.SyntaxError = null;
    try testing.expectError(error.Syntax, yaml.parse(arena.allocator(), "base: &anchor\n  name: alpha", &err));
}

test "parse of an empty document is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?yaml.SyntaxError = null;
    try testing.expect(try yaml.parse(arena.allocator(), "", &err) == .null);
    try testing.expect(try yaml.parse(arena.allocator(), "\n\n# only a comment\n", &err) == .null);
}

test "parse reads a top-level sequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "- one\n- two");
    try testing.expectEqual(@as(usize, 2), parsed.array.items.len);
    try testing.expectEqualStrings("two", parsed.array.items[1].string);
}

test "parse reads a bare dash carrying a nested block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(),
        \\targets:
        \\  -
        \\    name: alpha
        \\    paths:
        \\      - src
    );

    const first = value.get(parsed, "targets").?.array.items[0];
    try testing.expectEqualStrings("alpha", value.get(first, "name").?.string);
}

test "parseOrFail names the format and the line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try testing.expectError(error.Failed, yaml.parseOrFail(allocator, "targets:\n  - name: alpha\n   paths: [x]\n", "what-changed config", &fail));
    try testing.expect(std.mem.startsWith(u8, fail.text(), "what-changed config is not valid YAML: "));
    try testing.expect(std.mem.indexOf(u8, fail.text(), "line 3") != null);
}

test "needsQuoting quotes only what would read back as something else" {
    try testing.expect(yaml.needsQuoting(""));
    try testing.expect(yaml.needsQuoting("true"));
    try testing.expect(yaml.needsQuoting("null"));
    try testing.expect(yaml.needsQuoting("42"));
    try testing.expect(yaml.needsQuoting("1.5"));
    try testing.expect(yaml.needsQuoting("- leading dash"));
    try testing.expect(yaml.needsQuoting("key: value"));
    try testing.expect(yaml.needsQuoting("trailing "));
    try testing.expect(yaml.needsQuoting("has # comment"));

    try testing.expect(!yaml.needsQuoting("alpha"));
    try testing.expect(!yaml.needsQuoting(".md"));
    try testing.expect(!yaml.needsQuoting("src/a.ts"));
    try testing.expect(!yaml.needsQuoting("what-changed.yaml"));
    try testing.expect(!yaml.needsQuoting("/tmp/x/.what-changed/baseline.json"));
    try testing.expect(!yaml.needsQuoting("5424073a96f9f8a5"));
    try testing.expect(!yaml.needsQuoting("a#b"));
}

test "stringify renders a report the way the yaml package does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var change = value.newObject(allocator);
    try change.put(allocator, "path", value.str("src/a.ts"));
    try change.put(allocator, "kind", value.str("added"));
    try change.put(allocator, "previousHash", value.str(""));

    var changed = value.newArray(allocator);
    try changed.append(.{ .object = change });

    var root = value.newObject(allocator);
    try root.put(allocator, "hasBaseline", value.boolean(false));
    try root.put(allocator, "fileCount", value.int(4));
    try root.put(allocator, "changed", .{ .array = changed });

    try testing.expectEqualStrings(
        \\hasBaseline: false
        \\fileCount: 4
        \\changed:
        \\  - path: src/a.ts
        \\    kind: added
        \\    previousHash: ""
    , try yaml.stringify(allocator, .{ .object = root }));
}

test "stringify renders a nested sequence inside a sequence item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var watched = value.newArray(allocator);
    try watched.append(value.str("src"));
    try watched.append(value.str("scripts"));

    var target = value.newObject(allocator);
    try target.put(allocator, "name", value.str("unit"));
    try target.put(allocator, "watchedPaths", .{ .array = watched });
    try target.put(allocator, "changed", .{ .array = value.newArray(allocator) });

    var targets = value.newArray(allocator);
    try targets.append(.{ .object = target });

    var root = value.newObject(allocator);
    try root.put(allocator, "targets", .{ .array = targets });

    try testing.expectEqualStrings(
        \\targets:
        \\  - name: unit
        \\    watchedPaths:
        \\      - src
        \\      - scripts
        \\    changed: []
    , try yaml.stringify(allocator, .{ .object = root }));
}

test "stringify renders empty collections on one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = value.newObject(allocator);
    try root.put(allocator, "targets", .{ .array = value.newArray(allocator) });
    try root.put(allocator, "files", .{ .object = value.newObject(allocator) });

    try testing.expectEqualStrings("targets: []\nfiles: {}", try yaml.stringify(allocator, .{ .object = root }));
}

test "stringify renders a scalar on its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings("alpha", try yaml.stringify(allocator, value.str("alpha")));
    try testing.expectEqualStrings("null", try yaml.stringify(allocator, .null));
    try testing.expectEqualStrings("7", try yaml.stringify(allocator, value.int(7)));
}

test "stringify then parse gives back the same document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var target = value.newObject(allocator);
    try target.put(allocator, "name", value.str("unit"));
    try target.put(allocator, "appliesHere", value.boolean(true));
    try target.put(allocator, "previousHash", value.str(""));

    var targets = value.newArray(allocator);
    try targets.append(.{ .object = target });

    var root = value.newObject(allocator);
    try root.put(allocator, "fileCount", value.int(9));
    try root.put(allocator, "targets", .{ .array = targets });

    const round_tripped = try parseForTest(allocator, try yaml.stringify(allocator, .{ .object = root }));

    try testing.expectEqual(@as(i64, 9), value.get(round_tripped, "fileCount").?.integer);
    const first = value.get(round_tripped, "targets").?.array.items[0];
    try testing.expectEqualStrings("unit", value.get(first, "name").?.string);
    try testing.expectEqual(true, value.get(first, "appliesHere").?.bool);
    try testing.expectEqualStrings("", value.get(first, "previousHash").?.string);
}
