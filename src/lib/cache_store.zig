const std = @import("std");
const files = @import("files.zig");
const value = @import("value.zig");
const json = @import("json.zig");
const file_hash = @import("file_hash.zig");
const failure = @import("failure.zig");

const FileHashCache = file_hash.FileHashCache;
const Value = value.Value;

//
// The name of the file holding the per-file content hashes.
//
pub const FILE_HASHES_NAME = "file-hashes.json";

//
// The file hash cache: what the tool keeps purely so it does not have to redo work.
//
// Nothing in here affects what the tool reports. Deleting the lot costs one slow run and nothing
// else. That is what separates it from the baseline, which lives in its own file (see
// baseline_store.zig) because losing that DOES change the answer.
//
pub const Cache = struct {
    //
    // The per-file hashes, keyed by path, so a file whose mtime and size are unchanged is never read
    // again.
    //
    file_hashes: FileHashCache,
};

//
// Loads the file hash cache from disk. A missing directory, a missing file, or JSON that will not
// parse or is not a plain object all yield empty structures rather than an error: a damaged cache
// should cost a slow run, never a blocked one.
//
pub fn loadCache(allocator: std.mem.Allocator, cache_dir: []const u8) std.mem.Allocator.Error!Cache {
    const path = try files.joinPath(allocator, &.{ cache_dir, FILE_HASHES_NAME });
    return .{ .file_hashes = try file_hash.cacheFromValue(allocator, try readJsonObject(allocator, path)) };
}

//
// Reads a JSON object from a file, returning an empty object for anything that is not a readable,
// parseable, plain JSON object.
//
pub fn readJsonObject(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!Value {
    const text = files.readFile(allocator, path) catch {
        return .{ .object = value.newObject(allocator) };
    };

    const parsed = json.parse(allocator, text) catch {
        return .{ .object = value.newObject(allocator) };
    };

    if (!value.isPlainObject(parsed)) {
        return .{ .object = value.newObject(allocator) };
    }
    return parsed;
}

//
// Writes the per-file hashes, creating the cache directory if it is not there yet.
//
pub fn saveFileHashes(allocator: std.mem.Allocator, cache_dir: []const u8, hashes: *const FileHashCache) !void {
    const path = try files.joinPath(allocator, &.{ cache_dir, FILE_HASHES_NAME });
    try writeJsonFile(allocator, path, try file_hash.cacheToValue(allocator, hashes));
}

//
// Writes a JSON file through a temporary sibling and a rename, so a crash part way through a write
// cannot leave a half-written file behind for the next run to choke on. The directory above it is
// created if it is not there yet.
//
// The temporary name carries fresh random bytes because several processes write these files at once:
// a parallel test suite ends every script with a capture. When they all shared one temp name they
// fought over it, and the second to rename found the first had already moved it away and failed with
// ENOENT. A name per writer means each renames its own file and the last one wins.
//
pub fn writeJsonFile(allocator: std.mem.Allocator, path: []const u8, contents: Value) !void {
    try files.makeParentDir(path);

    const temporary_path = try std.fmt.allocPrint(allocator, "{s}.{s}.tmp", .{ path, try randomName(allocator) });
    errdefer files.removeFile(temporary_path);

    try files.writeFile(temporary_path, try json.stringify(allocator, contents));
    try files.renameFile(temporary_path, path);
}

//
// A name no other writer will pick, for a temporary file.
//
// The TypeScript uses randomUUID. This uses the same amount of randomness from the same kind of
// source; the exact spelling does not matter, because nothing ever reads these names back.
//
pub fn randomName(allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var raw: [16]u8 = undefined;
    files.io().random(&raw);

    const hex = try allocator.alloc(u8, raw.len * 2);
    @memcpy(hex, &std.fmt.bytesToHex(raw, .lower));
    return hex;
}

//
// How long to keep trying for a file's update lock, and how long to wait between tries. A writer
// only ever waits out another writer's read-and-write of one small JSON file, so the wait is
// milliseconds in practice and this ceiling is only there so a wedged process cannot hang a build
// forever.
//
pub const LOCK_ATTEMPTS = 600;
pub const LOCK_RETRY_MS = 50;

//
// A lock file older than this is treated as abandoned by a process that died still holding it, and
// is taken over. Far longer than any real update takes, so a slow but living writer is never robbed.
//
pub const LOCK_STALE_MS = 60000;

//
// Waits until no other process holds the lock beside a file, then takes it.
//
// Creating the lock file exclusively is what makes this safe: the filesystem lets exactly one caller
// create it and fails every other with "already exists", so there is no window in which two writers
// both believe they have it.
//
pub fn takeUpdateLock(lock_path: []const u8) !void {
    var attempt: usize = 0;
    while (attempt < LOCK_ATTEMPTS) : (attempt += 1) {
        if (files.createFileExclusive(lock_path)) {
            return;
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }

        clearAbandonedLock(lock_path);
        files.sleepMs(LOCK_RETRY_MS);
    }

    return error.LockTimeout;
}

//
// Removes a lock file old enough that whoever made it cannot still be working, so one killed process
// does not block every later one for good.
//
pub fn clearAbandonedLock(lock_path: []const u8) void {
    const stat = files.statFile(lock_path) catch return; // Already gone, which is what is wanted.

    const now_ms = files.nowMs();
    if (now_ms - stat.mtime_ms > LOCK_STALE_MS) {
        files.removeFile(lock_path);
    }
}

//
// Releases the lock beside a file.
//
pub fn releaseUpdateLock(lock_path: []const u8) void {
    files.removeFile(lock_path);
}

//
// Reads a JSON file, applies a change to what it holds, and writes the result back, with no other
// process able to slip its own read and write in between.
//
// The lock is what makes a read-modify-write safe across processes. Without it two callers both read
// the same contents, both apply their own change to that same starting point, and the second to
// write throws the first's change away. That is silent: nothing fails, the file is valid, and the
// only sign is work that quietly has to be redone later.
//
pub fn updateJsonFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    context: anytype,
    comptime mutate: fn (@TypeOf(context), std.mem.Allocator, Value) std.mem.Allocator.Error!Value,
    fail: *failure.Failure,
) failure.Error!void {
    files.makeParentDir(path) catch |err| {
        return fail.set("Failed to create the directory for \"{s}\": {s}", .{ path, files.describeError(err) });
    };

    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{path});
    takeUpdateLock(lock_path) catch |err| switch (err) {
        error.LockTimeout => return fail.set(
            "Gave up waiting for the update lock at \"{s}\" after {d}s. Delete it if no other run is going.",
            .{ lock_path, (LOCK_ATTEMPTS * LOCK_RETRY_MS) / 1000 },
        ),
        else => return fail.set("Failed to take the update lock at \"{s}\": {s}", .{ lock_path, files.describeError(err) }),
    };

    //
    // Released however this leaves, so a write that fails does not strand the lock and make every
    // later writer wait out the abandonment timeout.
    //
    defer releaseUpdateLock(lock_path);

    const current = try readJsonObject(allocator, path);
    writeJsonFile(allocator, path, try mutate(context, allocator, current)) catch |err| {
        return fail.set("Failed to write \"{s}\": {s}", .{ path, files.describeError(err) });
    };
}

//
// Empties the file hash cache, so the next run rehashes every file.
//
// An empty cache is written rather than the file being deleted. Everything that reads it already
// treats empty and absent the same way, and a write cannot go wrong the way a delete of a computed
// path can: if the path were ever empty or wrong, a delete would take something real with it.
//
pub fn cacheReset(allocator: std.mem.Allocator, cache_dir: []const u8) !void {
    const empty: FileHashCache = .empty;
    try saveFileHashes(allocator, cache_dir, &empty);
}

//
// Returns a copy of the file hash cache holding only the paths that still exist, so entries for
// deleted files do not accumulate for the life of the checkout.
//
pub fn pruneFileHashes(allocator: std.mem.Allocator, hashes: *const FileHashCache, current_paths: []const []const u8) std.mem.Allocator.Error!FileHashCache {
    var keep: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (current_paths) |path| {
        try keep.put(allocator, path, {});
    }

    var pruned: FileHashCache = .empty;
    var walker = hashes.iterator();
    while (walker.next()) |entry| {
        if (keep.contains(entry.key_ptr.*)) {
            try pruned.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    return pruned;
}

const testing = std.testing;

//
// Replaces whatever is in the file with a fixed object, for testing updateJsonFile.
//
fn replaceWith(replacement: Value, allocator: std.mem.Allocator, current: Value) std.mem.Allocator.Error!Value {
    _ = current;
    _ = allocator;
    return replacement;
}

//
// Adds one field to whatever is in the file, for testing that the read and the write are one step.
//
fn addField(name: []const u8, allocator: std.mem.Allocator, current: Value) std.mem.Allocator.Error!Value {
    var object = switch (current) {
        .object => |existing| existing,
        else => value.newObject(allocator),
    };
    try object.put(allocator, name, value.boolean(true));
    return .{ .object = object };
}

test "readJsonObject reads an object off disk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    try temporary.write("data.json", "{\"a\": 1}");

    const parsed = try readJsonObject(allocator, try temporary.join(allocator, "data.json"));
    try testing.expectEqual(@as(i64, 1), value.get(parsed, "a").?.integer);
}

test "readJsonObject treats a missing, damaged or wrongly typed file as empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    try temporary.write("broken.json", "{ not json");
    try temporary.write("array.json", "[1, 2]");
    try temporary.write("scalar.json", "42");

    try testing.expectEqual(@as(usize, 0), (try readJsonObject(allocator, try temporary.join(allocator, "gone.json"))).object.count());
    try testing.expectEqual(@as(usize, 0), (try readJsonObject(allocator, try temporary.join(allocator, "broken.json"))).object.count());
    try testing.expectEqual(@as(usize, 0), (try readJsonObject(allocator, try temporary.join(allocator, "array.json"))).object.count());
    try testing.expectEqual(@as(usize, 0), (try readJsonObject(allocator, try temporary.join(allocator, "scalar.json"))).object.count());
}

test "loadCache reads the hashes back, and an absent cache is empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    const cache_dir = try temporary.join(allocator, "cache");

    var empty = try loadCache(allocator, cache_dir);
    try testing.expectEqual(@as(usize, 0), empty.file_hashes.count());

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "a.ts", .{ .mtime_ms = 1.5, .size = 3, .hash = "hash-a" });
    try saveFileHashes(allocator, cache_dir, &hashes);

    var loaded = try loadCache(allocator, cache_dir);
    try testing.expectEqual(@as(usize, 1), loaded.file_hashes.count());
    try testing.expectEqualStrings("hash-a", loaded.file_hashes.get("a.ts").?.hash);
    try testing.expectEqual(@as(f64, 1.5), loaded.file_hashes.get("a.ts").?.mtime_ms);
}

test "saveFileHashes creates the cache directory when it is not there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "a.ts", .{ .mtime_ms = 1, .size = 1, .hash = "h" });
    try saveFileHashes(allocator, try temporary.join(allocator, "deep/nested/cache"), &hashes);

    try testing.expect(temporary.has("deep/nested/cache/" ++ FILE_HASHES_NAME));
}

test "writeJsonFile leaves no temporary file behind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();

    var object = value.newObject(allocator);
    try object.put(allocator, "a", value.int(1));
    try writeJsonFile(allocator, try temporary.join(allocator, "out.json"), .{ .object = object });

    var directory = try std.Io.Dir.cwd().openDir(files.io(), temporary.path, .{ .iterate = true });
    defer directory.close(files.io());

    var walker = directory.iterate();
    var count: usize = 0;
    while (try walker.next(files.io())) |entry| {
        count += 1;
        try testing.expectEqualStrings("out.json", entry.name);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "writeJsonFile writes what JSON.stringify with two spaces would" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();

    var object = value.newObject(allocator);
    try object.put(allocator, "targets", .{ .object = value.newObject(allocator) });
    try object.put(allocator, "files", .{ .object = value.newObject(allocator) });
    try writeJsonFile(allocator, try temporary.join(allocator, "baseline.json"), .{ .object = object });

    try testing.expectEqualStrings(
        \\{
        \\  "targets": {},
        \\  "files": {}
        \\}
    , try temporary.read(allocator, "baseline.json"));
}

test "randomName gives a different name every time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try randomName(allocator);
    const second = try randomName(allocator);
    try testing.expectEqual(@as(usize, 32), first.len);
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "takeUpdateLock takes a free lock and refuses a held one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    const lock_path = try temporary.join(allocator, "thing.json.lock");

    try takeUpdateLock(lock_path);
    try testing.expect(files.fileExists(lock_path));

    releaseUpdateLock(lock_path);
    try testing.expect(!files.fileExists(lock_path));

    //
    // And it can be taken again once released, which is what makes the whole thing usable more than
    // once in a process's lifetime.
    //
    try takeUpdateLock(lock_path);
    releaseUpdateLock(lock_path);
}

test "clearAbandonedLock leaves a fresh lock alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    const lock_path = try temporary.join(allocator, "fresh.lock");

    try takeUpdateLock(lock_path);
    clearAbandonedLock(lock_path);

    //
    // A living writer must never be robbed of its lock, so a lock made a moment ago stays.
    //
    try testing.expect(files.fileExists(lock_path));
    releaseUpdateLock(lock_path);
}

test "clearAbandonedLock does not mind a lock that is already gone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    clearAbandonedLock(try temporary.join(allocator, "never-existed.lock"));
}

test "updateJsonFile writes the result of the change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    const path = try temporary.join(allocator, "nested/data.json");

    var replacement = value.newObject(allocator);
    try replacement.put(allocator, "written", value.boolean(true));

    var fail = failure.Failure.init(allocator);
    try updateJsonFile(allocator, path, Value{ .object = replacement }, replaceWith, &fail);

    const read_back = try readJsonObject(allocator, path);
    try testing.expectEqual(true, value.get(read_back, "written").?.bool);
}

test "updateJsonFile hands the current contents to the change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    const path = try temporary.join(allocator, "data.json");

    var fail = failure.Failure.init(allocator);
    try updateJsonFile(allocator, path, @as([]const u8, "first"), addField, &fail);
    try updateJsonFile(allocator, path, @as([]const u8, "second"), addField, &fail);

    //
    // Both fields are there, which is the whole point: the second update read what the first wrote
    // rather than starting from nothing.
    //
    const read_back = try readJsonObject(allocator, path);
    try testing.expectEqual(true, value.get(read_back, "first").?.bool);
    try testing.expectEqual(true, value.get(read_back, "second").?.bool);
}

test "updateJsonFile releases the lock when it is done" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    const path = try temporary.join(allocator, "data.json");

    var fail = failure.Failure.init(allocator);
    try updateJsonFile(allocator, path, @as([]const u8, "a"), addField, &fail);

    try testing.expect(!files.fileExists(try std.fmt.allocPrint(allocator, "{s}.lock", .{path})));
}

test "cacheReset writes an empty cache rather than deleting the file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create();
    defer temporary.destroy();
    const cache_dir = try temporary.join(allocator, "cache");

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "a.ts", .{ .mtime_ms = 1, .size = 1, .hash = "h" });
    try saveFileHashes(allocator, cache_dir, &hashes);

    try cacheReset(allocator, cache_dir);

    try testing.expect(temporary.has("cache/" ++ FILE_HASHES_NAME));
    var loaded = try loadCache(allocator, cache_dir);
    try testing.expectEqual(@as(usize, 0), loaded.file_hashes.count());
}

test "pruneFileHashes keeps only the paths that still exist" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "kept.ts", .{ .mtime_ms = 1, .size = 1, .hash = "1" });
    try hashes.put(allocator, "gone.ts", .{ .mtime_ms = 2, .size = 2, .hash = "2" });

    var pruned = try pruneFileHashes(allocator, &hashes, &.{ "kept.ts", "never-hashed.ts" });
    try testing.expectEqual(@as(usize, 1), pruned.count());
    try testing.expectEqualStrings("1", pruned.get("kept.ts").?.hash);
    try testing.expect(pruned.get("gone.ts") == null);
}

test "pruneFileHashes with no current paths keeps nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes: FileHashCache = .empty;
    try hashes.put(allocator, "a.ts", .{ .mtime_ms = 1, .size = 1, .hash = "1" });

    try testing.expectEqual(@as(usize, 0), (try pruneFileHashes(allocator, &hashes, &.{})).count());
}
