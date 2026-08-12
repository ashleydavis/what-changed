const std = @import("std");

//
// How the message that goes with a failure is carried.
//
// Zig errors are bare enum values and cannot carry a string, so the string travels beside the error
// instead: every function that can fail takes a `*Failure`, fills in its message, and returns
// `error.Failed`. The top of the CLI prints whatever is in there.
//
// This is deliberately not one error value per failure mode. Nothing in this tool branches on which
// failure happened: every one of them ends the same way, printed to stderr with exit code 1. What
// matters is that the wording reaches the user, so that is the part that is modelled.
//

//
// The error every fallible function in this project returns.
//
// `Failed` means "a message has been left in the Failure". `OutOfMemory` is unavoidable in Zig and
// is handled at the top of the CLI like any other failure, so callers never have to think about it.
//
pub const Error = error{Failed} || std.mem.Allocator.Error;

//
// Carries the message describing why something failed, back to whoever is going to print it.
//
pub const Failure = struct {
    //
    // Where the message is allocated. An arena in the real CLI, so nothing has to be freed on the
    // way out of a failing run.
    //
    allocator: std.mem.Allocator,

    //
    // The message, or null when nothing has failed yet.
    //
    message: ?[]const u8 = null,

    //
    // Makes a Failure that allocates its messages from the given allocator.
    //
    pub fn init(allocator: std.mem.Allocator) Failure {
        return .{ .allocator = allocator };
    }

    //
    // Records a message and returns the error to return, so a caller can write the whole thing as
    // one statement: `return fail.set("...", .{});`
    //
    // The first message wins. A failure deep in the call stack is the one that says what actually
    // went wrong; anything added on the way out would only describe the unwinding.
    //
    pub fn set(self: *Failure, comptime fmt: []const u8, args: anytype) Error {
        if (self.message == null) {
            self.message = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
        }
        return error.Failed;
    }

    //
    // The recorded message, or a stand-in when something returned `error.Failed` without leaving
    // one. That stand-in should never be seen; it is here so a bug in this tool prints something a
    // person can act on rather than nothing at all.
    //
    pub fn text(self: *const Failure) []const u8 {
        return self.message orelse "what-changed failed without saying why.";
    }
};

const testing = std.testing;

test "set records the message and returns the error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());

    //
    // `set` hands back a bare error value rather than an error union, so it can be returned from a
    // function whatever that function's success type is. That is why this compares it directly
    // instead of using expectError, which wants a union to unwrap.
    //
    try testing.expectEqual(Error.Failed, fail.set("bad thing: {s}", .{"here"}));
    try testing.expectEqualStrings("bad thing: here", fail.text());
}

test "the first message wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    _ = fail.set("first", .{}) catch {};
    _ = fail.set("second", .{}) catch {};
    try testing.expectEqualStrings("first", fail.text());
}

test "text stands in when nothing was recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const fail = Failure.init(arena.allocator());
    try testing.expectEqualStrings("what-changed failed without saying why.", fail.text());
}

test "init leaves no message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const fail = Failure.init(arena.allocator());
    try testing.expect(fail.message == null);
}
