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
    // The file's current content hash, or an empty string for a deleted file.
    //
    hash: []const u8,

    //
    // The file's content hash in the baseline, or an empty string for an added file.
    //
    previous_hash: []const u8,

    //
    // Renders this change as the object the machine-readable formats print. The field names are the
    // TypeScript's, so a script reading either port's JSON sees the same keys.
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
pub fn diffFileHashes(allocator: std.mem.Allocator, current: *const FileHashes, baseline: *const FileHashes) std.mem.Allocator.Error![]ChangedFile {
    var changes: std.ArrayList(ChangedFile) = .empty;

    var present = try presentFiles(allocator, current);

    var walker = present.iterator();
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
        if (present.get(relative_path) == null) {
            try changes.append(allocator, .{ .path = relative_path, .kind = .deleted, .hash = "", .previous_hash = entry.value_ptr.* });
        }
    }

    const sorted = try changes.toOwnedSlice(allocator);
    std.mem.sort(ChangedFile, sorted, {}, lessThanChange);
    return sorted;
}

//
// Drops the files that are listed but not actually on disk. git lists a tracked file even after it
// has been deleted from the working tree, and such a file hashes to MISSING_FILE_HASH. Treating it
// as present would report a deletion as a modification to the literal text "<missing>".
//
pub fn presentFiles(allocator: std.mem.Allocator, current: *const FileHashes) std.mem.Allocator.Error!FileHashes {
    var present: FileHashes = .empty;

    var walker = current.iterator();
    while (walker.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.*, file_hash.MISSING_FILE_HASH)) {
            try present.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return present;
}

//
// Turns a map of path to hash into what is stored as the baseline, leaving out any file that is not
// actually on disk so the baseline only ever holds real content hashes.
//
pub fn toFileHashes(allocator: std.mem.Allocator, current: *const FileHashes) std.mem.Allocator.Error!FileHashes {
    return presentFiles(allocator, current);
}

//
// Renders the changed files as the lines the CLI prints: a one-letter kind, the short hash, and the
// path. A deleted file shows the hash it used to have, since there is no current one.
//
pub fn formatChangedFiles(allocator: std.mem.Allocator, changes: []const ChangedFile) std.mem.Allocator.Error![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;

    for (changes) |change| {
        const shown_hash = if (change.kind == .deleted) change.previous_hash else change.hash;
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

    try testing.expectEqual(@as(u8, 'A'), FileChangeKind.added.marker());
    try testing.expectEqual(@as(u8, 'M'), FileChangeKind.modified.marker());
    try testing.expectEqual(@as(u8, 'D'), FileChangeKind.deleted.marker());
}

test "diffFileHashes reports a file the baseline has never seen as added" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{.{ "src/a.ts", "hash-a" }});
    var baseline: FileHashes = .empty;

    const changes = try diffFileHashes(allocator, &current, &baseline);
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

    const changes = try diffFileHashes(allocator, &current, &baseline);
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

    const changes = try diffFileHashes(allocator, &current, &baseline);
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

    try testing.expectEqual(@as(usize, 0), (try diffFileHashes(allocator, &current, &baseline)).len);
}

test "diffFileHashes treats a file listed but not on disk as deleted, not modified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{.{ "src/gone.ts", file_hash.MISSING_FILE_HASH }});
    var baseline = try file_hashes.fromPairs(allocator, &.{.{ "src/gone.ts", "old" }});

    const changes = try diffFileHashes(allocator, &current, &baseline);
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(FileChangeKind.deleted, changes[0].kind);
}

test "diffFileHashes leaves a file that is neither on disk nor in the baseline out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{.{ "src/never.ts", file_hash.MISSING_FILE_HASH }});
    var baseline: FileHashes = .empty;

    try testing.expectEqual(@as(usize, 0), (try diffFileHashes(allocator, &current, &baseline)).len);
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

    const changes = try diffFileHashes(allocator, &current, &baseline);
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

    const changes = try diffFileHashes(allocator, &current, &baseline);
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expectEqualStrings("added.ts", changes[0].path);
    try testing.expectEqual(FileChangeKind.added, changes[0].kind);
    try testing.expectEqualStrings("changed.ts", changes[1].path);
    try testing.expectEqual(FileChangeKind.modified, changes[1].kind);
    try testing.expectEqualStrings("gone.ts", changes[2].path);
    try testing.expectEqual(FileChangeKind.deleted, changes[2].kind);
}

test "presentFiles drops the files that are not on disk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{
        .{ "here.ts", "hash" },
        .{ "gone.ts", file_hash.MISSING_FILE_HASH },
    });

    var present = try presentFiles(allocator, &current);
    try testing.expectEqual(@as(usize, 1), present.count());
    try testing.expect(present.get("gone.ts") == null);
    try testing.expectEqualStrings("hash", present.get("here.ts").?);
}

test "toFileHashes keeps only the files that are really there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes.fromPairs(allocator, &.{
        .{ "here.ts", "hash" },
        .{ "gone.ts", file_hash.MISSING_FILE_HASH },
    });

    var stored = try toFileHashes(allocator, &current);
    try testing.expectEqual(@as(usize, 1), stored.count());
    try testing.expectEqualStrings("hash", stored.get("here.ts").?);
}

test "formatChangedFiles renders a line per change with a short hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lines = try formatChangedFiles(allocator, &.{
        .{ .path = "src/a.ts", .kind = .added, .hash = "0123456789abcdef0123", .previous_hash = "" },
        .{ .path = "src/b.ts", .kind = .modified, .hash = "aaaabbbbccccddddeeee", .previous_hash = "old" },
        .{ .path = "src/c.ts", .kind = .deleted, .hash = "", .previous_hash = "ffffeeeeddddcccc1111" },
    });

    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("  A  0123456789abcdef  src/a.ts", lines[0]);
    try testing.expectEqualStrings("  M  aaaabbbbccccdddd  src/b.ts", lines[1]);
    //
    // A deleted file shows the hash it used to have. There is no current one, and printing an empty
    // column would leave the reader unable to tell which version went away.
    //
    try testing.expectEqualStrings("  D  ffffeeeeddddcccc  src/c.ts", lines[2]);
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

test "toValue renders a change with the TypeScript's field names" {
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
