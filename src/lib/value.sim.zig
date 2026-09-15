// What a run cannot put together for itself in `value.zig`.
//
// A `Value` is a tagged union over, among other things, a hash map and a list. Built field by field
// from a type, its pointers and its lengths have nothing to do with each other, so the first read of
// one faults and every function taking one is stepped over. These factories hand back real ones.

const std = @import("std");
const value = @import("value.zig");

const Value = value.Value;

// What a made `Value` is built from. Every field is filled from its own type, so the run gets a
// different value on each call without anything here deciding which.
// Which arm of a value the run is asking for.
pub const Kind = enum { nothing, flag, whole, fractional, text, list, object };

pub const MadeValue = struct {
    // Which of the union's arms this one is. An enum rather than a number, because the run draws
    // one of every enum value and a number wrapped around seven reached two of the seven.
    kind: Kind,

    // The text a string arm carries, and the key an object arm puts its entry under.
    text: []const u8,

    // What a number arm carries.
    whole: i64,

    // What a bool arm carries.
    flag: bool,

    // How many entries an array or an object arm holds, so the zero, one and many sides of every
    // loop over one are all reached, and every key below is reached by something.
    entries: u3,
};

// A whole `Value`, allocated from the run's own arena so what it points at outlives the call.
//
// The arms that hold other values hold strings rather than more of these: a factory that built a
// value inside a value would recurse as deep as the run asked it to, and nothing in this tool reads
// a config nested beyond that.
pub fn valueFrom(state: *MadeValue, allocator: std.mem.Allocator) Value {
    return switch (state.kind) {
        .nothing => .null,
        .flag => .{ .bool = state.flag },
        .whole => .{ .integer = state.whole },
        .fractional => .{ .float = @floatFromInt(@mod(state.whole, 1000)) },
        .text => .{ .string = state.text },
        .list => .{ .array = arrayFrom(state, allocator) },
        .object => .{ .object = objectFrom(state, allocator) },
    };
}

// An array of strings, as many as the state asks for.
pub fn arrayFrom(state: *MadeValue, allocator: std.mem.Allocator) value.Array {
    var array = value.Array.init(allocator);
    var at: usize = 0;
    while (at < state.entries) : (at += 1) {
        array.append(.{ .string = state.text }) catch return array;
    }
    return array;
}

// An object of string entries, keyed apart so several entries really are several.
//
// The keys are this file's own rather than the state's, because two entries under one key are one
// entry, and a loop that can only ever go round once cannot reach its own many side.
pub fn objectFrom(state: *MadeValue, allocator: std.mem.Allocator) value.Object {
    const keys = [_][]const u8{ "targets", "files", "name", "paths", "platforms" };
    var object: value.Object = .empty;
    var at: usize = 0;
    while (at < state.entries and at < keys.len) : (at += 1) {
        object.put(allocator, keys[at], .{ .string = state.text }) catch return object;
    }
    return object;
}

const sim = @import("sim");
const Subject = sim.Subject(@import("log").Log);
