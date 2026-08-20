const std = @import("std");
const value = @import("value.zig");
const testing = std.testing;

test "newObject and newArray start empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), value.newObject(allocator).count());
    try testing.expectEqual(@as(usize, 0), value.newArray(allocator).items.len);
}

test "str, boolean and int wrap their values" {
    try testing.expectEqualStrings("hello", value.str("hello").string);
    try testing.expectEqual(true, value.boolean(true).bool);
    try testing.expectEqual(@as(i64, 7), value.int(7).integer);
}

test "get reads a field off an object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object = value.newObject(allocator);
    try object.put(allocator, "name", value.str("alpha"));
    const wrapped = value.Value{ .object = object };

    try testing.expectEqualStrings("alpha", value.get(wrapped, "name").?.string);
    try testing.expect(value.get(wrapped, "missing") == null);
}

test "get answers null for anything that is not an object" {
    try testing.expect(value.get(value.str("text"), "name") == null);
    try testing.expect(value.get(.null, "name") == null);
    try testing.expect(value.get(value.int(1), "name") == null);
}

test "isPlainObject accepts objects and rejects everything else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expect(value.isPlainObject(.{ .object = value.newObject(allocator) }));
    try testing.expect(!value.isPlainObject(.{ .array = value.newArray(allocator) }));
    try testing.expect(!value.isPlainObject(.null));
    try testing.expect(!value.isPlainObject(value.str("text")));
    try testing.expect(!value.isPlainObject(value.int(3)));
}

test "describe renders values compactly, for dropping into a message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings("undefined", try value.describe(allocator, null));
    try testing.expectEqualStrings("null", try value.describe(allocator, .null));
    try testing.expectEqualStrings("\"alpha\"", try value.describe(allocator, value.str("alpha")));
    try testing.expectEqualStrings("7", try value.describe(allocator, value.int(7)));
    try testing.expectEqualStrings("true", try value.describe(allocator, value.boolean(true)));
    try testing.expectEqualStrings("[]", try value.describe(allocator, .{ .array = value.newArray(allocator) }));

    var array = value.newArray(allocator);
    try array.append(value.int(1));
    try array.append(value.str("two"));
    try testing.expectEqualStrings("[1,\"two\"]", try value.describe(allocator, .{ .array = array }));
}
