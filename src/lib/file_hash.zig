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
// Public so the tests in file_hash.test.zig can build a file bigger than one window without
// repeating the number here: a copy would keep passing if this ever grew, while testing nothing.
//
pub const READ_BUFFER_BYTES = 64 * 1024;

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

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change to the
    // code. Nothing else imports that file, so naming it here is what makes `zig build test` run it.
    //
    _ = @import("file_hash.test.zig");
}
