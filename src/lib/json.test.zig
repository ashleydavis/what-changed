const std = @import("std");
const value = @import("value.zig");
const json = @import("json.zig");
const failure = @import("failure.zig");
const Failure = failure.Failure;
const testing = std.testing;

test "parse reads objects, arrays and scalars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try json.parse(allocator, "{\"a\": [1, \"two\", true, null]}");
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

    try testing.expectError(error.Syntax, json.parse(arena.allocator(), "{ not json"));
    try testing.expectError(error.Syntax, json.parse(arena.allocator(), ""));
    try testing.expectError(error.Syntax, json.parse(arena.allocator(), "[1, 2"));
}

test "parse keeps object keys in the order they were written" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try json.parse(arena.allocator(), "{\"z\": 1, \"a\": 2, \"m\": 3}");
    const keys = parsed.object.keys();
    try testing.expectEqualStrings("z", keys[0]);
    try testing.expectEqualStrings("a", keys[1]);
    try testing.expectEqualStrings("m", keys[2]);
}

test "stringify indents by two spaces" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object: value.Object = .empty;
    try object.put(allocator, "hasBaseline", value.boolean(true));
    try object.put(allocator, "fileCount", value.int(4));
    try object.put(allocator, "changed", .{ .array = value.newArray(allocator) });

    try testing.expectEqualStrings(
        \\{
        \\  "hasBaseline": true,
        \\  "fileCount": 4,
        \\  "changed": []
        \\}
    , try json.stringify(allocator, .{ .object = object }));
}

test "stringify renders nested arrays of objects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var entry: value.Object = .empty;
    try entry.put(allocator, "path", value.str("src/a.ts"));
    try entry.put(allocator, "previousHash", value.str(""));

    var array = value.newArray(allocator);
    try array.append(.{ .object = entry });

    var object: value.Object = .empty;
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
    , try json.stringify(allocator, .{ .object = object }));
}

test "a stringified value parses back to the same thing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object: value.Object = .empty;
    try object.put(allocator, "name", value.str("alpha"));
    try object.put(allocator, "count", value.int(12));

    const round_tripped = try json.parse(allocator, try json.stringify(allocator, .{ .object = object }));
    try testing.expectEqualStrings("alpha", value.get(round_tripped, "name").?.string);
    try testing.expectEqual(@as(i64, 12), value.get(round_tripped, "count").?.integer);
}

test "parseOrFail names the format in the message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try testing.expectError(error.Failed, json.parseOrFail(allocator, "{ not json", "what-changed config", &fail));
    try testing.expect(std.mem.startsWith(u8, fail.text(), "what-changed config is not valid JSON: "));
}

test "parseDetailed says what was wrong" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var detail: ?[]const u8 = null;
    try testing.expectError(error.Syntax, json.parseDetailed(allocator, "[1, 2", &detail));
    try testing.expect(detail != null);
    try testing.expect(detail.?.len > 0);
}

test "parseOrFail returns the value when the text is good" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    const parsed = try json.parseOrFail(allocator, "{\"ok\": true}", "what-changed config", &fail);
    try testing.expectEqual(true, value.get(parsed, "ok").?.bool);
    try testing.expect(fail.message == null);
}
