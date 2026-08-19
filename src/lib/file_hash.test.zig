const std = @import("std");
const files = @import("files.zig");
const value = @import("value.zig");
const file_hash = @import("file_hash.zig");

const FileHashCache = file_hash.FileHashCache;
const HashedFile = file_hash.HashedFile;
const Sha256 = std.crypto.hash.sha2.Sha256;
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
    try testing.expectEqualStrings(HELLO_LINE_SHA256, (try file_hash.hashFile(io, allocator, temporary.path, "src/a.ts", &cache)).hashed);
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
    _ = (try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed;

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
    _ = (try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed;

    //
    // The cached hash is replaced with a value the file's content could never produce. Getting it
    // back proves the file was not read, which is what makes a warm run fast.
    //
    const stat = try files.statFile(io, try temporary.join(allocator, "a.ts"));
    try cache.put(allocator, "a.ts", .{ .mtime_ms = stat.mtime_ms, .size = stat.size, .hash = "from-the-cache" });

    try testing.expectEqualStrings("from-the-cache", (try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed);
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

    try testing.expectEqualStrings(HELLO_LINE_SHA256, (try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed);
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

    try testing.expectEqualStrings(HELLO_LINE_SHA256, (try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed);
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
    try testing.expectEqual(HashedFile.gone, try file_hash.hashFile(io, allocator, temporary.path, "gone.ts", &cache));
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
    const first = (try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed;
    const second = (try file_hash.hashFile(io, allocator, temporary.path, "b.ts", &cache)).hashed;
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

    const big = try allocator.alloc(u8, file_hash.READ_BUFFER_BYTES * 2 + 17);
    @memset(big, 'x');
    try temporary.write("big.bin", big);

    var cache: FileHashCache = .empty;
    const hash = (try file_hash.hashFile(io, allocator, temporary.path, "big.bin", &cache)).hashed;

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
    var hashed = try file_hash.hashFiles(io, allocator, temporary.path, &.{ "b.ts", "a.ts" }, &cache);

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
    var hashed = try file_hash.hashFiles(io, allocator, temporary.path, &.{ "here.ts", "gone.ts" }, &hashed_cache);

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
    var hashed = try file_hash.hashFiles(io, allocator, "/nowhere", &.{}, &cache);
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

    const rendered = try file_hash.cacheToValue(allocator, &cache);
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

    var cache = try file_hash.cacheFromValue(allocator, .{ .object = object });
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

    var cache = try file_hash.cacheFromValue(allocator, .{ .object = object });
    try testing.expectEqual(@as(usize, 1), cache.count());
    try testing.expectEqual(@as(f64, 3), cache.get("good.ts").?.mtime_ms);
}

test "cacheFromValue of anything that is not an object is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try file_hash.cacheFromValue(allocator, .null)).count());
    try testing.expectEqual(@as(usize, 0), (try file_hash.cacheFromValue(allocator, .{ .array = value.newArray(allocator) })).count());
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
    _ = (try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache)).hashed;

    var round_tripped = try file_hash.cacheFromValue(allocator, try file_hash.cacheToValue(allocator, &cache));

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
    try testing.expectEqualStrings("from-a-round-trip", (try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &round_tripped)).hashed);
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
    try testing.expectEqualStrings(HELLO_LINE_SHA256, try file_hash.hashFileContent(io, allocator, try temporary.join(allocator, "a.ts")));
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
        try file_hash.hashFileContent(io, allocator, try temporary.join(allocator, "empty.ts")),
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
    try testing.expectError(error.FileNotFound, file_hash.hashFileContent(io, allocator, try temporary.join(allocator, "gone.ts")));
}
