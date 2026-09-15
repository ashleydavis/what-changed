// What a run cannot put together for itself in `src/cmd`.
//
// The command layer reaches the library by module name, so the types it takes are that module's own
// rather than the ones the library's own simulations make. Every factory here is the same idea as
// the library's: a hash map, a list or a function pointer built field by field from its type has
// nothing valid inside it, and every function taking one is stepped over.

const std = @import("std");
const wc = @import("what-changed");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;
const Value = wc.value.Value;
const Context = wc.run.Context;
const Failure = wc.failure.Failure;
const Output = wc.output.Output;

// What a made `Value` is built from. The same fields as the library's own, for the same reasons.
// Which arm of a value the run is asking for.
pub const Kind = enum { nothing, flag, whole, fractional, text, list, object };

pub const MadeValue = struct {
    // Which of the union's arms this one is. An enum rather than a number, because the run draws
    // one of every enum value and a number wrapped around seven reached two of the seven.
    kind: Kind,
    text: []const u8,
    whole: i64,
    flag: bool,
    entries: u2,
};

pub fn valueFrom(state: *MadeValue, allocator: std.mem.Allocator) Value {
    return switch (state.kind) {
        .nothing => .null,
        .flag => .{ .bool = state.flag },
        .whole => .{ .integer = state.whole },
        .fractional => .{ .float = @floatFromInt(@mod(state.whole, 1000)) },
        .text => .{ .string = state.text },
        .list => blk: {
            var array = wc.value.Array.init(allocator);
            var at: usize = 0;
            while (at < state.entries) : (at += 1) {
                array.append(.{ .string = state.text }) catch break;
            }
            break :blk .{ .array = array };
        },
        .object => blk: {
            const keys = [_][]const u8{ "name", "paths", "platforms", "targets" };
            var object: wc.value.Object = .empty;
            var at: usize = 0;
            while (at < state.entries and at < keys.len) : (at += 1) {
                object.put(allocator, keys[at], .{ .string = state.text }) catch break;
            }
            break :blk .{ .object = object };
        },
    };
}

// What a made set of recorded file hashes is built from.
pub const MadeHashes = struct {
    entries: u2,
    hash: []const u8,
};

const paths = [_][]const u8{ "src/a.ts", "src/b.ts", "docs/c.md", "package.json" };

pub fn hashesFrom(state: *MadeHashes, allocator: std.mem.Allocator) wc.file_hashes.FileHashes {
    var hashes: wc.file_hashes.FileHashes = .empty;
    var at: usize = 0;
    while (at < state.entries and at < paths.len) : (at += 1) {
        hashes.put(allocator, paths[at], state.hash) catch return hashes;
    }
    return hashes;
}

// What a made file hash cache is built from.
pub const MadeCache = struct {
    entries: u2,
    mtime_ms: f64,
    size: u64,
    hash: []const u8,
};

pub fn cacheFrom(state: *MadeCache, allocator: std.mem.Allocator) wc.file_hash.FileHashCache {
    var cache: wc.file_hash.FileHashCache = .empty;
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

// What a made set of target records is built from.
pub const MadeTargets = struct {
    entries: u2,
    files: u2,
    hash: []const u8,
};

const names = [_][]const u8{ "compile", "test", "lint", "package" };

pub fn targetsFrom(state: *MadeTargets, allocator: std.mem.Allocator) wc.baseline_store.TargetBaselines {
    var targets: wc.baseline_store.TargetBaselines = .empty;
    var at: usize = 0;
    while (at < state.entries and at < names.len) : (at += 1) {
        var recorded: wc.file_hashes.FileHashes = .empty;
        var file: usize = 0;
        while (file < state.files and file < paths.len) : (file += 1) {
            recorded.put(allocator, paths[file], state.hash) catch break;
        }
        targets.put(allocator, names[at], recorded) catch return targets;
    }
    return targets;
}

// What a made environment is built from. Empty, because nothing the command layer does reads one:
// it is carried so the file lister a real run uses has something to hand to git.
pub const MadeEnviron = struct {
    unused: u1 = 0,
};

pub fn environFrom(state: *MadeEnviron, allocator: std.mem.Allocator) *const std.process.Environ.Map {
    _ = state;
    const room = allocator.create(std.process.Environ.Map) catch @panic("out of memory building a simulated environment");
    room.* = std.process.Environ.Map.init(allocator);
    return room;
}

// The file lister a made context is given: it answers with paths of this file's own rather than
// asking git, because a run stands in a directory with no repository in it.
fn listNothing(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    fail: *Failure,
) wc.failure.Error![][]const u8 {
    _ = io;
    _ = environ;
    _ = root_dir;
    _ = fail;
    return allocator.dupe([]const u8, &paths);
}

// What a made context is built from: where it thinks it is standing, and what platform it reports.
pub const MadeContext = struct {
    // The directory the tool was invoked from. Drawn, so a run meets both a path that is there and
    // one that is not.
    cwd: []const u8,

    // The platform a target's list is matched against.
    platform: []const u8,
};

// A whole context, with its output, its failure and its environment allocated beside it so what it
// points at outlives the call.
pub fn contextFrom(
    state: *MadeContext,
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    log: Log,
) Context {
    const fail = allocator.create(Failure) catch @panic("out of memory building a simulated context");
    fail.* = Failure.init(allocator, log);

    const out = allocator.create(Output) catch @panic("out of memory building a simulated context");
    out.* = .{ .writer = writer, .log = log };

    const environ = allocator.create(std.process.Environ.Map) catch @panic("out of memory building a simulated context");
    environ.* = std.process.Environ.Map.init(allocator);

    return .{
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .cwd = state.cwd,
        .list_files = listNothing,
        .platform = state.platform,
        .out = out,
        .fail = fail,
    };
}

// The project every command simulation below is driven against: a target that runs here and one that
// does not, a path every target watches, and an extension left out of the file list entirely.
pub const project_config =
    \\always:
    \\  - package.json
    \\ignore:
    \\  - .log
    \\targets:
    \\  - name: compile
    \\    paths:
    \\      - src
    \\  - name: package
    \\    paths:
    \\      - src
    \\    platforms:
    \\      - win32
;

// Every format a command can be asked to render in.
pub const formats = [_][]const u8{ "text", "json", "yaml" };


const sim = @import("sim");
const harness = @import("test/harness.zig");
const Subject = sim.Subject(Log);
// The harness itself, driven through everything a command test asks of it.
pub fn runHarnessScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
    defer scenario.destroy();

    // A project with nothing in it, one file, and several.
    try scenario.project(project_config, &.{});
    try scenario.project(project_config, &.{.{ "src/a.ts", "one" }});
    try scenario.project(project_config, &.{ .{ "src/a.ts", "one" }, .{ "src/b.ts", "two" }, .{ "src/c.ts", "three" } });

    try scenario.write("notes.md", "not in the list");
    _ = scenario.allocator();
    _ = scenario.io();
    _ = scenario.printed();
    scenario.clear();
    _ = scenario.context();
    _ = scenario.contextOn("win32");

    var fail = wc.failure.Failure.init(scenario.allocator(), self.log);
    var environ = std.process.Environ.Map.init(scenario.allocator());
    _ = try harness.listFromScenario(scenario.io(), &environ, scenario.allocator(), scenario.temporary.path, &fail);
}
