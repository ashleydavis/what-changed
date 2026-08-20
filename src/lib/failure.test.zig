const std = @import("std");
const failure = @import("failure.zig");
const testing = std.testing;

test "set records the message and returns the error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = failure.Failure.init(arena.allocator());

    //
    // `set` hands back a bare error value rather than an error union, so it can be returned from a
    // function whatever that function's success type is. That is why this compares it directly
    // instead of using expectError, which wants a union to unwrap.
    //
    try testing.expectEqual(failure.Error.Failed, fail.set("bad thing: {s}", .{"here"}));
    try testing.expectEqualStrings("bad thing: here", fail.text());
}

test "the first message wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = failure.Failure.init(arena.allocator());
    _ = fail.set("first", .{}) catch {};
    _ = fail.set("second", .{}) catch {};
    try testing.expectEqualStrings("first", fail.text());
}

test "text stands in when nothing was recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const fail = failure.Failure.init(arena.allocator());
    try testing.expectEqualStrings("what-changed failed without saying why.", fail.text());
}

test "init leaves no message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const fail = failure.Failure.init(arena.allocator());
    try testing.expect(fail.message == null);
}
