// The deterministic simulation for `files.zig`: the errors a run cannot cause and the throwaway
// directory it cannot make twice.

const std = @import("std");
const sim = @import("sim");
const files = @import("files.zig");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;
const Subject = sim.Subject(Log);

// An `Io` that refuses to wait, and serves everything else the way the failing one does.
//
// Its vtable is a copy rather than one written out here: what an `Io` has to answer grows with the
// standard library, and a copy of the failing one keeps this to the single answer it is about.
var refusing_vtable: std.Io.VTable = undefined;

fn refuseToWait(userdata: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    _ = userdata;
    _ = timeout;
    return error.Canceled;
}

fn refusesToWait() std.Io {
    refusing_vtable = std.Io.failing.vtable.*;
    refusing_vtable.sleep = refuseToWait;
    return .{ .userdata = null, .vtable = &refusing_vtable };
}

// Every error the two description tables name, plus one they do not.
const named_errors = [_]anyerror{
    error.FileNotFound,
    error.AccessDenied,
    error.PermissionDenied,
    error.IsDir,
    error.NotDir,
    error.NameTooLong,
    error.SymLinkLoop,
    error.FileTooBig,
    error.StreamTooLong,
    error.NoSpaceLeft,
    error.SystemResources,
    error.ProcessFdQuotaExceeded,
    error.SystemFdQuotaExceeded,
    error.OutOfMemory,
    error.Unexpected,
};

// Describes each of them. A run reaches these only by causing the error, and most of these cannot be
// caused on demand: a symlink loop, a full disk, a process out of file descriptors.
pub fn runFileErrorsScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (named_errors) |err| {
        _ = files.describeError(err);
        _ = files.errorCode(err);
        _ = try files.describeOperation(allocator, err, "open", "src/a.ts");
    }
}

// The throwaway directory and the `Io` a test stands one up with, driven through their whole life:
// made, written to, read back, asked about, removed, and removed a second time when it is already
// gone.
pub fn runTemporaryDirScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The run's own `Io`, whose filesystem is held in memory: a scenario that makes an `Io` of its
    // own reaches the real disk, which costs a syscall per call and leaves files behind.
    const io = self.io;

    var temporary = try files.TemporaryDir.create(io, self.log);
    try temporary.write("src/a.ts", "the contents\n");
    _ = try temporary.read(allocator, "src/a.ts");
    _ = try temporary.join(allocator, "src/a.ts");
    _ = temporary.has("src/a.ts");
    _ = temporary.has("src/nowhere.ts");

    // A sub-path far longer than the buffer the join is formatted into.
    _ = temporary.has("n" ** 600);

    temporary.destroy();

    // A wait that is refused rather than served. Nothing a run stands up refuses one, so this is an
    // `Io` of this file's own: the failing one with its wait replaced, which is the only part of it
    // under test here.
    files.sleepMs(refusesToWait(), 1, self.log);

    // A directory that cannot be removed, because its path names something inside a file.
    var in_the_way = try files.TemporaryDir.create(io, self.log);
    try in_the_way.write("a-file", "not a directory\n");
    const under_a_file = try std.heap.page_allocator.dupe(u8, try std.fmt.allocPrint(allocator, "{s}/a-file/below", .{in_the_way.path}));
    var cannot_delete = files.TemporaryDir{ .path = under_a_file, .io = io, .log = self.log };
    cannot_delete.destroy();
    in_the_way.destroy();

    // A directory that was never there, removed, which is the branch that meets one somebody else
    // has already taken away.
    var never_made = files.TemporaryDir{
        .path = try std.heap.page_allocator.dupe(u8, "/tmp/what-changed-never-made"),
        .io = io,
        .log = self.log,
    };
    never_made.destroy();
}

// The `Io` a unit test drives the code with. Nothing a fault run does calls these, because a run
// hands out its own `Io`, so they are reached here or not at all.
pub fn runTestIoScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var made = files.TestIo.init(self.log);
    _ = made.io();
    made.deinit();
}
