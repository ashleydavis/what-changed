const std = @import("std");
const value = @import("value.zig");
const file_hashes = @import("file_hashes.zig");
const testing = std.testing;

//
// Builds a map from pairs, so a test case is one line.
//
pub fn fromPairs(allocator: std.mem.Allocator, pairs: []const [2][]const u8) std.mem.Allocator.Error!file_hashes.FileHashes {
    var hashes: file_hashes.FileHashes = .empty;
    for (pairs) |pair| {
        try hashes.put(allocator, pair[0], pair[1]);
    }
    return hashes;
}

test "sortedKeys sorts whatever order the entries went in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try fromPairs(allocator, &.{
        .{ "src/z.ts", "3" },
        .{ "src/a.ts", "1" },
        .{ "package.json", "2" },
    });

    const keys = try file_hashes.sortedKeys(allocator, &hashes);
    try testing.expectEqualStrings("package.json", keys[0]);
    try testing.expectEqualStrings("src/a.ts", keys[1]);
    try testing.expectEqualStrings("src/z.ts", keys[2]);
}

test "sortedKeys of an empty map is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes: file_hashes.FileHashes = .empty;
    try testing.expectEqual(@as(usize, 0), (try file_hashes.sortedKeys(allocator, &hashes)).len);
}

test "lessThanPath orders paths bytewise" {
    try testing.expect(file_hashes.lessThanPath({}, "a", "b"));
    try testing.expect(!file_hashes.lessThanPath({}, "b", "a"));
    try testing.expect(!file_hashes.lessThanPath({}, "a", "a"));
    try testing.expect(file_hashes.lessThanPath({}, "src", "src/a.ts"));
}

test "toValue writes the paths in sorted order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try fromPairs(allocator, &.{ .{ "b.ts", "2" }, .{ "a.ts", "1" } });
    const rendered = try file_hashes.toValue(allocator, &hashes);

    try testing.expectEqualStrings("a.ts", rendered.object.keys()[0]);
    try testing.expectEqualStrings("b.ts", rendered.object.keys()[1]);
    try testing.expectEqualStrings("1", value.get(rendered, "a.ts").?.string);
}

test "toValue of an empty map is an empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes: file_hashes.FileHashes = .empty;
    try testing.expectEqual(@as(usize, 0), (try file_hashes.toValue(allocator, &hashes)).object.count());
}

test "fromValue reads a JSON object back into a map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object: value.Object = .empty;
    try object.put(allocator, "src/a.ts", value.str("hash-a"));
    try object.put(allocator, "src/b.ts", value.str("hash-b"));

    var hashes = try file_hashes.fromValue(allocator, .{ .object = object });
    try testing.expectEqual(@as(usize, 2), hashes.count());
    try testing.expectEqualStrings("hash-a", hashes.get("src/a.ts").?);
}

test "fromValue drops entries that are not strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object: value.Object = .empty;
    try object.put(allocator, "good.ts", value.str("hash"));
    try object.put(allocator, "bad.ts", value.int(7));
    try object.put(allocator, "worse.ts", .null);

    var hashes = try file_hashes.fromValue(allocator, .{ .object = object });
    try testing.expectEqual(@as(usize, 1), hashes.count());
    try testing.expect(hashes.get("bad.ts") == null);
}

test "fromValue of anything that is not an object is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try file_hashes.fromValue(allocator, .null)).count());
    try testing.expectEqual(@as(usize, 0), (try file_hashes.fromValue(allocator, value.str("x"))).count());
    try testing.expectEqual(@as(usize, 0), (try file_hashes.fromValue(allocator, .{ .array = value.newArray(allocator) })).count());
}

test "a map survives a round trip through a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try fromPairs(allocator, &.{ .{ "a.ts", "1" }, .{ "b.ts", "2" } });
    var round_tripped = try file_hashes.fromValue(allocator, try file_hashes.toValue(allocator, &hashes));

    try testing.expectEqual(@as(usize, 2), round_tripped.count());
    try testing.expectEqualStrings("1", round_tripped.get("a.ts").?);
    try testing.expectEqualStrings("2", round_tripped.get("b.ts").?);
}
