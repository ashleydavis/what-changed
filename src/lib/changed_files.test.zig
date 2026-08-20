const std = @import("std");
const value = @import("value.zig");
const file_hashes = @import("file_hashes.zig");
const changed_files = @import("changed_files.zig");
const file_hashes_test = @import("file_hashes.test.zig");
const FileHashes = file_hashes.FileHashes;
const testing = std.testing;

test "FileChangeKind renders its word and its letter" {
    try testing.expectEqualStrings("added", changed_files.FileChangeKind.added.text());
    try testing.expectEqualStrings("modified", changed_files.FileChangeKind.modified.text());
    try testing.expectEqualStrings("deleted", changed_files.FileChangeKind.deleted.text());
    try testing.expectEqualStrings("unreadable", changed_files.FileChangeKind.unreadable.text());

    try testing.expectEqual(@as(u8, 'A'), changed_files.FileChangeKind.added.marker());
    try testing.expectEqual(@as(u8, 'M'), changed_files.FileChangeKind.modified.marker());
    try testing.expectEqual(@as(u8, 'D'), changed_files.FileChangeKind.deleted.marker());
    try testing.expectEqual(@as(u8, 'U'), changed_files.FileChangeKind.unreadable.marker());
}

test "diffFileHashes reports a file the baseline has never seen as added" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "hash-a" }});
    var baseline: FileHashes = .empty;

    const changes = try changed_files.diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings("src/a.ts", changes[0].path);
    try testing.expectEqual(changed_files.FileChangeKind.added, changes[0].kind);
    try testing.expectEqualStrings("hash-a", changes[0].hash);
    try testing.expectEqualStrings("", changes[0].previous_hash);
}

test "diffFileHashes reports a file whose hash moved as modified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "new" }});
    var baseline = try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "old" }});

    const changes = try changed_files.diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(changed_files.FileChangeKind.modified, changes[0].kind);
    try testing.expectEqualStrings("new", changes[0].hash);
    try testing.expectEqualStrings("old", changes[0].previous_hash);
}

test "diffFileHashes reports a file the baseline has but the tree does not as deleted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current: FileHashes = .empty;
    var baseline = try file_hashes_test.fromPairs(allocator, &.{.{ "src/gone.ts", "old" }});

    const changes = try changed_files.diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(changed_files.FileChangeKind.deleted, changes[0].kind);
    try testing.expectEqualStrings("", changes[0].hash);
    try testing.expectEqualStrings("old", changes[0].previous_hash);
}

test "diffFileHashes reports nothing when nothing moved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes_test.fromPairs(allocator, &.{ .{ "a.ts", "1" }, .{ "b.ts", "2" } });
    var baseline = try file_hashes_test.fromPairs(allocator, &.{ .{ "a.ts", "1" }, .{ "b.ts", "2" } });

    try testing.expectEqual(@as(usize, 0), (try changed_files.diffFileHashes(allocator, &current, &baseline, &.{})).len);
}

test "diffFileHashes treats a file listed but not on disk as deleted, not modified" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // A file that is gone never reaches the map, so "absent from current" is the whole signal.
    //
    var current: FileHashes = .empty;
    var baseline = try file_hashes_test.fromPairs(allocator, &.{.{ "src/gone.ts", "old" }});

    const changes = try changed_files.diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(changed_files.FileChangeKind.deleted, changes[0].kind);
}

test "diffFileHashes leaves a file that is neither on disk nor in the baseline out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current: FileHashes = .empty;
    var baseline: FileHashes = .empty;

    try testing.expectEqual(@as(usize, 0), (try changed_files.diffFileHashes(allocator, &current, &baseline, &.{})).len);
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
    var baseline = try file_hashes_test.fromPairs(allocator, &.{.{ "src/locked.ts", "old" }});

    const changes = try changed_files.diffFileHashes(allocator, &current, &baseline, &.{"src/locked.ts"});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(changed_files.FileChangeKind.unreadable, changes[0].kind);
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

    const changes = try changed_files.diffFileHashes(allocator, &current, &baseline, &.{"src/locked.ts"});
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(changed_files.FileChangeKind.unreadable, changes[0].kind);
    try testing.expectEqualStrings("", changes[0].previous_hash);
}

test "diffFileHashes sorts the changes by path whatever order they came in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current = try file_hashes_test.fromPairs(allocator, &.{
        .{ "z.ts", "1" },
        .{ "a.ts", "1" },
        .{ "m.ts", "changed" },
    });
    var baseline = try file_hashes_test.fromPairs(allocator, &.{
        .{ "m.ts", "old" },
        .{ "deleted.ts", "old" },
    });

    const changes = try changed_files.diffFileHashes(allocator, &current, &baseline, &.{});
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

    var current = try file_hashes_test.fromPairs(allocator, &.{
        .{ "added.ts", "new" },
        .{ "same.ts", "1" },
        .{ "changed.ts", "new" },
    });
    var baseline = try file_hashes_test.fromPairs(allocator, &.{
        .{ "same.ts", "1" },
        .{ "changed.ts", "old" },
        .{ "gone.ts", "old" },
    });

    const changes = try changed_files.diffFileHashes(allocator, &current, &baseline, &.{});
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expectEqualStrings("added.ts", changes[0].path);
    try testing.expectEqual(changed_files.FileChangeKind.added, changes[0].kind);
    try testing.expectEqualStrings("changed.ts", changes[1].path);
    try testing.expectEqual(changed_files.FileChangeKind.modified, changes[1].kind);
    try testing.expectEqualStrings("gone.ts", changes[2].path);
    try testing.expectEqual(changed_files.FileChangeKind.deleted, changes[2].kind);
}

test "diffFileHashes still reports a deletion beside an unreadable file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var current: FileHashes = .empty;
    var baseline = try file_hashes_test.fromPairs(allocator, &.{
        .{ "gone.ts", "old" },
        .{ "locked.ts", "old" },
    });

    const changes = try changed_files.diffFileHashes(allocator, &current, &baseline, &.{"locked.ts"});
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("gone.ts", changes[0].path);
    try testing.expectEqual(changed_files.FileChangeKind.deleted, changes[0].kind);
    try testing.expectEqualStrings("locked.ts", changes[1].path);
    try testing.expectEqual(changed_files.FileChangeKind.unreadable, changes[1].kind);
}

test "formatChangedFiles renders a line per change with a short hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const lines = try changed_files.formatChangedFiles(allocator, &.{
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

    const lines = try changed_files.formatChangedFiles(allocator, &.{
        .{ .path = "a.ts", .kind = .modified, .hash = "abc", .previous_hash = "old" },
    });
    try testing.expectEqualStrings("  M  abc  a.ts", lines[0]);
}

test "formatChangedFiles of nothing is nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try changed_files.formatChangedFiles(allocator, &.{})).len);
}

test "toValue renders a change with the field names a script reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const change = changed_files.ChangedFile{ .path = "src/a.ts", .kind = .modified, .hash = "new", .previous_hash = "old" };
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

    const rendered = try changed_files.toValueArray(allocator, &.{
        .{ .path = "a.ts", .kind = .added, .hash = "1", .previous_hash = "" },
        .{ .path = "b.ts", .kind = .deleted, .hash = "", .previous_hash = "2" },
    });
    try testing.expectEqual(@as(usize, 2), rendered.array.items.len);
    try testing.expectEqualStrings("b.ts", value.get(rendered.array.items[1], "path").?.string);

    try testing.expectEqual(@as(usize, 0), (try changed_files.toValueArray(allocator, &.{})).array.items.len);
}
