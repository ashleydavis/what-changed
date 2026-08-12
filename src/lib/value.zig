const std = @import("std");

//
// The value used wherever the structure is not known at compile time.
//
// Three things in this tool are like that: the parsed config, which may be malformed in any way at
// all, the JSON read back off disk, and the object handed to `--output json` / `--output yaml`.
//
// All three use `std.json.Value`, a tagged union over null, bool, number, string, array and object.
// Using the standard library's type rather than a hand-rolled one means `std.json` parses and
// renders it for free, and both the YAML parser and the YAML renderer in this project work on the
// same type, so a config in either format lands in an identical structure and every check
// downstream is written once.
//
// Objects preserve insertion order (`std.json.ObjectMap` is an array hash map). That is not a
// detail: it is what makes the rendered output depend on the document rather than on a hash seed,
// so two runs over the same input print the same bytes.
//

//
// A value of any type: null, bool, number, string, array or object.
//
pub const Value = std.json.Value;

//
// An object: an insertion-ordered map of string keys to values.
//
pub const Object = std.json.ObjectMap;

//
// An array of values.
//
pub const Array = std.json.Array;

//
// Makes an empty object.
//
pub fn newObject(allocator: std.mem.Allocator) Object {
    //
    // The object holds no allocator of its own: every `put` takes one. The parameter stays so the
    // call sites read the same as the array ones beside them, and so this can go back to holding an
    // allocator without touching them if the standard library changes again.
    //
    _ = allocator;
    return .empty;
}

//
// Makes an empty array.
//
pub fn newArray(allocator: std.mem.Allocator) Array {
    return Array.init(allocator);
}

//
// Wraps a string as a value, so building an object reads as a list of fields rather than as a list
// of union initialisers.
//
pub fn str(text: []const u8) Value {
    return .{ .string = text };
}

//
// Wraps a boolean as a value.
//
pub fn boolean(value: bool) Value {
    return .{ .bool = value };
}

//
// Wraps a whole number as a value.
//
pub fn int(value: i64) Value {
    return .{ .integer = value };
}

//
// Reads a field off a value.
//
// Anything that is not an object has no fields, so it answers null rather than failing. That is
// what lets the config checks read a field and then complain about its value, instead of having to
// prove the whole document is an object at every step.
//
pub fn get(value: Value, key: []const u8) ?Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

//
// True for a plain object, which is what both halves of the baseline have to be.
//
// An array is a different tag, so it is excluded without having to be named.
//
pub fn isPlainObject(value: Value) bool {
    return value == .object;
}

//
// Renders a value for dropping into an error message: compact, with no whitespace at all.
//
// A missing field renders as "undefined" rather than "null", so a config that leaves a field out
// entirely reads as `got undefined`, which is a different complaint from one that set it to null.
//
pub fn describe(allocator: std.mem.Allocator, value: ?Value) std.mem.Allocator.Error![]const u8 {
    const present = value orelse return allocator.dupe(u8, "undefined");

    var rendered = std.Io.Writer.Allocating.init(allocator);
    errdefer rendered.deinit();

    std.json.Stringify.value(present, .{}, &rendered.writer) catch return error.OutOfMemory;
    return rendered.toOwnedSlice();
}

const testing = std.testing;

test "newObject and newArray start empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), newObject(allocator).count());
    try testing.expectEqual(@as(usize, 0), newArray(allocator).items.len);
}

test "str, boolean and int wrap their values" {
    try testing.expectEqualStrings("hello", str("hello").string);
    try testing.expectEqual(true, boolean(true).bool);
    try testing.expectEqual(@as(i64, 7), int(7).integer);
}

test "get reads a field off an object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var object = newObject(allocator);
    try object.put(allocator, "name", str("alpha"));
    const value = Value{ .object = object };

    try testing.expectEqualStrings("alpha", get(value, "name").?.string);
    try testing.expect(get(value, "missing") == null);
}

test "get answers null for anything that is not an object" {
    try testing.expect(get(str("text"), "name") == null);
    try testing.expect(get(.null, "name") == null);
    try testing.expect(get(int(1), "name") == null);
}

test "isPlainObject accepts objects and rejects everything else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expect(isPlainObject(.{ .object = newObject(allocator) }));
    try testing.expect(!isPlainObject(.{ .array = newArray(allocator) }));
    try testing.expect(!isPlainObject(.null));
    try testing.expect(!isPlainObject(str("text")));
    try testing.expect(!isPlainObject(int(3)));
}

test "describe renders values compactly, for dropping into a message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings("undefined", try describe(allocator, null));
    try testing.expectEqualStrings("null", try describe(allocator, .null));
    try testing.expectEqualStrings("\"alpha\"", try describe(allocator, str("alpha")));
    try testing.expectEqualStrings("7", try describe(allocator, int(7)));
    try testing.expectEqualStrings("true", try describe(allocator, boolean(true)));
    try testing.expectEqualStrings("[]", try describe(allocator, .{ .array = newArray(allocator) }));

    var array = newArray(allocator);
    try array.append(int(1));
    try array.append(str("two"));
    try testing.expectEqualStrings("[1,\"two\"]", try describe(allocator, .{ .array = array }));
}
