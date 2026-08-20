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
pub fn loadCache(io: std.Io, allocator: std.mem.Allocator, cache_dir: []const u8) std.mem.Allocator.Error!Cache {
    const path = try files.joinPath(allocator, &.{ cache_dir, FILE_HASHES_NAME });
    return .{ .file_hashes = try file_hash.cacheFromValue(allocator, (try readJsonObject(io, allocator, path)).contentOrNull()) };
}

//
// What came of reading a JSON object out of a file.
//
// The four ways there is no object are kept apart rather than collapsed into an empty one. They are
// not the same news: a file that is not there has never been written, and a file that is there and
// unusable is a problem someone has to go and look at. Reporting the second as the first is how
// `baseline show` came to say "no target has been captured yet" about a file sitting in front of it.
//
// A caller that genuinely treats all four alike says so with `contentOrNull`.
//
pub const JsonObjectFile = union(enum) {
    //
    // The file held a JSON object, which is here.
    //
    object: Value,

    //
    // There is no file at that path.
    //
    absent,

    //
    // The file is there and could not be read, with the error that stopped it.
    //
    unreadable: anyerror,

    //
    // The file is there and its content will not parse as JSON.
    //
    not_json,

    //
    // The file is there and holds valid JSON that is not an object: an array, a number, a string.
    //
    not_an_object,

    //
    // The object that was read, or `.null` for every way there was not one.
    //
    // For a caller that treats all four failures alike. Everything that reads one of these values
    // already treats anything that is not an object as empty, so `.null` needs no branch of its own.
    //
    pub fn contentOrNull(self: JsonObjectFile) Value {
        return switch (self) {
            .object => |object| object,
            else => .null,
        };
    }

    //
    // The name the machine-readable output uses for this outcome.
    //
    // Spelled out here rather than taken from the tag, because these names are part of what a script
    // reads and renaming a tag must not change them.
    //
    pub fn statusText(self: JsonObjectFile) []const u8 {
        return switch (self) {
            .object => "read",
            .absent => "absent",
            .unreadable => "unreadable",
            .not_json => "notJson",
            .not_an_object => "notAnObject",
        };
    }
};

//
// Reads a JSON object from a file, saying which of the four ways it failed when it did.
//
pub fn readJsonObject(io: std.Io, allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!JsonObjectFile {
    const text = files.readFile(io, allocator, path) catch |err| {
        return if (err == error.FileNotFound) .absent else .{ .unreadable = err };
    };

    const parsed = json.parse(allocator, text) catch return .not_json;

    if (!value.isPlainObject(parsed)) {
        return .not_an_object;
    }
    return .{ .object = parsed };
}

//
// Writes the per-file hashes, creating the cache directory if it is not there yet.
//
pub fn saveFileHashes(io: std.Io, allocator: std.mem.Allocator, cache_dir: []const u8, hashes: *const FileHashCache) !void {
    const path = try files.joinPath(allocator, &.{ cache_dir, FILE_HASHES_NAME });
    try writeJsonFile(io, allocator, path, try file_hash.cacheToValue(allocator, hashes));
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
pub fn writeJsonFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, contents: Value) !void {
    try files.makeParentDir(io, path);

    const temporary_path = try std.fmt.allocPrint(allocator, "{s}.{s}.tmp", .{ path, try randomName(io, allocator) });
    errdefer files.removeFile(io, temporary_path);

    try files.writeFile(io, temporary_path, try json.stringify(allocator, contents));
    try files.renameFile(io, temporary_path, path);
}

//
// A name no other writer will pick, for a temporary file.
//
// Sixteen random bytes from the platform's own source. The exact spelling does not matter, because
// nothing ever reads these names back.
//
pub fn randomName(io: std.Io, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);

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
pub fn takeUpdateLock(io: std.Io, lock_path: []const u8) !void {
    var attempt: usize = 0;
    while (attempt < LOCK_ATTEMPTS) : (attempt += 1) {
        if (files.createFileExclusive(io, lock_path)) {
            return;
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }

        clearAbandonedLock(io, lock_path);
        files.sleepMs(io, LOCK_RETRY_MS);
    }

    return error.LockTimeout;
}

//
// Removes a lock file old enough that whoever made it cannot still be working, so one killed process
// does not block every later one for good.
//
pub fn clearAbandonedLock(io: std.Io, lock_path: []const u8) void {
    const stat = files.statFile(io, lock_path) catch return; // Already gone, which is what is wanted.

    const now_ms = files.nowMs(io);
    if (now_ms - stat.mtime_ms > LOCK_STALE_MS) {
        files.removeFile(io, lock_path);
    }
}

//
// Releases the lock beside a file.
//
pub fn releaseUpdateLock(io: std.Io, lock_path: []const u8) void {
    files.removeFile(io, lock_path);
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
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    context: anytype,
    comptime mutate: fn (@TypeOf(context), std.mem.Allocator, Value) std.mem.Allocator.Error!Value,
    fail: *failure.Failure,
) failure.Error!void {
    files.makeParentDir(io, path) catch |err| {
        return fail.set("Failed to create the directory for \"{s}\": {s}", .{ path, files.describeError(err) });
    };

    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{path});
    takeUpdateLock(io, lock_path) catch |err| switch (err) {
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
    defer releaseUpdateLock(io, lock_path);

    const current = (try readJsonObject(io, allocator, path)).contentOrNull();
    writeJsonFile(io, allocator, path, try mutate(context, allocator, current)) catch |err| {
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
pub fn cacheReset(io: std.Io, allocator: std.mem.Allocator, cache_dir: []const u8) !void {
    const empty: FileHashCache = .empty;
    try saveFileHashes(io, allocator, cache_dir, &empty);
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

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("cache_store.test.zig");
}
