const std = @import("std");
const value = @import("value.zig");

//
// A map of repository-relative path to content hash.
//
// One type covers both uses: the tree that was just hashed, and the same thing read back out of a
// JSON file. `std.StringArrayHashMapUnmanaged` keeps its keys in insertion order, which is what a
// JSON object does too, so nothing has to be converted between the two.
//
pub const FileHashes = std.StringArrayHashMapUnmanaged([]const u8);

//
// Every path in the map, sorted.
//
// Sorted rather than in insertion order because callers use this where the order is part of the
// answer: what gets printed, and what gets hashed into a directory's digest. Leaving it to
// insertion order would make the tool's output depend on the order git happened to list files in.
//
pub fn sortedKeys(allocator: std.mem.Allocator, hashes: *const FileHashes) std.mem.Allocator.Error![][]const u8 {
    const keys = try allocator.dupe([]const u8, hashes.keys());
    std.mem.sort([]const u8, keys, {}, lessThanPath);
    return keys;
}

//
// Orders two paths, for sorting.
//
pub fn lessThanPath(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

//
// Turns a map into the JSON object that gets written to disk, with the paths in sorted order.
//
// Sorted so that two runs that saw the same tree write byte-identical files, whatever order the
// file lister returned. A file that changes for no reason is noise in a diff and a needless write.
//
pub fn toValue(allocator: std.mem.Allocator, hashes: *const FileHashes) std.mem.Allocator.Error!value.Value {
    var object = value.newObject(allocator);
    for (try sortedKeys(allocator, hashes)) |path| {
        try object.put(allocator, path, value.str(hashes.get(path).?));
    }
    return .{ .object = object };
}

//
// Reads a map back from a JSON object, ignoring any entry that is not a string.
//
// Anything unreadable is dropped rather than refused. A damaged record should cost a file being
// treated as changed, which is the safe direction, rather than a run that will not start.
//
pub fn fromValue(allocator: std.mem.Allocator, parsed: value.Value) std.mem.Allocator.Error!FileHashes {
    var hashes: FileHashes = .empty;

    switch (parsed) {
        .object => |object| {
            var walker = object.iterator();
            while (walker.next()) |entry| {
                switch (entry.value_ptr.*) {
                    .string => |hash| try hashes.put(allocator, entry.key_ptr.*, hash),
                    else => {},
                }
            }
        },
        else => {},
    }

    return hashes;
}

const testing = std.testing;

//
// Builds a map from pairs, so a test case is one line.
//
pub fn fromPairs(allocator: std.mem.Allocator, pairs: []const [2][]const u8) std.mem.Allocator.Error!FileHashes {
    var hashes: FileHashes = .empty;
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

    const keys = try sortedKeys(allocator, &hashes);
    try testing.expectEqualStrings("package.json", keys[0]);
    try testing.expectEqualStrings("src/a.ts", keys[1]);
    try testing.expectEqualStrings("src/z.ts", keys[2]);
}

test "sortedKeys of an empty map is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes: FileHashes = .empty;
    try testing.expectEqual(@as(usize, 0), (try sortedKeys(allocator, &hashes)).len);
}

test "lessThanPath orders paths bytewise" {
    try testing.expect(lessThanPath({}, "a", "b"));
    try testing.expect(!lessThanPath({}, "b", "a"));
    try testing.expect(!lessThanPath({}, "a", "a"));
    try testing.expect(lessThanPath({}, "src", "src/a.ts"));
}

test "toValue writes the paths in sorted order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try fromPairs(allocator, &.{ .{ "b.ts", "2" }, .{ "a.ts", "1" } });
    const rendered = try toValue(allocator, &hashes);

    try testing.expectEqualStrings("a.ts", rendered.object.keys()[0]);
    try testing.expectEqualStrings("b.ts", rendered.object.keys()[1]);
    try testing.expectEqualStrings("1", value.get(rendered, "a.ts").?.string);
}

test "toValue of an empty map is an empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes: FileHashes = .empty;
    try testing.expectEqual(@as(usize, 0), (try toValue(allocator, &hashes)).object.count());
}

test "fromValue reads a JSON object back into a map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object = value.newObject(allocator);
    try object.put(allocator, "src/a.ts", value.str("hash-a"));
    try object.put(allocator, "src/b.ts", value.str("hash-b"));

    var hashes = try fromValue(allocator, .{ .object = object });
    try testing.expectEqual(@as(usize, 2), hashes.count());
    try testing.expectEqualStrings("hash-a", hashes.get("src/a.ts").?);
}

test "fromValue drops entries that are not strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object = value.newObject(allocator);
    try object.put(allocator, "good.ts", value.str("hash"));
    try object.put(allocator, "bad.ts", value.int(7));
    try object.put(allocator, "worse.ts", .null);

    var hashes = try fromValue(allocator, .{ .object = object });
    try testing.expectEqual(@as(usize, 1), hashes.count());
    try testing.expect(hashes.get("bad.ts") == null);
}

test "fromValue of anything that is not an object is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try fromValue(allocator, .null)).count());
    try testing.expectEqual(@as(usize, 0), (try fromValue(allocator, value.str("x"))).count());
    try testing.expectEqual(@as(usize, 0), (try fromValue(allocator, .{ .array = value.newArray(allocator) })).count());
}

test "a map survives a round trip through a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try fromPairs(allocator, &.{ .{ "a.ts", "1" }, .{ "b.ts", "2" } });
    var round_tripped = try fromValue(allocator, try toValue(allocator, &hashes));

    try testing.expectEqual(@as(usize, 2), round_tripped.count());
    try testing.expectEqualStrings("1", round_tripped.get("a.ts").?);
    try testing.expectEqualStrings("2", round_tripped.get("b.ts").?);
}
