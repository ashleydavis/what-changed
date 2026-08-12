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
// A module-level value because a Zig function pointer carries no captured state. This is the one
// place the port cannot mirror the TypeScript, which closes over its list; the effect is the same,
// and a scenario sets it as it writes the files.
//
var file_list: []const []const u8 = &.{};

//
// Answers with whatever the scenario last wrote, in place of asking git.
//
fn listFromScenario(io: std.Io, allocator: std.mem.Allocator, root_dir: []const u8, fail: *Failure) wc.failure.Error![][]const u8 {
    _ = io;
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
        };
        scenario.temporary = try wc.files.TemporaryDir.create(scenario.test_io.io());
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

const testing = std.testing;

test "a scenario gives each test its own empty project" {
    var scenario = try Scenario.create();
    defer scenario.destroy();

    try testing.expectEqualStrings("", scenario.printed());
    try testing.expect(!scenario.temporary.has("what-changed.yaml"));
}

test "project writes the config and the files, and the lister reports them" {
    var scenario = try Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{ .{ "src/a.ts", "one" }, .{ "src/b.ts", "two" } });

    try testing.expect(scenario.temporary.has("what-changed.yaml"));
    try testing.expect(scenario.temporary.has("src/a.ts"));

    var fail = Failure.init(scenario.allocator());
    const listed = try listFromScenario(scenario.io(), scenario.allocator(), scenario.temporary.path, &fail);
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("src/a.ts", listed[0]);
}

test "clear forgets what was printed" {
    var scenario = try Scenario.create();
    defer scenario.destroy();

    scenario.out.line("something", .{});
    try testing.expectEqualStrings("something\n", scenario.printed());

    scenario.clear();
    try testing.expectEqualStrings("", scenario.printed());
}

test "the context points at the throwaway project" {
    var scenario = try Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    try testing.expectEqualStrings(scenario.temporary.path, context.cwd);
    try testing.expectEqualStrings("linux", context.platform);
    try testing.expectEqualStrings("darwin", scenario.contextOn("darwin").platform);
}
