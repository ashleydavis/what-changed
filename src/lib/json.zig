const std = @import("std");
const annotate_mod = @import("log");

//
// The branch markers a fault run reads back. `an` is a compile-time flag: the binary people run is
// built with it off, so every `if (an) annotate(...)` below compiles to nothing there.
//
const Log = annotate_mod.Log;
const an = annotate_mod.an;
const annotate = annotate_mod.annotate;
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
pub fn parseDetailed(allocator: std.mem.Allocator, text: []const u8, detail: *?[]const u8, log: Log) error{ Syntax, OutOfMemory }!Value {
    return std.json.parseFromSliceLeaky(Value, allocator, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => {
            if (an) annotate(log, "parseDetailed-no-room", "", .{});
            return error.OutOfMemory;
        },
        error.UnexpectedEndOfInput => {
                if (an) annotate(log, "parseDetailed-ends-early", "", .{});
                detail.* = "it ends in the middle of a value";
                return error.Syntax;
            },
            // Reading into a dynamic value keeps every number as the text it was written with, so
            // nothing here is ever asked to fit one into a type it will not fit.
            error.InvalidNumber, error.Overflow => unreachable,
            error.InvalidCharacter, error.SyntaxError => {
                if (an) annotate(log, "parseDetailed-bad-character", "", .{});
                detail.* = "it holds a character that cannot appear there";
                return error.Syntax;
            },
            // Everything else the reader can refuse is one of the three above: a dynamic value has
            // no fields to be missing, no enum to be wrong and no length to mismatch.
        else => unreachable,
    };
}

//
// Parses JSON text, for the callers that only care whether it worked.
//
pub fn parse(allocator: std.mem.Allocator, text: []const u8, log: Log) error{ Syntax, OutOfMemory }!Value {
    var detail: ?[]const u8 = null;
    return parseDetailed(allocator, text, &detail, log);
}

//
// Renders a value as JSON indented by two spaces.
//
// The exact formatting is fixed rather than incidental: two spaces, empty arrays as `[]` on one
// line, empty objects as `{}`. `--output json` gets diffed between runs, and a baseline file
// written by one run is read back by the next.
//
pub fn stringify(allocator: std.mem.Allocator, root: Value, log: Log) std.mem.Allocator.Error![]const u8 {
    var rendered = std.Io.Writer.Allocating.init(allocator);
    errdefer rendered.deinit();

    std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &rendered.writer) catch {
        if (an) annotate(log, "stringify-no-room", "", .{});
        return error.OutOfMemory;
    };
    return rendered.toOwnedSlice();
}

//
// Parses JSON text, failing with a message that names the format, for the places where malformed
// input is an error the user has to see.
//
pub fn parseOrFail(allocator: std.mem.Allocator, text: []const u8, description: []const u8, fail: *Failure) failure.Error!Value {
    var detail: ?[]const u8 = null;
    return parseDetailed(allocator, text, &detail, fail.log) catch |err| switch (err) {
        error.OutOfMemory => {
            if (an) annotate(fail.log, "parseOrFail-no-room", "", .{});
            return error.OutOfMemory;
        },
        error.Syntax => {
            if (an) annotate(fail.log, "parseOrFail-a-syntax-error", "", .{});
            // Every refusal above says what was wrong with the text before it hands the error back,
            // so one always arrives here.
            const said = detail orelse unreachable;
            return fail.set("{s} is not valid JSON: {s}", .{ description, said });
        },
    };
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("json.test.zig");
}
