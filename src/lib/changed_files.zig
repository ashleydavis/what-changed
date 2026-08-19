const std = @import("std");
const value = @import("value.zig");
const file_hash = @import("file_hash.zig");
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

const testing = std.testing;

test "FileChangeKind renders its word and its letter" {
    try testing.expectEqualStrings("added", FileChangeKind.added.text());
    try testing.expectEqualStrings("modified", FileChangeKind.modified.text());
    try testing.expectEqualStrings("deleted", FileChangeKind.deleted.text());
    try testing.expectEqualStrings("unreadable", FileChangeKind.unreadable.text());

    try testing.expectEqual(@as(u8, 'A'), FileChangeKind.added.marker());
    try testing.expectEqual(@as(u8, 'M'), FileChangeKind.modified.marker());
    try testing.expectEqual(@as(u8, 'D'), FileChangeKind.deleted.marker());
    try testing.expectEqual(@as(u8, 'U'), FileChangeKind.unreadable.marker());
}

test "diffFileHashes reports a file the baseline has never seen as added" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{.{ "src/a.ts", "hash-a" }});
    var baseline: FileHashes = .empty;

    const changes = try diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings("src/a.ts", changes[0].path);
    try testing.expectEqual(FileChangeKind.added, changes[0].kind);
    try testing.expectEqualStrings("hash-a", changes[0].hash);
    try testing.expectEqualStrings("", changes[0].previous_hash);
}

test "diffFileHashes reports a file whose hash moved as modified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{.{ "src/a.ts", "new" }});
    var baseline = try file_hashes.fromPairs(allocator, &.{.{ "src/a.ts", "old" }});

    const changes = try diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(FileChangeKind.modified, changes[0].kind);
    try testing.expectEqualStrings("new", changes[0].hash);
    try testing.expectEqualStrings("old", changes[0].previous_hash);
}

test "diffFileHashes reports a file the baseline has but the tree does not as deleted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current: FileHashes = .empty;
    var baseline = try file_hashes.fromPairs(allocator, &.{.{ "src/gone.ts", "old" }});

    const changes = try diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(FileChangeKind.deleted, changes[0].kind);
    try testing.expectEqualStrings("", changes[0].hash);
    try testing.expectEqualStrings("old", changes[0].previous_hash);
}

test "diffFileHashes reports nothing when nothing moved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{ .{ "a.ts", "1" }, .{ "b.ts", "2" } });
    var baseline = try file_hashes.fromPairs(allocator, &.{ .{ "a.ts", "1" }, .{ "b.ts", "2" } });

    try testing.expectEqual(@as(usize, 0), (try diffFileHashes(allocator, &current, &baseline, &.{})).len);
}

test "diffFileHashes treats a file listed but not on disk as deleted, not modified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // A file that is gone never reaches the map, so "absent from current" is the whole signal.
    //
    var current: FileHashes = .empty;
    var baseline = try file_hashes.fromPairs(allocator, &.{.{ "src/gone.ts", "old" }});

    const changes = try diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(FileChangeKind.deleted, changes[0].kind);
}

test "diffFileHashes leaves a file that is neither on disk nor in the baseline out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current: FileHashes = .empty;
    var baseline: FileHashes = .empty;

    try testing.expectEqual(@as(usize, 0), (try diffFileHashes(allocator, &current, &baseline, &.{})).len);
}

test "diffFileHashes reports an unreadable file as unreadable rather than deleted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // The file is in the baseline and absent from the tree's hashes, which on its own reads as a
    // deletion. Naming it as unreadable is what stops it being reported as one.
    //
    var current: FileHashes = .empty;
    var baseline = try file_hashes.fromPairs(allocator, &.{.{ "src/locked.ts", "old" }});

    const changes = try diffFileHashes(allocator, &current, &baseline, &.{"src/locked.ts"});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(FileChangeKind.unreadable, changes[0].kind);
    try testing.expectEqualStrings("src/locked.ts", changes[0].path);
    try testing.expectEqualStrings("", changes[0].hash);
    try testing.expectEqualStrings("old", changes[0].previous_hash);
}

test "diffFileHashes reports an unreadable file the baseline never held" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current: FileHashes = .empty;
    var baseline: FileHashes = .empty;

    const changes = try diffFileHashes(allocator, &current, &baseline, &.{"src/locked.ts"});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(FileChangeKind.unreadable, changes[0].kind);
    try testing.expectEqualStrings("", changes[0].previous_hash);
}

test "diffFileHashes sorts the changes by path whatever order they came in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{
        .{ "z.ts", "1" },
        .{ "a.ts", "1" },
        .{ "m.ts", "changed" },
    });
    var baseline = try file_hashes.fromPairs(allocator, &.{
        .{ "m.ts", "old" },
        .{ "deleted.ts", "old" },
    });

    const changes = try diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 4), changes.len);
    try testing.expectEqualStrings("a.ts", changes[0].path);
    try testing.expectEqualStrings("deleted.ts", changes[1].path);
    try testing.expectEqualStrings("m.ts", changes[2].path);
    try testing.expectEqualStrings("z.ts", changes[3].path);
}

test "diffFileHashes reports every kind together" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{
        .{ "added.ts", "new" },
        .{ "same.ts", "1" },
        .{ "changed.ts", "new" },
    });
    var baseline = try file_hashes.fromPairs(allocator, &.{
        .{ "same.ts", "1" },
        .{ "changed.ts", "old" },
        .{ "gone.ts", "old" },
    });

    const changes = try diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expectEqualStrings("added.ts", changes[0].path);
    try testing.expectEqual(FileChangeKind.added, changes[0].kind);
    try testing.expectEqualStrings("changed.ts", changes[1].path);
    try testing.expectEqual(FileChangeKind.modified, changes[1].kind);
    try testing.expectEqualStrings("gone.ts", changes[2].path);
    try testing.expectEqual(FileChangeKind.deleted, changes[2].kind);
}

test "diffFileHashes still reports a deletion beside an unreadable file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current: FileHashes = .empty;
    var baseline = try file_hashes.fromPairs(allocator, &.{
        .{ "gone.ts", "old" },
        .{ "locked.ts", "old" },
    });

    const changes = try diffFileHashes(allocator, &current, &baseline, &.{"locked.ts"});
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("gone.ts", changes[0].path);
    try testing.expectEqual(FileChangeKind.deleted, changes[0].kind);
    try testing.expectEqualStrings("locked.ts", changes[1].path);
    try testing.expectEqual(FileChangeKind.unreadable, changes[1].kind);
}

test "formatChangedFiles renders a line per change with a short hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lines = try formatChangedFiles(allocator, &.{
        .{ .path = "src/a.ts", .kind = .added, .hash = "0123456789abcdef0123", .previous_hash = "" },
        .{ .path = "src/b.ts", .kind = .modified, .hash = "aaaabbbbccccddddeeee", .previous_hash = "old" },
        .{ .path = "src/c.ts", .kind = .deleted, .hash = "", .previous_hash = "ffffeeeeddddcccc1111" },
        .{ .path = "src/d.ts", .kind = .unreadable, .hash = "", .previous_hash = "1111222233334444aaaa" },
    });

    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("  A  0123456789abcdef  src/a.ts", lines[0]);
    try testing.expectEqualStrings("  M  aaaabbbbccccdddd  src/b.ts", lines[1]);
    //
    // A deleted file shows the hash it used to have. There is no current one, and printing an empty
    // column would leave the reader unable to tell which version went away.
    //
    try testing.expectEqualStrings("  D  ffffeeeeddddcccc  src/c.ts", lines[2]);

    //
    // Same for an unreadable one: the last hash anyone managed to compute is the only one there is.
    //
    try testing.expectEqualStrings("  U  1111222233334444  src/d.ts", lines[3]);
}

test "formatChangedFiles copes with a hash shorter than the short form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lines = try formatChangedFiles(allocator, &.{
        .{ .path = "a.ts", .kind = .modified, .hash = "abc", .previous_hash = "old" },
    });
    try testing.expectEqualStrings("  M  abc  a.ts", lines[0]);
}

test "formatChangedFiles of nothing is nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try formatChangedFiles(allocator, &.{})).len);
}

test "toValue renders a change with the field names a script reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const change = ChangedFile{ .path = "src/a.ts", .kind = .modified, .hash = "new", .previous_hash = "old" };
    const rendered = try change.toValue(allocator);

    try testing.expectEqualStrings("path", rendered.object.keys()[0]);
    try testing.expectEqualStrings("kind", rendered.object.keys()[1]);
    try testing.expectEqualStrings("hash", rendered.object.keys()[2]);
    try testing.expectEqualStrings("previousHash", rendered.object.keys()[3]);
    try testing.expectEqualStrings("modified", value.get(rendered, "kind").?.string);
    try testing.expectEqualStrings("old", value.get(rendered, "previousHash").?.string);
}

test "toValueArray renders every change, and nothing as an empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rendered = try toValueArray(allocator, &.{
        .{ .path = "a.ts", .kind = .added, .hash = "1", .previous_hash = "" },
        .{ .path = "b.ts", .kind = .deleted, .hash = "", .previous_hash = "2" },
    });
    try testing.expectEqual(@as(usize, 2), rendered.array.items.len);
    try testing.expectEqualStrings("b.ts", value.get(rendered.array.items[1], "path").?.string);

    try testing.expectEqual(@as(usize, 0), (try toValueArray(allocator, &.{})).array.items.len);
}
