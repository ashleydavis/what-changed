const std = @import("std");
const annotate_mod = @import("log");

//
// This file drives the commands rather than being driven, so it sits in a directory a fault run is
// told to leave out and carries no branch markers of its own. It still takes a `Log`, because what
// it drives is marked and a scenario's log has to reach it.
//
const Log = annotate_mod.Log;
const wc = @import("what-changed");

const Context = wc.run.Context;
const Failure = wc.failure.Failure;
const Output = wc.output.Output;

//
// What the command tests are driven with: a throwaway project on disk, a file list the test chose,
// and somewhere to collect what was printed.
//
// The commands take all of this as arguments rather than reading the process, which is what lets a
// test run a real command end to end without a git repository, without touching the working
// directory, and without capturing the process's output.
//

//
// The list the fake lister answers with.
//
// A module-level value because a Zig function pointer carries no captured state, so the fake lister
// has nowhere else to keep what it was told to answer with. A scenario sets it as it writes the
// files.
//
var file_list: []const []const u8 = &.{};

//
// Answers with whatever the scenario last wrote, in place of asking git.
// Public only so the tests in harness.test.zig can reach it. Nothing else calls it.
//
//
pub fn listFromScenario(io: std.Io, environ: *const std.process.Environ.Map, allocator: std.mem.Allocator, root_dir: []const u8, fail: *Failure) wc.failure.Error![][]const u8 {
    _ = io;
    _ = environ;
    _ = root_dir;
    // Named because this stands in for `wc.list_files.listRepoFiles`, whose signature it has to
    // match to be assigned to the same function pointer. Nothing here can fail, so nothing records
    // a reason.
    _ = fail;
    return allocator.dupe([]const u8, file_list);
}

//
// One test's project, output and failure, all torn down together.
//
pub const Scenario = struct {
    arena: std.heap.ArenaAllocator,

    // Null when the scenario was handed an `Io` to use. A unit test makes its own, which reaches the
    // real disk; a simulation passes the one the run gave it, whose filesystem is held in memory.
    test_io: ?wc.files.TestIo,
    given: ?std.Io,
    temporary: wc.files.TemporaryDir,
    captured: std.Io.Writer.Allocating,
    out: Output,
    fail: Failure,

    //
    // Empty, because the scenario's lister never spawns anything. Held here so the context can point
    // at a real map rather than the test run's own environment.
    //
    environ: std.process.Environ.Map,

    //
    // Where this scenario's own branch markers go.
    //
    log: Log = .{},

    //
    // Where the scenario itself is allocated from, which is not the arena inside it: the arena is
    // freed as one piece and this is what frees the piece holding it. A parameter rather than the
    // testing allocator, because a fault run is not a test build and reaching for that one there
    // stops the compile.
    //
    parent: std.mem.Allocator,

    //
    // Makes an empty project in a throwaway directory.
    //
    pub fn create(parent: std.mem.Allocator, log: Log) !*Scenario {
        return build(parent, log, null);
    }

    //
    // The same, driven through an `Io` the caller already has. A simulation passes the run's own,
    // whose filesystem is in memory, so the project this makes costs no syscall and leaves nothing
    // on disk when the scenario ends.
    //
    pub fn createOn(parent: std.mem.Allocator, log: Log, io_given: std.Io) !*Scenario {
        return build(parent, log, io_given);
    }

    fn build(parent: std.mem.Allocator, log: Log, io_given: ?std.Io) !*Scenario {
        const scenario = try parent.create(Scenario);
        scenario.* = .{
            .arena = std.heap.ArenaAllocator.init(parent),
            .test_io = if (io_given == null) .init(log) else null,
            .given = io_given,
            .temporary = undefined,
            .captured = undefined,
            .out = undefined,
            .fail = undefined,
            .environ = undefined,
            .log = log,
            .parent = parent,
        };
        scenario.temporary = try wc.files.TemporaryDir.create(scenario.io(), log);
        scenario.environ = std.process.Environ.Map.init(scenario.arena.allocator());
        scenario.captured = std.Io.Writer.Allocating.init(scenario.arena.allocator());
        scenario.out = .{ .writer = &scenario.captured.writer, .log = log };
        scenario.fail = Failure.init(scenario.arena.allocator(), log);
        file_list = &.{};
        return scenario;
    }

    //
    // Removes the project and everything allocated for it.
    //
    pub fn destroy(self: *Scenario) void {
        self.temporary.destroy();
        if (self.test_io) |*own| {
            own.deinit();
        }
        const parent = self.parent;
        self.arena.deinit();
        parent.destroy(self);
    }

    //
    // Where this scenario's memory comes from.
    //
    pub fn allocator(self: *Scenario) std.mem.Allocator {
        return self.arena.allocator();
    }

    //
    // The `Io` everything this scenario does goes through, which is its own and no other test's.
    //
    pub fn io(self: *Scenario) std.Io {
        if (self.given) |io_given| {
            return io_given;
        }
        return self.test_io.?.io();
    }

    //
    // Writes one file into the project, without adding it to the file list.
    //
    pub fn write(self: *Scenario, sub_path: []const u8, contents: []const u8) !void {
        try self.temporary.write(sub_path, contents);
    }

    //
    // Writes a config and the files it describes, and points the lister at them.
    //
    pub fn project(self: *Scenario, config_text: []const u8, tree: []const struct { []const u8, []const u8 }) !void {
        try self.temporary.write("what-changed.yaml", config_text);

        var paths: std.ArrayList([]const u8) = .empty;
        for (tree) |entry| {
            try self.temporary.write(entry[0], entry[1]);
            try paths.append(self.allocator(), entry[0]);
        }
        file_list = try paths.toOwnedSlice(self.allocator());
    }

    //
    // The context a command is driven with, reporting the platform as Linux unless a test says
    // otherwise.
    //
    pub fn context(self: *Scenario) Context {
        return self.contextOn("linux");
    }

    //
    // The context a command is driven with, on a chosen platform.
    //
    pub fn contextOn(self: *Scenario, platform: []const u8) Context {
        return .{
            .allocator = self.allocator(),
            .io = self.io(),
            .environ = &self.environ,
            .cwd = self.temporary.path,
            .list_files = listFromScenario,
            .platform = platform,
            .out = &self.out,
            .fail = &self.fail,
        };
    }

    //
    // What has been printed so far.
    //
    pub fn printed(self: *Scenario) []const u8 {
        return self.captured.written();
    }

    //
    // Forgets what has been printed, so one test can check several commands in turn.
    //
    pub fn clear(self: *Scenario) void {
        self.captured.clearRetainingCapacity();
    }
};

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("harness.test.zig");
}
