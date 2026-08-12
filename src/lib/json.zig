const std = @import("std");
const value = @import("value.zig");
const failure = @import("failure.zig");

const Value = value.Value;
const Failure = failure.Failure;

//
// Reading and writing JSON.
//
// Both directions go through `std.json` rather than anything hand-written here: a hand-rolled
// parser is a source of bugs nobody is paid to find. All this file adds is the wrapping, so a parse
// failure carries a message worded like every other failure in the tool.
//

//
// Parses JSON text into a dynamic value, reporting a syntax error rather than crashing, and leaving
// a short description of what was wrong with it.
//
// The message is the caller's, not this function's, because the same parse is reported differently
// depending on what was being read: a config says "what-changed config is not valid JSON", while a
// damaged cache file says nothing at all and is quietly treated as empty.
//
pub fn parseDetailed(allocator: std.mem.Allocator, text: []const u8, detail: *?[]const u8) error{ Syntax, OutOfMemory }!Value {
    return std.json.parseFromSliceLeaky(Value, allocator, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnexpectedEndOfInput => {
            detail.* = "it ends in the middle of a value";
            return error.Syntax;
        },
        error.InvalidNumber, error.Overflow => {
            detail.* = "it holds a number JSON cannot represent";
            return error.Syntax;
        },
        error.InvalidCharacter, error.SyntaxError => {
            detail.* = "it holds a character that cannot appear there";
            return error.Syntax;
        },
        else => {
            detail.* = "it is not well formed";
            return error.Syntax;
        },
    };
}

//
// Parses JSON text, for the callers that only care whether it worked.
//
pub fn parse(allocator: std.mem.Allocator, text: []const u8) error{ Syntax, OutOfMemory }!Value {
    var detail: ?[]const u8 = null;
    return parseDetailed(allocator, text, &detail);
}

//
// Renders a value as JSON indented by two spaces.
//
// The exact formatting is fixed rather than incidental: two spaces, empty arrays as `[]` on one
// line, empty objects as `{}`. `--output json` gets diffed between runs, and a baseline file
// written by one run is read back by the next.
//
pub fn stringify(allocator: std.mem.Allocator, root: Value) std.mem.Allocator.Error![]const u8 {
    var rendered = std.Io.Writer.Allocating.init(allocator);
    errdefer rendered.deinit();

    std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &rendered.writer) catch return error.OutOfMemory;
    return rendered.toOwnedSlice();
}

//
// Parses JSON text, failing with a message that names the format, for the places where malformed
// input is an error the user has to see.
//
pub fn parseOrFail(allocator: std.mem.Allocator, text: []const u8, description: []const u8, fail: *Failure) failure.Error!Value {
    var detail: ?[]const u8 = null;
    return parseDetailed(allocator, text, &detail) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Syntax => fail.set("{s} is not valid JSON: {s}", .{ description, detail orelse "it is not well formed" }),
    };
}

const testing = std.testing;

test "parse reads objects, arrays and scalars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, "{\"a\": [1, \"two\", true, null]}");
    const array = value.get(parsed, "a").?.array;
    try testing.expectEqual(@as(usize, 4), array.items.len);
    try testing.expectEqual(@as(i64, 1), array.items[0].integer);
    try testing.expectEqualStrings("two", array.items[1].string);
    try testing.expectEqual(true, array.items[2].bool);
    try testing.expect(array.items[3] == .null);
}

test "parse reports a syntax error rather than crashing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.Syntax, parse(arena.allocator(), "{ not json"));
    try testing.expectError(error.Syntax, parse(arena.allocator(), ""));
    try testing.expectError(error.Syntax, parse(arena.allocator(), "[1, 2"));
}

test "parse keeps object keys in the order they were written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parse(arena.allocator(), "{\"z\": 1, \"a\": 2, \"m\": 3}");
    const keys = parsed.object.keys();
    try testing.expectEqualStrings("z", keys[0]);
    try testing.expectEqualStrings("a", keys[1]);
    try testing.expectEqualStrings("m", keys[2]);
}

test "stringify indents by two spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object = value.newObject(allocator);
    try object.put(allocator, "hasBaseline", value.boolean(true));
    try object.put(allocator, "fileCount", value.int(4));
    try object.put(allocator, "changed", .{ .array = value.newArray(allocator) });

    try testing.expectEqualStrings(
        \\{
        \\  "hasBaseline": true,
        \\  "fileCount": 4,
        \\  "changed": []
        \\}
    , try stringify(allocator, .{ .object = object }));
}

test "stringify renders nested arrays of objects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var entry = value.newObject(allocator);
    try entry.put(allocator, "path", value.str("src/a.ts"));
    try entry.put(allocator, "previousHash", value.str(""));

    var array = value.newArray(allocator);
    try array.append(.{ .object = entry });

    var object = value.newObject(allocator);
    try object.put(allocator, "changed", .{ .array = array });

    try testing.expectEqualStrings(
        \\{
        \\  "changed": [
        \\    {
        \\      "path": "src/a.ts",
        \\      "previousHash": ""
        \\    }
        \\  ]
        \\}
    , try stringify(allocator, .{ .object = object }));
}

test "a stringified value parses back to the same thing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object = value.newObject(allocator);
    try object.put(allocator, "name", value.str("alpha"));
    try object.put(allocator, "count", value.int(12));

    const round_tripped = try parse(allocator, try stringify(allocator, .{ .object = object }));
    try testing.expectEqualStrings("alpha", value.get(round_tripped, "name").?.string);
    try testing.expectEqual(@as(i64, 12), value.get(round_tripped, "count").?.integer);
}

test "parseOrFail names the format in the message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try testing.expectError(error.Failed, parseOrFail(allocator, "{ not json", "what-changed config", &fail));
    try testing.expect(std.mem.startsWith(u8, fail.text(), "what-changed config is not valid JSON: "));
}

test "parseDetailed says what was wrong" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var detail: ?[]const u8 = null;
    try testing.expectError(error.Syntax, parseDetailed(allocator, "[1, 2", &detail));
    try testing.expect(detail != null);
    try testing.expect(detail.?.len > 0);
}

test "parseOrFail returns the value when the text is good" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    const parsed = try parseOrFail(allocator, "{\"ok\": true}", "what-changed config", &fail);
    try testing.expectEqual(true, value.get(parsed, "ok").?.bool);
    try testing.expect(fail.message == null);
}
