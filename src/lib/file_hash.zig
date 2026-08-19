const std = @import("std");
const files = @import("files.zig");
const value = @import("value.zig");
const file_hashes = @import("file_hashes.zig");

const FileHashes = file_hashes.FileHashes;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// How much of a file is read at a time when hashing it.
//
// The whole file is never held in memory: hashing is a streaming operation, so a 64KB window is all
// it needs whatever the file's size. That also means a huge file in the tree costs time and not
// memory, which is the difference between a slow run and a failed one.
//
const READ_BUFFER_BYTES = 64 * 1024;

//
// What is remembered about one file so it does not have to be read again.
//
pub const FileHashEntry = struct {
    //
    // The file's modification time in milliseconds when the hash was computed.
    //
    mtime_ms: f64,

    //
    // The file's size in bytes when the hash was computed.
    //
    size: u64,

    //
    // The SHA-256 hex digest of the file's content.
    //
    hash: []const u8,
};

//
// Maps a repository-relative path to what was last known about that file. Paths are relative so the
// cache stays valid when the checkout moves.
//
pub const FileHashCache = std.StringArrayHashMapUnmanaged(FileHashEntry);

//
// What came of hashing one file.
//
// Three outcomes rather than a digest with a stand-in value for the other two. A file that is gone
// and a file that is there but locked are different things and the tool says different things about
// them, so they are different values here rather than one placeholder both callers have to recognise
// by comparing against a magic string.
//
pub const HashedFile = union(enum) {
    //
    // The SHA-256 hex digest of the file's content.
    //
    hashed: []const u8,

    //
    // The file was listed but is no longer on disk.
    //
    // Normal, not an error: the listing and the hashing are two passes over a live working tree, and
    // git lists a tracked file until the deletion is staged. It is reported as a deletion.
    //
    gone,

    //
    // The file is on disk and something stopped it being read, with the error that stopped it.
    //
    // Kept apart from `gone` because the two need opposite responses: a deletion is finished with,
    // and this will happen again on every run until somebody fixes it.
    //
    unreadable: anyerror,
};

//
// Hashes one file's content, reading it only when the cached entry no longer matches the file's
// modification time and size.
//
pub fn hashFile(io: std.Io, allocator: std.mem.Allocator, root_dir: []const u8, relative_path: []const u8, cache: *FileHashCache) std.mem.Allocator.Error!HashedFile {
    const full_path = try files.joinPath(allocator, &.{ root_dir, relative_path });

    const stat = files.statFile(io, full_path) catch |err| return whyNot(err);

    if (cache.get(relative_path)) |cached| {
        if (cached.mtime_ms == stat.mtime_ms and cached.size == stat.size) {
            return .{ .hashed = cached.hash };
        }
    }

    const hash = hashFileContent(io, allocator, full_path) catch |err| return whyNot(err);

    //
    // The key is copied because the cache outlives the file list it came from when the caller reuses
    // one cache across several listings.
    //
    try cache.put(allocator, try allocator.dupe(u8, relative_path), .{
        .mtime_ms = stat.mtime_ms,
        .size = stat.size,
        .hash = hash,
    });
    return .{ .hashed = hash };
}

//
// Sorts an error that stopped a file being hashed into the file having gone or the file being
// unreadable.
//
// FileNotFound is the only one that means the file is not there. Everything else, a permission
// problem above all, means the entry is still in the tree and something stopped this process reading
// it, which is worth saying out loud rather than passing off as a deletion.
//
fn whyNot(err: anyerror) HashedFile {
    return if (err == error.FileNotFound) .gone else .{ .unreadable = err };
}

//
// Reads a file and returns the SHA-256 hex digest of its content.
//
pub fn hashFileContent(io: std.Io, allocator: std.mem.Allocator, full_path: []const u8) ![]const u8 {
    const file = try files.openFile(io, full_path);
    defer files.closeFile(io, file);

    var digest = Sha256.init(.{});

    //
    // Two buffers, not one. The reader keeps the first as its own storage, so reading into it as
    // well would have it overwrite what it is in the middle of handing back.
    //
    var reader_buffer: [READ_BUFFER_BYTES]u8 = undefined;
    var chunk: [READ_BUFFER_BYTES]u8 = undefined;
    var reader = files.fileReader(io, file, &reader_buffer);
    while (true) {
        const read = reader.interface.readSliceShort(&chunk) catch break;
        if (read == 0) break;
        digest.update(chunk[0..read]);
    }

    var raw: [Sha256.digest_length]u8 = undefined;
    digest.final(&raw);

    const hex = try allocator.alloc(u8, raw.len * 2);
    @memcpy(hex, &std.fmt.bytesToHex(raw, .lower));
    return hex;
}

//
// What came of hashing a whole set of files.
//
pub const HashedFiles = struct {
    //
    // Every file that was hashed, and its digest, in the order the paths were given.
    //
    // Only files that were actually read. A file that is gone or unreadable is not in here at all,
    // which is what keeps this map holding nothing but real content hashes: everything downstream can
    // compare these values without first checking whether one of them is standing in for something
    // else.
    //
    hashes: FileHashes,

    //
    // The files that are on disk and could not be read, in the order they were hashed.
    //
    // Named rather than counted, because the only useful thing to do about one is go and look at it.
    // The files that were simply gone are not listed: they are absent from `hashes`, which is all the
    // comparison needs to report them as deletions.
    //
    unreadable: [][]const u8,
};

//
// Hashes every requested file, sharing one cache across the whole set. Sequential on purpose: in the
// steady state this is one stat per file, so there is no throughput to win and no file-descriptor
// ceiling to reason about.
//
pub fn hashFiles(io: std.Io, allocator: std.mem.Allocator, root_dir: []const u8, relative_paths: []const []const u8, cache: *FileHashCache) std.mem.Allocator.Error!HashedFiles {
    var hashes: FileHashes = .empty;
    try hashes.ensureTotalCapacity(allocator, relative_paths.len);

    var unreadable: std.ArrayList([]const u8) = .empty;

    for (relative_paths) |relative_path| {
        switch (try hashFile(io, allocator, root_dir, relative_path, cache)) {
            .hashed => |hash| try hashes.put(allocator, relative_path, hash),
            .gone => {},
            .unreadable => try unreadable.append(allocator, relative_path),
        }
    }

    return .{ .hashes = hashes, .unreadable = try unreadable.toOwnedSlice(allocator) };
}

//
// Turns the cache into the JSON object it is stored as, with the paths in sorted order.
//
pub fn cacheToValue(allocator: std.mem.Allocator, cache: *const FileHashCache) std.mem.Allocator.Error!value.Value {
    const keys = try allocator.dupe([]const u8, cache.keys());
    std.mem.sort([]const u8, keys, {}, file_hashes.lessThanPath);

    var object = value.newObject(allocator);
    for (keys) |path| {
        const entry = cache.get(path).?;
        var record = value.newObject(allocator);
        try record.put(allocator, "mtimeMs", .{ .float = entry.mtime_ms });
        try record.put(allocator, "size", value.int(@intCast(entry.size)));
        try record.put(allocator, "hash", value.str(entry.hash));
        try object.put(allocator, path, .{ .object = record });
    }

    return .{ .object = object };
}

//
// Reads the cache back from the JSON object it is stored as.
//
// Any entry that is not a complete record is dropped rather than refused. A damaged cache should
// cost one slow run, never a blocked one, which is the whole reason it is kept apart from the
// baseline.
//
pub fn cacheFromValue(allocator: std.mem.Allocator, parsed: value.Value) std.mem.Allocator.Error!FileHashCache {
    var cache: FileHashCache = .empty;

    const object = switch (parsed) {
        .object => |object| object,
        else => return cache,
    };

    var walker = object.iterator();
    while (walker.next()) |entry| {
        const record = entry.value_ptr.*;
        if (record != .object) continue;

        const mtime_ms = switch (value.get(record, "mtimeMs") orelse continue) {
            .float => |number| number,
            .integer => |whole| @as(f64, @floatFromInt(whole)),
            else => continue,
        };
        const size = switch (value.get(record, "size") orelse continue) {
            .integer => |whole| if (whole < 0) continue else @as(u64, @intCast(whole)),
            .float => |number| if (number < 0) continue else @as(u64, @intFromFloat(number)),
            else => continue,
        };
        const hash = switch (value.get(record, "hash") orelse continue) {
            .string => |text| text,
            else => continue,
        };

        try cache.put(allocator, entry.key_ptr.*, .{ .mtime_ms = mtime_ms, .size = size, .hash = hash });
    }

    return cache;
}

const testing = std.testing;

//
// The SHA-256 of "hello\n", which is what `echo hello | sha256sum` gives. A known-good value, so
// these tests check the digest is right rather than only that it is consistent with itself.
//
const HELLO_LINE_SHA256 = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03";

test "hashFile hashes a file's content" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("src/a.ts", "hello\n");

    var cache: FileHashCache = .empty;
    try testing.expectEqualStrings(HELLO_LINE_SHA256, (try hashFile(io, allocator, temporary.path, "src/a.ts", &cache)).hashed);
}

test "hashFile records what it hashed in the cache" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("a.ts", "hello\n");

    var cache: FileHashCache = .empty;
    _ = (try hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed;

    const entry = cache.get("a.ts").?;
    try testing.expectEqualStrings(HELLO_LINE_SHA256, entry.hash);
    try testing.expectEqual(@as(u64, 6), entry.size);
    try testing.expect(entry.mtime_ms > 0);
}

test "hashFile answers from the cache when the file has not moved" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("a.ts", "hello\n");

    var cache: FileHashCache = .empty;
    _ = (try hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed;

    //
    // The cached hash is replaced with a value the file's content could never produce. Getting it
    // back proves the file was not read, which is what makes a warm run fast.
    //
    const stat = try files.statFile(io, try temporary.join(allocator, "a.ts"));
    try cache.put(allocator, "a.ts", .{ .mtime_ms = stat.mtime_ms, .size = stat.size, .hash = "from-the-cache" });

    try testing.expectEqualStrings("from-the-cache", (try hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed);
}

test "hashFile reads the file again when the size no longer matches" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("a.ts", "hello\n");

    const stat = try files.statFile(io, try temporary.join(allocator, "a.ts"));
    var cache: FileHashCache = .empty;
    try cache.put(allocator, "a.ts", .{ .mtime_ms = stat.mtime_ms, .size = stat.size + 1, .hash = "stale" });

    try testing.expectEqualStrings(HELLO_LINE_SHA256, (try hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed);
}

test "hashFile reads the file again when the modification time no longer matches" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("a.ts", "hello\n");

    const stat = try files.statFile(io, try temporary.join(allocator, "a.ts"));
    var cache: FileHashCache = .empty;
    try cache.put(allocator, "a.ts", .{ .mtime_ms = stat.mtime_ms - 1000, .size = stat.size, .hash = "stale" });

    try testing.expectEqualStrings(HELLO_LINE_SHA256, (try hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed);
}

test "hashFile reports a file that is not there as missing" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    var cache: FileHashCache = .empty;
    try testing.expectEqual(HashedFile.gone, try hashFile(io, allocator, temporary.path, "gone.ts", &cache));
    try testing.expect(cache.get("gone.ts") == null);
}

test "hashFile gives different content different hashes" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("a.ts", "one");
    try temporary.write("b.ts", "two");

    var cache: FileHashCache = .empty;
    const first = (try hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed;
    const second = (try hashFile(io, allocator, temporary.path, "b.ts", &cache)).hashed;
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "hashFile hashes a file larger than one read buffer" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    const big = try allocator.alloc(u8, READ_BUFFER_BYTES * 2 + 17);
    @memset(big, 'x');
    try temporary.write("big.bin", big);

    var cache: FileHashCache = .empty;
    const hash = (try hashFile(io, allocator, temporary.path, "big.bin", &cache)).hashed;

    //
    // Hashed in one go for comparison, so the streaming read is checked against a single-shot
    // digest of the same bytes rather than only against itself.
    //
    var raw: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(big, &raw, .{});
    try testing.expectEqualStrings(&std.fmt.bytesToHex(raw, .lower), hash);
}

test "hashFiles hashes every path and keeps them in the order given" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("b.ts", "two");
    try temporary.write("a.ts", "one");

    var cache: FileHashCache = .empty;
    var hashed = try hashFiles(io, allocator, temporary.path, &.{ "b.ts", "a.ts" }, &cache);

    try testing.expectEqual(@as(usize, 2), hashed.hashes.count());
    try testing.expectEqualStrings("b.ts", hashed.hashes.keys()[0]);
    try testing.expectEqualStrings("a.ts", hashed.hashes.keys()[1]);
    try testing.expectEqual(@as(usize, 64), hashed.hashes.get("a.ts").?.len);
    try testing.expectEqual(@as(usize, 0), hashed.unreadable.len);
}

test "hashFiles leaves a missing file out of the hashes and does not call it unreadable" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("here.ts", "x");

    var hashed_cache: FileHashCache = .empty;
    var hashed = try hashFiles(io, allocator, temporary.path, &.{ "here.ts", "gone.ts" }, &hashed_cache);

    //
    // The map holds real digests and nothing else, so a file that is not there is simply absent.
    // That absence is what the comparison reads as a deletion.
    //
    try testing.expectEqual(@as(usize, 1), hashed.hashes.count());
    try testing.expect(hashed.hashes.get("gone.ts") == null);
    try testing.expectEqual(@as(usize, 0), hashed.unreadable.len);
}

test "hashFiles with nothing to hash gives nothing" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cache: FileHashCache = .empty;
    var hashed = try hashFiles(io, allocator, "/nowhere", &.{}, &cache);
    try testing.expectEqual(@as(usize, 0), hashed.hashes.count());
    try testing.expectEqual(@as(usize, 0), hashed.unreadable.len);
}

test "cacheToValue writes each entry as a record, sorted by path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cache: FileHashCache = .empty;
    try cache.put(allocator, "z.ts", .{ .mtime_ms = 2.5, .size = 20, .hash = "hash-z" });
    try cache.put(allocator, "a.ts", .{ .mtime_ms = 1.5, .size = 10, .hash = "hash-a" });

    const rendered = try cacheToValue(allocator, &cache);
    try testing.expectEqualStrings("a.ts", rendered.object.keys()[0]);

    const record = value.get(rendered, "a.ts").?;
    try testing.expectEqual(@as(f64, 1.5), value.get(record, "mtimeMs").?.float);
    try testing.expectEqual(@as(i64, 10), value.get(record, "size").?.integer);
    try testing.expectEqualStrings("hash-a", value.get(record, "hash").?.string);
}

test "cacheFromValue reads records back" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var record = value.newObject(allocator);
    try record.put(allocator, "mtimeMs", .{ .float = 1.5 });
    try record.put(allocator, "size", value.int(10));
    try record.put(allocator, "hash", value.str("hash-a"));

    var object = value.newObject(allocator);
    try object.put(allocator, "a.ts", .{ .object = record });

    var cache = try cacheFromValue(allocator, .{ .object = object });
    const entry = cache.get("a.ts").?;
    try testing.expectEqual(@as(f64, 1.5), entry.mtime_ms);
    try testing.expectEqual(@as(u64, 10), entry.size);
    try testing.expectEqualStrings("hash-a", entry.hash);
}

test "cacheFromValue drops records that are incomplete or the wrong type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var missing_hash = value.newObject(allocator);
    try missing_hash.put(allocator, "mtimeMs", .{ .float = 1 });
    try missing_hash.put(allocator, "size", value.int(1));

    var wrong_type = value.newObject(allocator);
    try wrong_type.put(allocator, "mtimeMs", value.str("soon"));
    try wrong_type.put(allocator, "size", value.int(1));
    try wrong_type.put(allocator, "hash", value.str("h"));

    var good = value.newObject(allocator);
    try good.put(allocator, "mtimeMs", value.int(3));
    try good.put(allocator, "size", value.int(1));
    try good.put(allocator, "hash", value.str("h"));

    var object = value.newObject(allocator);
    try object.put(allocator, "missing.ts", .{ .object = missing_hash });
    try object.put(allocator, "wrong.ts", .{ .object = wrong_type });
    try object.put(allocator, "scalar.ts", value.str("nope"));
    try object.put(allocator, "good.ts", .{ .object = good });

    var cache = try cacheFromValue(allocator, .{ .object = object });
    try testing.expectEqual(@as(usize, 1), cache.count());
    try testing.expectEqual(@as(f64, 3), cache.get("good.ts").?.mtime_ms);
}

test "cacheFromValue of anything that is not an object is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try cacheFromValue(allocator, .null)).count());
    try testing.expectEqual(@as(usize, 0), (try cacheFromValue(allocator, .{ .array = value.newArray(allocator) })).count());
}

test "a cache survives a round trip through a value, mtime and all" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("a.ts", "hello\n");

    var cache: FileHashCache = .empty;
    _ = (try hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed;

    var round_tripped = try cacheFromValue(allocator, try cacheToValue(allocator, &cache));

    //
    // The modification time has to survive exactly. Losing the fraction of a millisecond would make
    // every cached entry look stale on the next run, which would quietly turn every warm run cold.
    //
    try testing.expectEqual(cache.get("a.ts").?.mtime_ms, round_tripped.get("a.ts").?.mtime_ms);
    try testing.expectEqualStrings(cache.get("a.ts").?.hash, round_tripped.get("a.ts").?.hash);

    //
    // And a cache read back off disk still answers without touching the file. The recognisable hash
    // is what proves it: the file's real content could not produce it.
    //
    const reloaded = round_tripped.get("a.ts").?;
    try round_tripped.put(allocator, "a.ts", .{
        .mtime_ms = reloaded.mtime_ms,
        .size = reloaded.size,
        .hash = "from-a-round-trip",
    });
    try testing.expectEqualStrings("from-a-round-trip", (try hashFile(io, allocator, temporary.path, "a.ts", &round_tripped)).hashed);
}

test "hashFileContent digests a file, whatever the cache says" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("a.ts", "hello\n");

    //
    // Unlike hashFile, this always reads. It is the half that does the work, and it is checked here
    // against a digest computed elsewhere rather than only against itself.
    //
    try testing.expectEqualStrings(HELLO_LINE_SHA256, try hashFileContent(io, allocator, try temporary.join(allocator, "a.ts")));
}

test "hashFileContent digests an empty file" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("empty.ts", "");

    //
    // The SHA-256 of nothing at all, which is a real digest and not a special case.
    //
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        try hashFileContent(io, allocator, try temporary.join(allocator, "empty.ts")),
    );
}

test "hashFileContent reports a file that is not there rather than returning a digest" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    //
    // hashFile turns this into `.gone`; this one is the raw operation and returns the error.
    //
    try testing.expectError(error.FileNotFound, hashFileContent(io, allocator, try temporary.join(allocator, "gone.ts")));
}
