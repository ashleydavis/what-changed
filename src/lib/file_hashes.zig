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
    var object: value.Object = .empty;
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

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("file_hashes.test.zig");
}
