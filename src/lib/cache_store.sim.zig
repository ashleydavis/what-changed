// The deterministic simulation for `cache_store.zig`: a file on disk, the four ways reading one can
// go wrong, and the lock two writers fight over.

const std = @import("std");
const sim = @import("sim");
const cache_store = @import("cache_store.zig");
const files = @import("files.zig");
const failure = @import("failure.zig");
const value = @import("value.zig");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;
const Subject = sim.Subject(Log);

// The same `Io`, with its wait taken out.
//
// A writer that cannot take the lock tries six hundred times, fifty milliseconds apart, which is
// half a minute of a run spent asleep. What is being driven is the giving up, not the waiting, and
// how long a wait takes is the `Io`'s to decide.
var impatient_vtable: std.Io.VTable = undefined;

fn doNotWait(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    _ = userdata;
    _ = timeout;
}

fn impatient(real: std.Io) std.Io {
    impatient_vtable = real.vtable.*;
    impatient_vtable.sleep = doNotWait;
    return .{ .userdata = real.userdata, .vtable = &impatient_vtable };
}

// Reads a JSON object out of each of the files it can be asked for: one that is there and holds one,
// one that is not there, one that will not parse, and one that parses to something else.
pub fn runReadJsonObjectScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
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

    try temporary.write("object.json", "{\"a\": 1}");
    try temporary.write("not-json.json", "{ not json");
    try temporary.write("not-an-object.json", "[1, 2, 3]");

    for ([_][]const u8{ "object.json", "not-json.json", "not-an-object.json", "gone.json" }) |name| {
        const path = try temporary.join(allocator, name);
        const read = try cache_store.readJsonObject(io, allocator, path, self.log);
        _ = read.contentOrNull();
        _ = read.statusText();
    }

    // Each outcome's own name, for the ones a directory cannot be made to produce on demand.
    for ([_]cache_store.JsonObjectFile{
        .{ .object = .null },
        .absent,
        .{ .unreadable = error.AccessDenied },
        .not_json,
        .not_an_object,
    }) |outcome| {
        _ = outcome.statusText();
        _ = outcome.contentOrNull();
    }
}

// The cache on disk, written, read back, pruned and emptied.
pub fn runCacheFileScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
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

    const cache_dir = try temporary.join(allocator, "cache");
    var loaded = try cache_store.loadCache(io, allocator, cache_dir, self.log);

    try loaded.file_hashes.put(allocator, "src/a.ts", .{ .mtime_ms = 1, .size = 2, .hash = "abc" });
    try loaded.file_hashes.put(allocator, "src/gone.ts", .{ .mtime_ms = 1, .size = 2, .hash = "def" });
    try cache_store.saveFileHashes(io, allocator, cache_dir, &loaded.file_hashes, self.log);

    _ = try cache_store.loadCache(io, allocator, cache_dir, self.log);
    _ = try cache_store.pruneFileHashes(allocator, &loaded.file_hashes, &.{}, self.log);
    _ = try cache_store.pruneFileHashes(allocator, &loaded.file_hashes, &.{"src/a.ts"}, self.log);
    try cache_store.cacheReset(io, allocator, cache_dir, self.log);

    _ = try cache_store.randomName(io, allocator);
}

// What a change under the lock does: the ordinary case, one where the file cannot be read, one where
// the directory cannot be made, and one where the lock is already held.
pub fn runUpdateJsonFileScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
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

    const path = try temporary.join(allocator, "record.json");

    // The ordinary case: nothing there yet, then a second change on top of the first.
    var fail = failure.Failure.init(allocator, self.log);
    try cache_store.updateJsonFile(io, allocator, path, Change{ .log = self.log }, Change.apply, &fail);
    try cache_store.updateJsonFile(io, allocator, path, Change{ .log = self.log }, Change.apply, &fail);

    // A directory that cannot be made, because a file is standing where it would go.
    try temporary.write("in-the-way", "not a directory\n");
    const under_a_file = try temporary.join(allocator, "in-the-way/record.json");
    var blocked = failure.Failure.init(allocator, self.log);
    cache_store.updateJsonFile(io, allocator, under_a_file, Change{ .log = self.log }, Change.apply, &blocked) catch {};

    // The lock already held by somebody else, and never released, so the wait gives up. The lock is
    // taken by hand rather than by a second process: what is being driven is the waiting, and a
    // second process is a slower way of arriving at the same place.
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{path});
    try files.createFileExclusive(io, lock_path);
    _ = try files.statFile(io, lock_path);
    cache_store.clearAbandonedLock(io, lock_path, self.log);
    try cache_store.releaseUpdateLock(io, lock_path, self.log);

    // Released twice, which is what meets a lock somebody else has already cleared.
    try cache_store.releaseUpdateLock(io, lock_path, self.log);

    // Taken, then taken again by the same caller, which is the branch that finds it held.
    try cache_store.takeUpdateLock(io, lock_path, self.log);
    cache_store.clearAbandonedLock(io, lock_path, self.log);
    try cache_store.releaseUpdateLock(io, lock_path, self.log);

    // A lock that was never made at all, which is the branch that finds nothing to clear.
    cache_store.clearAbandonedLock(io, try temporary.join(allocator, "never-made.lock"), self.log);

    // An abandoned lock: one whose file is old enough that whoever made it cannot still be working.
    // The age is set rather than waited for, so this takes no time and says the same thing twice.
    const abandoned_lock = try temporary.join(allocator, "abandoned.lock");
    try files.writeFile(io, abandoned_lock, "");
    try ageFile(io, abandoned_lock);
    cache_store.clearAbandonedLock(io, abandoned_lock, self.log);

    // The same, in a directory nothing may delete from, so clearing it is refused.
    const sealed = try temporary.join(allocator, "sealed");
    try files.makeDirPath(io, sealed);
    const sealed_lock = try std.fmt.allocPrint(allocator, "{s}/held.lock", .{sealed});
    try files.writeFile(io, sealed_lock, "");
    try ageFile(io, sealed_lock);
    try std.Io.Dir.cwd().setFilePermissions(io, sealed, std.Io.File.Permissions.default_dir.setReadOnly(true), .{});
    cache_store.clearAbandonedLock(io, sealed_lock, self.log);
    try std.Io.Dir.cwd().setFilePermissions(io, sealed, std.Io.File.Permissions.default_dir, .{});

    // A lock held by somebody who is still working: fresh, so it is never cleared, and every attempt
    // to take it finds it there until the caller gives up.
    const contested = try temporary.join(allocator, "contested.json");
    const contested_lock = try std.fmt.allocPrint(allocator, "{s}.lock", .{contested});
    try files.writeFile(io, contested_lock, "");
    var gave_up = failure.Failure.init(allocator, self.log);
    cache_store.updateJsonFile(impatient(io), allocator, contested, Change{ .log = self.log }, Change.apply, &gave_up) catch {};

    // A lock that cannot be created at all, because a directory is standing where the file would go.
    const blocked_path = try temporary.join(allocator, "blocked.json");
    const blocked_lock = try std.fmt.allocPrint(allocator, "{s}.lock", .{blocked_path});
    try files.makeDirPath(io, blocked_lock);
    var cannot_lock = failure.Failure.init(allocator, self.log);
    cache_store.updateJsonFile(impatient(io), allocator, blocked_path, Change{ .log = self.log }, Change.apply, &cannot_lock) catch {};

    // A file that is there and cannot be read, which the change refuses to write over.
    const unreadable_path = try temporary.join(allocator, "unreadable.json");
    try files.makeDirPath(io, unreadable_path);
    var refused = failure.Failure.init(allocator, self.log);
    cache_store.updateJsonFile(io, allocator, unreadable_path, Change{ .log = self.log }, Change.apply, &refused) catch {};

    // A directory nothing may write into, so the change is read and then cannot be written back.
    const read_only_dir = try std.fmt.allocPrintSentinel(allocator, "{s}/read-only", .{temporary.path}, 0);
    try files.makeDirPath(io, read_only_dir);
    const read_only_path = try std.fmt.allocPrint(allocator, "{s}/record.json", .{read_only_dir});
    try files.writeFile(io, read_only_path, "{}");
    // Set through the `Io` rather than with a raw `chmod`, which goes straight to the kernel and so
    // says nothing to the filesystem this run is actually using.
    try std.Io.Dir.cwd().setFilePermissions(io, read_only_dir, std.Io.File.Permissions.default_dir.setReadOnly(true), .{});
    var unwritable = failure.Failure.init(allocator, self.log);
    cache_store.updateJsonFile(io, allocator, read_only_path, Change{ .log = self.log }, Change.apply, &unwritable) catch {};
    try std.Io.Dir.cwd().setFilePermissions(io, read_only_dir, std.Io.File.Permissions.default_dir, .{});

    // A file the filesystem will not let go of: the read succeeds, the change is built, and writing
    // it back is refused. A read-only directory cannot produce this, because the lock file and the
    // temporary file sit in that same directory and the first of them fails instead.
    const sealed_path = try temporary.join(allocator, "sealed.json");
    try files.writeFile(io, sealed_path, "{}");
    try sim.filesystem.failWritesOf(sealed_path);
    var sealed_fail = failure.Failure.init(allocator, self.log);
    cache_store.updateJsonFile(io, allocator, sealed_path, Change{ .log = self.log }, Change.apply, &sealed_fail) catch {};

    // A lock that will not come off, because its file is turned into a directory while the change
    // is still going. The change is handed what it needs to do that, which is the only moment
    // anything is standing between the lock being taken and being released.
    const stranded_path = try temporary.join(allocator, "stranded.json");
    var stranded = failure.Failure.init(allocator, self.log);
    cache_store.updateJsonFile(io, allocator, stranded_path, Change{
        .log = self.log,
        .io = io,
        .strand = try std.fmt.allocPrint(allocator, "{s}.lock", .{stranded_path}),
    }, Change.apply, &stranded) catch {};
}

// A change that puts one field into whatever the file holds, and, when it is asked to, turns the
// lock file into a directory on its way past so the release cannot remove it.
const Change = struct {
    log: Log = .{},

    // How the strand below is done. Null for the ordinary change, which touches nothing.
    io: ?std.Io = null,

    // The lock file to leave behind, or null to leave it alone.
    strand: ?[]const u8 = null,

    fn apply(self: Change, allocator: std.mem.Allocator, current: value.Value) std.mem.Allocator.Error!value.Value {
        if (self.strand) |lock_path| {
            const io = self.io.?;
            files.removeFile(io, lock_path) catch {};
            files.makeDirPath(io, lock_path) catch {};
        }
        var object: value.Object = .empty;
        if (current == .object) {
            var walker = current.object.iterator();
            while (walker.next()) |entry| {
                try object.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        try object.put(allocator, "changed", .{ .bool = true });
        return .{ .object = object };
    }
};

// Sets a file's timestamp far enough back that the code reading it calls whoever made it long gone.
// Set rather than waited for: the age is what the branch turns on, and a run that waited a minute
// for it would be a minute longer for nothing.
fn ageFile(io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const now = std.Io.Clock.Timestamp.now(io, .real).raw;
    try file.setTimestamps(io, .{ .modify_timestamp = .{
        .new = .{ .nanoseconds = now.nanoseconds - (cache_store.LOCK_STALE_MS + 1_000) * std.time.ns_per_ms },
    } });
}
