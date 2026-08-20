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

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("json.test.zig");
}
