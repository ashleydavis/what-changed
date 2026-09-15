// What a run cannot put together for itself in `file_hash.zig`.
//
// The cache is a hash map, so a value built field by field from its type has an entry pointer and a
// length drawn independently of each other and faults on its first read.

const std = @import("std");
const file_hash = @import("file_hash.zig");
const files = @import("files.zig");

const FileHashCache = file_hash.FileHashCache;

// What a made cache is built from: how many files it remembers, and what it remembers about them.
pub const MadeCache = struct {
    // How many entries, so a loop over the cache reaches its zero, one and many sides.
    entries: u2,

    // The recorded modification time and size. Drawn from their own types, so a run gets both the
    // pair that still matches the file on disk and the pair that does not.
    mtime_ms: f64,
    size: u64,

    // The recorded digest.
    hash: []const u8,
};

// The paths a made cache is keyed by, written here rather than drawn: two entries under one key are
// one entry, and a cache that can only ever hold one cannot reach a loop's many side.
const paths = [_][]const u8{ "src/a.ts", "src/b.ts", "docs/c.md", "package.json" };

pub fn cacheFrom(state: *MadeCache, allocator: std.mem.Allocator) FileHashCache {
    var cache: FileHashCache = .empty;
    var at: usize = 0;
    while (at < state.entries and at < paths.len) : (at += 1) {
        cache.put(allocator, paths[at], .{
            .mtime_ms = state.mtime_ms,
            .size = state.size,
            .hash = state.hash,
        }) catch return cache;
    }
    return cache;
}

const sim = @import("sim");
const value = @import("value.zig");
const Subject = sim.Subject(@import("log").Log);

// Every record the cache reader has a branch for, read back out of a JSON object.
//
// A cache file is written by this tool and read back by it, so a damaged one is the only way most of
// these are reached, and a damaged one is exactly what a run cannot invent.
pub fn runCacheFromValueScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Not an object at all.
    _ = try file_hash.cacheFromValue(allocator, .null, self.log);
    _ = try file_hash.cacheFromValue(allocator, .{ .integer = 1 }, self.log);

    // An object with nothing in it.
    const empty: value.Object = .empty;
    _ = try file_hash.cacheFromValue(allocator, .{ .object = empty }, self.log);

    // One whole record, which is what a cache this tool wrote holds.
    var whole: value.Object = .empty;
    try whole.put(allocator, "mtimeMs", .{ .float = 1.5 });
    try whole.put(allocator, "size", .{ .integer = 12 });
    try whole.put(allocator, "hash", .{ .string = "abc" });
    var one: value.Object = .empty;
    try one.put(allocator, "src/a.ts", .{ .object = whole });
    _ = try file_hash.cacheFromValue(allocator, .{ .object = one }, self.log);

    // A record per way one can be damaged, all in the one object so the entry loop goes round many
    // times as well.
    var damaged: value.Object = .empty;
    try damaged.put(allocator, "whole/a.ts", .{ .object = whole });
    try damaged.put(allocator, "not-a-record.ts", .{ .string = "not an object" });

    var whole_mtime: value.Object = .empty;
    try whole_mtime.put(allocator, "mtimeMs", .{ .integer = 2 });
    try whole_mtime.put(allocator, "size", .{ .float = 12.0 });
    try whole_mtime.put(allocator, "hash", .{ .string = "abc" });
    try damaged.put(allocator, "whole-mtime.ts", .{ .object = whole_mtime });

    var no_mtime: value.Object = .empty;
    try no_mtime.put(allocator, "size", .{ .integer = 12 });
    try damaged.put(allocator, "no-mtime.ts", .{ .object = no_mtime });

    var bad_mtime: value.Object = .empty;
    try bad_mtime.put(allocator, "mtimeMs", .{ .string = "soon" });
    try damaged.put(allocator, "bad-mtime.ts", .{ .object = bad_mtime });

    var no_size: value.Object = .empty;
    try no_size.put(allocator, "mtimeMs", .{ .float = 1.5 });
    try damaged.put(allocator, "no-size.ts", .{ .object = no_size });

    var bad_size: value.Object = .empty;
    try bad_size.put(allocator, "mtimeMs", .{ .float = 1.5 });
    try bad_size.put(allocator, "size", .{ .string = "big" });
    try damaged.put(allocator, "bad-size.ts", .{ .object = bad_size });

    var negative_whole: value.Object = .empty;
    try negative_whole.put(allocator, "mtimeMs", .{ .float = 1.5 });
    try negative_whole.put(allocator, "size", .{ .integer = -1 });
    try damaged.put(allocator, "negative-whole.ts", .{ .object = negative_whole });

    var negative_float: value.Object = .empty;
    try negative_float.put(allocator, "mtimeMs", .{ .float = 1.5 });
    try negative_float.put(allocator, "size", .{ .float = -1.0 });
    try damaged.put(allocator, "negative-float.ts", .{ .object = negative_float });

    var no_hash: value.Object = .empty;
    try no_hash.put(allocator, "mtimeMs", .{ .float = 1.5 });
    try no_hash.put(allocator, "size", .{ .integer = 12 });
    try damaged.put(allocator, "no-hash.ts", .{ .object = no_hash });

    var bad_hash: value.Object = .empty;
    try bad_hash.put(allocator, "mtimeMs", .{ .float = 1.5 });
    try bad_hash.put(allocator, "size", .{ .integer = 12 });
    try bad_hash.put(allocator, "hash", .{ .integer = 1 });
    try damaged.put(allocator, "bad-hash.ts", .{ .object = bad_hash });

    _ = try file_hash.cacheFromValue(allocator, .{ .object = damaged }, self.log);
}

// Hashing one file twice with a cache in between: once with nothing recorded, once with a record
// that still matches, and once with one that has gone stale.
pub fn runHashFileScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The run's own `Io`, whose filesystem is held in memory: a scenario that makes an `Io` of its
    // own reaches the real disk, which costs a syscall per call and leaves files behind.
    const io = self.io;

    var temporary = try files.TemporaryDir.create(io, self.log);
    defer temporary.destroy();
    try temporary.write("a.ts", "the first contents\n");
    try temporary.write("b.ts", "another file\n");

    var cache: file_hash.FileHashCache = .empty;

    // Nothing recorded, so the file is read.
    _ = try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache, self.log);

    // Recorded and unchanged, so it is not.
    _ = try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache, self.log);

    // The record made stale by hand, so the file is read again.
    if (cache.getPtr("a.ts")) |recorded| {
        recorded.size = recorded.size + 1;
    }
    _ = try file_hash.hashFile(io, allocator, temporary.path, "a.ts", &cache, self.log);

    // A file that is not there, and a whole set at once.
    _ = try file_hash.hashFile(io, allocator, temporary.path, "gone.ts", &cache, self.log);
    _ = try file_hash.hashFiles(io, allocator, temporary.path, &.{}, &cache, self.log);
    _ = try file_hash.hashFiles(io, allocator, temporary.path, &.{"a.ts"}, &cache, self.log);
    _ = try file_hash.hashFiles(io, allocator, temporary.path, &.{ "a.ts", "b.ts", "gone.ts" }, &cache, self.log);

    // An empty file, which the read loop takes in one pass rather than two: the first read gets
    // nothing and stops it.
    try temporary.write("empty.ts", "");
    _ = try file_hash.hashFile(io, allocator, temporary.path, "empty.ts", &cache, self.log);

    // A path that is a directory: it stats like anything else and then refuses to open as a file,
    // which is the branch for a file that cannot be read at all.
    try files.makeDirPath(io, try temporary.join(allocator, "a-directory"));
    _ = try file_hash.hashFile(io, allocator, temporary.path, "a-directory", &cache, self.log);

    // A file that opens and then gives out part way through, which is what a failing disk does. The
    // run's filesystem is asked for it by name, because an in-memory read has nothing that can fail.
    try temporary.write("breaks.ts", "contents that will not arrive\n");
    try sim.filesystem.failReadsOf(try temporary.join(allocator, "breaks.ts"));
    _ = try file_hash.hashFile(io, allocator, temporary.path, "breaks.ts", &cache, self.log);
    _ = try file_hash.hashFiles(io, allocator, temporary.path, &.{"breaks.ts"}, &cache, self.log);

    _ = try file_hash.cacheToValue(allocator, &cache, self.log);
}
