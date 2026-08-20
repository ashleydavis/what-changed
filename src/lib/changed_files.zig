const std = @import("std");
const value = @import("value.zig");
const file_hashes = @import("file_hashes.zig");

const FileHashes = file_hashes.FileHashes;

//
// What happened to one file since the baseline was recorded.
//
pub const FileChangeKind = enum {
    added,
    modified,
    deleted,

    //
    // The file is on disk and could not be read, so whether its content differs is unknown.
    //
    // Counted as a change rather than left out, because a file whose content cannot be seen cannot be
    // called unchanged. It is its own kind rather than a modification so that the report says why,
    // and so it does not read as a deletion, which is what it looked like when every failure produced
    // the same answer.
    //
    unreadable,

    //
    // The word the machine-readable output uses.
    //
    pub fn text(self: FileChangeKind) []const u8 {
        return @tagName(self);
    }

    //
    // The one letter the text output uses.
    //
    pub fn marker(self: FileChangeKind) u8 {
        return switch (self) {
            .added => 'A',
            .modified => 'M',
            .deleted => 'D',
            .unreadable => 'U',
        };
    }
};

//
// One file that differs from the baseline.
//
pub const ChangedFile = struct {
    //
    // The repository-relative path.
    //
    path: []const u8,

    //
    // Whether the file was added, modified or deleted since the baseline.
    //
    kind: FileChangeKind,

    //
    // The file's current content hash, or an empty string when there is no current one: a deleted
    // file, or one that could not be read.
    //
    hash: []const u8,

    //
    // The file's content hash in the baseline, or an empty string for a file the baseline has never
    // held.
    //
    previous_hash: []const u8,

    //
    // Renders this change as the object the machine-readable formats print. The field names are
    // part of the tool's output, so a script reading the JSON can rely on them.
    //
    pub fn toValue(self: ChangedFile, allocator: std.mem.Allocator) std.mem.Allocator.Error!value.Value {
        var object = value.newObject(allocator);
        try object.put(allocator, "path", value.str(self.path));
        try object.put(allocator, "kind", value.str(self.kind.text()));
        try object.put(allocator, "hash", value.str(self.hash));
        try object.put(allocator, "previousHash", value.str(self.previous_hash));
        return .{ .object = object };
    }
};

//
// Renders a list of changes as the array the machine-readable formats print.
//
pub fn toValueArray(allocator: std.mem.Allocator, changes: []const ChangedFile) std.mem.Allocator.Error!value.Value {
    var array = value.newArray(allocator);
    for (changes) |change| {
        try array.append(try change.toValue(allocator));
    }
    return .{ .array = array };
}

//
// Orders two changes by path, for sorting.
//
fn lessThanChange(_: void, left: ChangedFile, right: ChangedFile) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

//
// Compares the working tree's file hashes against the baseline recorded at the last passing run and
// returns every difference, sorted by path. Pure, so the whole comparison is testable without a disk.
//
// `current` holds only files that were read, so a file absent from it and present in the baseline was
// deleted. `unreadable` names the ones that are on disk and could not be read: they are absent from
// `current` for a different reason, so they are reported as their own kind rather than being counted
// among the deletions.
//
pub fn diffFileHashes(allocator: std.mem.Allocator, current: *const FileHashes, baseline: *const FileHashes, unreadable: []const []const u8) std.mem.Allocator.Error![]ChangedFile {
    var changes: std.ArrayList(ChangedFile) = .empty;

    var could_not_read: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (unreadable) |relative_path| {
        try could_not_read.put(allocator, relative_path, {});
        try changes.append(allocator, .{
            .path = relative_path,
            .kind = .unreadable,
            .hash = "",
            .previous_hash = baseline.get(relative_path) orelse "",
        });
    }

    var walker = current.iterator();
    while (walker.next()) |entry| {
        const relative_path = entry.key_ptr.*;
        const hash = entry.value_ptr.*;

        const previous_hash = baseline.get(relative_path) orelse {
            try changes.append(allocator, .{ .path = relative_path, .kind = .added, .hash = hash, .previous_hash = "" });
            continue;
        };
        if (!std.mem.eql(u8, previous_hash, hash)) {
            try changes.append(allocator, .{ .path = relative_path, .kind = .modified, .hash = hash, .previous_hash = previous_hash });
        }
    }

    var recorded = baseline.iterator();
    while (recorded.next()) |entry| {
        const relative_path = entry.key_ptr.*;
        if (current.get(relative_path) == null and !could_not_read.contains(relative_path)) {
            try changes.append(allocator, .{ .path = relative_path, .kind = .deleted, .hash = "", .previous_hash = entry.value_ptr.* });
        }
    }

    const sorted = try changes.toOwnedSlice(allocator);
    std.mem.sort(ChangedFile, sorted, {}, lessThanChange);
    return sorted;
}

//
// Renders the changed files as the lines the CLI prints: a one-letter kind, the short hash, and the
// path. A file with no current hash, deleted or unreadable, shows the hash it used to have.
//
pub fn formatChangedFiles(allocator: std.mem.Allocator, changes: []const ChangedFile) std.mem.Allocator.Error![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;

    for (changes) |change| {
        const shown_hash = if (change.hash.len == 0) change.previous_hash else change.hash;
        const short_hash = shown_hash[0..@min(16, shown_hash.len)];
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "  {c}  {s}  {s}", .{
            change.kind.marker(), short_hash, change.path,
        }));
    }

    return lines.toOwnedSlice(allocator);
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("changed_files.test.zig");
}
