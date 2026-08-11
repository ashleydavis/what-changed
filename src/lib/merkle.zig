const std = @import("std");
const file_hashes = @import("file_hashes.zig");

const FileHashes = file_hashes.FileHashes;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// Returned for a path that is not in the tree at all. A watched path that does not exist has to hash
// to something stable, so that creating the first file under it registers as a change.
//
pub const MISSING_PATH_HASH = "<missing>";

//
// One node in the hash tree. A file node carries its content hash and no children; a directory node
// carries a hash derived from its children.
//
pub const TreeNode = struct {
    //
    // The node's hash: a file's content hash, or a directory's hash over its entries.
    //
    hash: []const u8,

    //
    // The node's children by name. Empty for a file node.
    //
    children: std.StringArrayHashMapUnmanaged(*TreeNode),
};

//
// Builds a hash tree over a set of file hashes, so that one lookup answers "has anything under this
// directory changed" without walking the file list again.
//
pub fn buildTree(allocator: std.mem.Allocator, hashes: *const FileHashes) std.mem.Allocator.Error!*TreeNode {
    const root = try newNode(allocator, "");

    //
    // Sorted, so the tree is identical whatever order the files arrived in. The directory hashes
    // below sort their own entries anyway, but building in a fixed order keeps the whole thing
    // reproducible rather than only its digests.
    //
    for (try file_hashes.sortedKeys(allocator, hashes)) |relative_path| {
        const file_hash = hashes.get(relative_path).?;

        //
        // Empty segments are skipped, so a path written with a doubled or trailing slash lands in
        // the same place as the tidy spelling of itself.
        //
        var segment_count: usize = 0;
        var counter = std.mem.splitScalar(u8, relative_path, '/');
        while (counter.next()) |segment| {
            if (segment.len > 0) segment_count += 1;
        }
        if (segment_count == 0) continue;

        var node = root;
        var at: usize = 0;
        var walker = std.mem.splitScalar(u8, relative_path, '/');
        while (walker.next()) |segment| {
            if (segment.len == 0) continue;
            at += 1;

            if (at == segment_count) {
                //
                // The last segment is the file itself, and it takes the file's hash. Assigned
                // rather than merged: a path that used to be a directory and is now a file is a
                // file, and keeping the old children would leave the tree describing a tree that no
                // longer exists.
                //
                const leaf = try newNode(allocator, file_hash);
                try node.children.put(allocator, segment, leaf);
                break;
            }

            const existing = node.children.get(segment);
            if (existing) |child| {
                node = child;
            } else {
                const child = try newNode(allocator, "");
                try node.children.put(allocator, segment, child);
                node = child;
            }
        }
    }

    try computeDirectoryHash(allocator, root);
    return root;
}

//
// Makes a node with the given hash and no children.
//
fn newNode(allocator: std.mem.Allocator, hash: []const u8) std.mem.Allocator.Error!*TreeNode {
    const node = try allocator.create(TreeNode);
    node.* = .{ .hash = hash, .children = .empty };
    return node;
}

//
// Fills in the hash of a directory node and every directory below it, from the bottom up. Entries
// are sorted by name before hashing so the result does not depend on the order the files arrived in.
//
pub fn computeDirectoryHash(allocator: std.mem.Allocator, node: *TreeNode) std.mem.Allocator.Error!void {
    if (node.children.count() == 0) {
        return;
    }

    const names = try allocator.dupe([]const u8, node.children.keys());
    std.mem.sort([]const u8, names, {}, file_hashes.lessThanPath);

    var digest = Sha256.init(.{});
    for (names) |name| {
        const child = node.children.get(name).?;
        try computeDirectoryHash(allocator, child);
        digest.update(name);
        digest.update(&.{0});
        digest.update(child.hash);
        digest.update("\n");
    }

    var raw: [Sha256.digest_length]u8 = undefined;
    digest.final(&raw);

    const hex = try allocator.alloc(u8, raw.len * 2);
    @memcpy(hex, &std.fmt.bytesToHex(raw, .lower));
    node.hash = hex;
}

//
// Returns the hash recorded for a path, whether that path names a file or a directory. An empty path
// returns the root hash, which is the hash of the whole tree.
//
pub fn hashForPath(root: *const TreeNode, relative_path: []const u8) []const u8 {
    var node = root;

    var walker = std.mem.splitScalar(u8, relative_path, '/');
    while (walker.next()) |segment| {
        if (segment.len == 0) continue;
        const child = node.children.get(segment) orelse return MISSING_PATH_HASH;
        node = child;
    }

    return node.hash;
}

const testing = std.testing;

test "buildTree puts every file under its directories" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try file_hashes.fromPairs(allocator, &.{
        .{ "src/a.ts", "hash-a" },
        .{ "src/nested/b.ts", "hash-b" },
        .{ "package.json", "hash-p" },
    });

    const root = try buildTree(allocator, &hashes);

    try testing.expectEqual(@as(usize, 2), root.children.count());
    try testing.expectEqualStrings("hash-a", root.children.get("src").?.children.get("a.ts").?.hash);
    try testing.expectEqualStrings("hash-b", root.children.get("src").?.children.get("nested").?.children.get("b.ts").?.hash);
    try testing.expectEqualStrings("hash-p", root.children.get("package.json").?.hash);
}

test "buildTree of nothing has a root with no children and no hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes: FileHashes = .empty;
    const root = try buildTree(allocator, &hashes);

    try testing.expectEqual(@as(usize, 0), root.children.count());
    try testing.expectEqualStrings("", root.hash);
}

test "hashForPath finds files and directories, and reports what is missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try file_hashes.fromPairs(allocator, &.{ .{ "src/a.ts", "hash-a" } });
    const root = try buildTree(allocator, &hashes);

    try testing.expectEqualStrings("hash-a", hashForPath(root, "src/a.ts"));
    try testing.expectEqual(@as(usize, 64), hashForPath(root, "src").len);
    try testing.expectEqualStrings(MISSING_PATH_HASH, hashForPath(root, "nope"));
    try testing.expectEqualStrings(MISSING_PATH_HASH, hashForPath(root, "src/nope.ts"));
    try testing.expectEqualStrings(MISSING_PATH_HASH, hashForPath(root, "src/a.ts/deeper"));
}

test "hashForPath with an empty path gives the whole tree's hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try file_hashes.fromPairs(allocator, &.{ .{ "src/a.ts", "hash-a" } });
    const root = try buildTree(allocator, &hashes);

    try testing.expectEqualStrings(root.hash, hashForPath(root, ""));
    try testing.expectEqual(@as(usize, 64), root.hash.len);
}

test "hashForPath ignores empty segments in the path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try file_hashes.fromPairs(allocator, &.{ .{ "src/a.ts", "hash-a" } });
    const root = try buildTree(allocator, &hashes);

    try testing.expectEqualStrings("hash-a", hashForPath(root, "src//a.ts"));
    try testing.expectEqualStrings("hash-a", hashForPath(root, "/src/a.ts"));
}

test "the same files give the same hashes whatever order they went in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var forwards = try file_hashes.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "src/b.ts", "2" },
        .{ "docs/c.md", "3" },
    });
    var backwards = try file_hashes.fromPairs(allocator, &.{
        .{ "docs/c.md", "3" },
        .{ "src/b.ts", "2" },
        .{ "src/a.ts", "1" },
    });

    try testing.expectEqualStrings(
        (try buildTree(allocator, &forwards)).hash,
        (try buildTree(allocator, &backwards)).hash,
    );
}

test "changing one file changes its directory's hash and the root's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var before = try file_hashes.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "docs/c.md", "3" } });
    var after = try file_hashes.fromPairs(allocator, &.{ .{ "src/a.ts", "changed" }, .{ "docs/c.md", "3" } });

    const before_tree = try buildTree(allocator, &before);
    const after_tree = try buildTree(allocator, &after);

    try testing.expect(!std.mem.eql(u8, before_tree.hash, after_tree.hash));
    try testing.expect(!std.mem.eql(u8, hashForPath(before_tree, "src"), hashForPath(after_tree, "src")));

    //
    // And the directory that did not change keeps its hash, which is the whole point: a lookup
    // under "docs" answers "nothing here changed" without looking at any file.
    //
    try testing.expectEqualStrings(hashForPath(before_tree, "docs"), hashForPath(after_tree, "docs"));
}

test "adding a file changes the hash of the directory it lands in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var before = try file_hashes.fromPairs(allocator, &.{ .{ "src/a.ts", "1" } });
    var after = try file_hashes.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "src/b.ts", "2" } });

    try testing.expect(!std.mem.eql(
        u8,
        hashForPath(try buildTree(allocator, &before), "src"),
        hashForPath(try buildTree(allocator, &after), "src"),
    ));
}

test "a file's name is part of the hash, not just its content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var named_one = try file_hashes.fromPairs(allocator, &.{ .{ "src/a.ts", "same" } });
    var named_other = try file_hashes.fromPairs(allocator, &.{ .{ "src/b.ts", "same" } });

    try testing.expect(!std.mem.eql(
        u8,
        hashForPath(try buildTree(allocator, &named_one), "src"),
        hashForPath(try buildTree(allocator, &named_other), "src"),
    ));
}

test "computeDirectoryHash leaves a node with no children alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const leaf = try newNode(allocator, "file-hash");
    try computeDirectoryHash(allocator, leaf);
    try testing.expectEqualStrings("file-hash", leaf.hash);
}

test "a directory hash is a sha-256 hex digest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try file_hashes.fromPairs(allocator, &.{ .{ "src/a.ts", "1" } });
    const directory_hash = hashForPath(try buildTree(allocator, &hashes), "src");

    try testing.expectEqual(@as(usize, 64), directory_hash.len);
    for (directory_hash) |character| {
        try testing.expect(std.ascii.isHex(character) and !std.ascii.isUpper(character));
    }
}
