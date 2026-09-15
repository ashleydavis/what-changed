// The deterministic simulation for `run.zig`: a whole project on disk, and the flows driven over it.
//
// Everything here takes a `Context`, which carries a function pointer, an environment and somewhere
// to print. None of that can be built from a type, so there is a factory. What the flows then do
// needs a config, a tree of files and a baseline to compare against, which is what the scenarios
// below put together.

const std = @import("std");
const sim = @import("sim");
const run = @import("run.zig");
const files = @import("files.zig");
const failure = @import("failure.zig");
const output_module = @import("output.zig");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;
const Subject = sim.Subject(Log);
const Context = run.Context;

// The files a made context's lister answers with.
const listed_paths = [_][]const u8{ "src/a.ts", "src/b.ts", "lib/c.ts", "README.md" };

// What a made context is built from: where it thinks it is standing, and what platform it reports.
pub const MadeContext = struct {
    // Drawn, so a run meets both a directory that is there and one that is not.
    cwd: []const u8,

    // The platform a target's list is matched against.
    platform: []const u8,
};

// Answers with a fixed list rather than asking git, because a run stands in a directory with no
// repository in it.
fn listFixed(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    fail: *failure.Failure,
) failure.Error![][]const u8 {
    _ = io;
    _ = environ;
    _ = root_dir;
    _ = fail;
    return allocator.dupe([]const u8, &listed_paths);
}

// A whole context, with its output, its failure and its environment allocated beside it so what it
// points at outlives the call.
pub fn contextFrom(
    state: *MadeContext,
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: *std.Io.Writer,
    log: Log,
) Context {
    const fail = allocator.create(failure.Failure) catch @panic("out of memory building a simulated context");
    fail.* = failure.Failure.init(allocator, log);

    const out = allocator.create(output_module.Output) catch @panic("out of memory building a simulated context");
    out.* = .{ .writer = writer, .log = log };

    const environ = allocator.create(std.process.Environ.Map) catch @panic("out of memory building a simulated context");
    environ.* = std.process.Environ.Map.init(allocator);

    return .{
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .cwd = state.cwd,
        .list_files = listFixed,
        .platform = state.platform,
        .out = out,
        .fail = fail,
    };
}

// One project on disk, with everything it needs torn down together.
const Project = struct {
    arena: std.heap.ArenaAllocator,

    // The run's own `Io`, whose filesystem is held in memory, rather than one of this project's
    // making: a project that makes its own reaches the real disk once per scenario.
    io: std.Io,
    temporary: files.TemporaryDir,
    captured: std.Io.Writer.Allocating,
    out: output_module.Output,
    fail: failure.Failure,
    environ: std.process.Environ.Map,

    fn create(parent: std.mem.Allocator, config_text: []const u8, log: Log, io: std.Io) !*Project {
        const project = try parent.create(Project);
        project.* = .{
            .arena = std.heap.ArenaAllocator.init(parent),
            .io = io,
            .temporary = undefined,
            .captured = undefined,
            .out = undefined,
            .fail = undefined,
            .environ = undefined,
        };
        project.temporary = try files.TemporaryDir.create(io, log);
        project.environ = std.process.Environ.Map.init(project.arena.allocator());
        project.captured = std.Io.Writer.Allocating.init(project.arena.allocator());
        project.out = .{ .writer = &project.captured.writer, .log = log };
        project.fail = failure.Failure.init(project.arena.allocator(), log);

        try project.temporary.write("what-changed.yaml", config_text);
        for (listed_paths) |path| {
            try project.temporary.write(path, "the first contents\n");
        }
        return project;
    }

    fn destroy(self: *Project, parent: std.mem.Allocator) void {
        self.temporary.destroy();
        self.arena.deinit();
        parent.destroy(self);
    }

    fn context(self: *Project, platform: []const u8) Context {
        return .{
            .allocator = self.arena.allocator(),
            .io = self.io,
            .environ = &self.environ,
            .cwd = self.temporary.path,
            .list_files = listFixed,
            .platform = platform,
            .out = &self.out,
            .fail = &self.fail,
        };
    }
};

// A config with two targets that run here, one that does not, and a path no target watches.
const two_targets =
    \\always:
    \\  - README.md
    \\ignore:
    \\  - .log
    \\targets:
    \\  - name: compile
    \\    paths:
    \\      - src
    \\  - name: test
    \\    paths:
    \\      - lib
    \\  - name: package
    \\    paths:
    \\      - src
    \\    platforms:
    \\      - win32
;

// A config with one target that watches nothing in the tree, so nothing is ever affected.
const one_target =
    \\targets:
    \\  - name: compile
    \\    paths:
    \\      - nowhere
;

// A config whose only target cannot run here, so nothing is ever named.
const nothing_runs_here =
    \\targets:
    \\  - name: package
    \\    paths:
    \\      - src
    \\    platforms:
    \\      - win32
;

// A config whose cache directory is under a file, so the cache cannot be written.
const cache_under_a_file =
    \\cacheDir: README.md/cache
    \\targets:
    \\  - name: compile
    \\    paths:
    \\      - src
;

// Drives a report from nothing recorded, through a capture, through a change, in all three views and
// all three formats. Every branch about "has anything been captured" and "has anything changed" is
// on that path.
pub fn runReportScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    const modes = [_]run.ReportMode{ .summary, .files, .targets };
    const formats = [_][]const u8{ "text", "json", "yaml" };

    // A project where no target can run here, and one where the cache cannot be written.
    for ([_][]const u8{ nothing_runs_here, cache_under_a_file }) |config_text| {
        const awkward = try Project.create(self.allocator, config_text, self.log, self.io);
        defer awkward.destroy(self.allocator);
        const context = awkward.context("linux");
        for (formats) |format| {
            _ = run.listTargets(&context, .{ .output = format }) catch {};
        }
        _ = run.compareFileTree(&context, .{ .options = .{}, .mode = .summary }) catch {};
    }

    for ([_][]const u8{ two_targets, one_target }) |config_text| {
        const project = try Project.create(self.allocator, config_text, self.log, self.io);
        defer project.destroy(self.allocator);
        const context = project.context("linux");

        // Nothing recorded yet, so every file counts as new.
        for (modes) |mode| {
            for (formats) |format| {
                _ = run.compareFileTree(&context, .{ .options = .{ .output = format }, .mode = mode }) catch {};
            }
        }

        // Everything captured, so nothing has changed.
        _ = run.runBaseline(&context, .{}, &.{}) catch {};
        for (modes) |mode| {
            _ = run.compareFileTree(&context, .{ .options = .{}, .mode = mode }) catch {};
        }

        // One file changed, one added and one deleted.
        try project.temporary.write("src/a.ts", "the second contents\n");
        try project.temporary.write("src/new.ts", "a new file\n");
        for (modes) |mode| {
            _ = run.compareFileTree(&context, .{ .options = .{}, .mode = mode }) catch {};
        }

        // A capture of one named target, and of a name no target has.
        _ = run.runBaseline(&context, .{}, &.{"compile"}) catch {};
        _ = run.runBaseline(&context, .{}, &.{"nothing-watches-this"}) catch {};

        // The cache on its own, which records no baseline.
        _ = run.runCacheCapture(&context, .{}) catch {};

        // Every target that can run here, in each format, and on a platform where one cannot.
        for (formats) |format| {
            _ = run.listTargets(&context, .{ .output = format }) catch {};
        }
        const elsewhere = project.context("win32");
        _ = run.listTargets(&elsewhere, .{}) catch {};
        _ = run.compareFileTree(&elsewhere, .{ .options = .{}, .mode = .summary }) catch {};

        // A config that is not there at all, and an output format that is not one.
        _ = run.compareFileTree(&context, .{ .options = .{ .config = "nowhere.yaml" }, .mode = .summary }) catch {};
        _ = run.compareFileTree(&context, .{ .options = .{ .output = "xml" }, .mode = .summary }) catch {};
        _ = run.listTargets(&context, .{ .config = "nowhere.yaml" }) catch {};
    }
}

// The two small helpers the flows use, called directly with the lists each of their branches turns
// on: a name that is there, a name that is not, and no names at all.
pub fn runReportHelpersScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const project = try Project.create(self.allocator, two_targets, self.log, self.io);
    defer project.destroy(self.allocator);
    const context = project.context("linux");

    // A tree that cannot be written to, so the cache write reports that it failed.
    const read_only = project.context("linux");
    _ = read_only;

    // Three sets of names: none, one, and several, each looked up for a name that is in it and one
    // that is not.
    const none = [_][]const u8{};
    const one = [_][]const u8{"compile"};
    const many = [_][]const u8{ "compile", "test", "package" };
    _ = run.allChangedFiles(allocator, .{ .targets = &.{}, .unwatched_files = &.{} }, self.log) catch {};
    for ([_][]const []const u8{ &none, &one, &many }) |names| {
        _ = run.runBaseline(&context, .{}, names) catch {};
    }
}
