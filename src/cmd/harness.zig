const std = @import("std");
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
    _ = fail;
    return allocator.dupe([]const u8, file_list);
}

//
// One test's project, output and failure, all torn down together.
//
pub const Scenario = struct {
    arena: std.heap.ArenaAllocator,
    test_io: wc.files.TestIo,
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
    // Makes an empty project in a throwaway directory.
    //
    pub fn create() !*Scenario {
        const scenario = try std.testing.allocator.create(Scenario);
        scenario.* = .{
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .test_io = .init(),
            .temporary = undefined,
            .captured = undefined,
            .out = undefined,
            .fail = undefined,
            .environ = undefined,
        };
        scenario.temporary = try wc.files.TemporaryDir.create(scenario.test_io.io());
        scenario.environ = std.process.Environ.Map.init(scenario.arena.allocator());
        scenario.captured = std.Io.Writer.Allocating.init(scenario.arena.allocator());
        scenario.out = .{ .writer = &scenario.captured.writer };
        scenario.fail = Failure.init(scenario.arena.allocator());
        file_list = &.{};
        return scenario;
    }

    //
    // Removes the project and everything allocated for it.
    //
    pub fn destroy(self: *Scenario) void {
        self.temporary.destroy();
        self.test_io.deinit();
        self.arena.deinit();
        std.testing.allocator.destroy(self);
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
        return self.test_io.io();
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
