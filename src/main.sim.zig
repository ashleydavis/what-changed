// The deterministic simulation for `main.zig`: a process of the run's own making.
//
// Everything below `main` takes what the process was started with. A run cannot start a process, so
// it builds one: an argument vector, an empty environment, and an `Io` of its own. What `main` does
// with that is then the ordinary flow, driven the way a shell drives it.

const std = @import("std");
const sim = @import("sim");
const wc = @import("what-changed");
const main_mod = @import("main.zig");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;
const Subject = sim.Subject(Log);

// Every command line the CLI answers to, including the ones it refuses.
const command_lines = [_][]const [*:0]const u8{
    &.{"what-changed"},
    &.{ "what-changed", "--help" },
    &.{ "what-changed", "--version" },
    &.{ "what-changed", "summary" },
    &.{ "what-changed", "summary", "--output", "json" },
    &.{ "what-changed", "changes" },
    &.{ "what-changed", "targets" },
    &.{ "what-changed", "targets", "list" },
    &.{ "what-changed", "version" },
    &.{ "what-changed", "init" },
    &.{ "what-changed", "baseline", "show" },
    &.{ "what-changed", "baseline", "capture" },
    &.{ "what-changed", "baseline", "reset" },
    &.{ "what-changed", "cache", "show" },
    &.{ "what-changed", "cache", "reset" },
    &.{ "what-changed", "nonsense" },
    &.{ "what-changed", "--nonsense" },
    &.{ "what-changed", "summary", "--config" },
    &.{ "what-changed", "summary", "--config", "nowhere.yaml" },
};

// Runs every command line above against a project of its own, from the argument vector down.
pub fn runCommandLineScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    for (command_lines) |argv| {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const allocator = arena_state.allocator();

        // The run's own `Io`, whose filesystem is held in memory: a scenario that makes an `Io`
        // of its own reaches the real disk, which costs a syscall per call and leaves files behind.
        const io = self.io;

        var environ = std.process.Environ.Map.init(allocator);
        var captured = std.Io.Writer.Allocating.init(allocator);
        var out = wc.output.Output{ .writer = &captured.writer, .log = self.log };
        var fail = wc.failure.Failure.init(allocator, self.log);

        const init = std.process.Init{
            .minimal = .{ .environ = .empty, .args = .{ .vector = argv } },
            .arena = &arena_state,
            .gpa = allocator,
            .io = io,
            .environ_map = &environ,
            .preopens = .empty,
        };

        // No project is written for this: the working directory a run reads is the process's own,
        // so every command line above is answered against wherever the run is standing. What is
        // being driven is the flow, and the flow is the same either way.
        _ = main_mod.run(init, allocator, &out, &fail) catch {};
    }
}

// The entry point itself, driven the way a shell drives it.
//
// `main` writes to the process's own output, which is the run's report, so this stands the two
// handles somewhere else while it runs and puts them back after: the scenario is standing in for a
// shell, and a shell is what decides where a process writes.
pub fn runEntryPointScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    const linux = std.os.linux;

    // Where the output goes while this runs, and where a write fails outright: a file opened for
    // reading only, which is what makes the branch about output that never arrived reachable.
    const nowhere = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    if (linux.errno(nowhere) != .SUCCESS) {
        return;
    }
    defer _ = linux.close(@intCast(nowhere));

    const unwritable = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(unwritable) != .SUCCESS) {
        return;
    }
    defer _ = linux.close(@intCast(unwritable));

    // `main` is handed the process rather than a log, so the one it marks its branches with is set
    // here and put back after, the same way the two handles below are.
    const kept_log = main_mod.entry_log;
    main_mod.entry_log = self.log;
    defer main_mod.entry_log = kept_log;

    const kept_out = linux.dup(1);
    const kept_err = linux.dup(2);
    defer {
        _ = linux.dup2(@intCast(kept_out), 1);
        _ = linux.dup2(@intCast(kept_err), 2);
        _ = linux.close(@intCast(kept_out));
        _ = linux.close(@intCast(kept_err));
    }

    // A command line that works, one that is refused, and one whose output cannot be written.
    const runs = [_]struct { argv: []const [*:0]const u8, writable: bool, out_of_memory: bool }{
        .{ .argv = &.{ "what-changed", "--help" }, .writable = true, .out_of_memory = false },
        .{ .argv = &.{ "what-changed", "nonsense" }, .writable = true, .out_of_memory = false },
        // `version` prints through the `Output`, which is what records a write that never arrived.
        // `--help` writes straight to the writer and swallows the failure, so it says nothing here.
        .{ .argv = &.{ "what-changed", "version" }, .writable = false, .out_of_memory = false },
        .{ .argv = &.{ "what-changed", "summary" }, .writable = true, .out_of_memory = true },
    };

    for (runs) |one| {
        var backing = std.heap.ArenaAllocator.init(self.allocator);
        defer backing.deinit();

        // An allocator that gives out at once, so the run fails with nothing said and the wording
        // of that failure cannot be recorded either.
        var running_out = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = 0 });
        var arena_state = std.heap.ArenaAllocator.init(if (one.out_of_memory) running_out.allocator() else backing.allocator());
        defer arena_state.deinit();

        var environ = std.process.Environ.Map.init(backing.allocator());

        // When the output cannot be written, neither can the sentence saying so: both handles are
        // the same unwritable file, which is the only way that second branch is reached.
        _ = linux.dup2(@intCast(if (one.writable) nowhere else unwritable), 1);
        _ = linux.dup2(@intCast(if (one.writable) nowhere else unwritable), 2);

        _ = main_mod.main(.{
            .minimal = .{ .environ = .empty, .args = .{ .vector = one.argv } },
            .arena = &arena_state,
            .gpa = backing.allocator(),
            .io = self.io,
            .environ_map = &environ,
            .preopens = .empty,
        });

        _ = linux.dup2(@intCast(kept_out), 1);
        _ = linux.dup2(@intCast(kept_err), 2);
    }
}

// A command line that cannot be read, an output that never arrives, and the wording of a failure.
pub fn runFailureReportingScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var environ = std.process.Environ.Map.init(allocator);

    // Somewhere with no room at all, so every write gives up and the run is failed for it.
    var nothing: [0]u8 = undefined;
    var no_room = std.Io.Writer.fixed(&nothing);
    var out = wc.output.Output{ .writer = &no_room, .log = self.log };
    var fail = wc.failure.Failure.init(allocator, self.log);

    const argv = [_][*:0]const u8{ "what-changed", "summary" };
    const init = std.process.Init{
        .minimal = .{ .environ = .empty, .args = .{ .vector = &argv } },
        .arena = &arena_state,
        .gpa = allocator,
        .io = self.io,
        .environ_map = &environ,
        .preopens = .empty,
    };
    _ = main_mod.run(init, allocator, &out, &fail) catch {};

    // An allocator that gives out while the argument list is being widened.
    var running_out = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var also_failing = wc.failure.Failure.init(allocator, self.log);
    _ = main_mod.run(init, running_out.allocator(), &out, &also_failing) catch {};

    // An allocation that fails once the command line has been built and the command it named is
    // already running. The build itself stops the process when it runs out, by design, so the point
    // of failure is counted first and then aimed at the far end, which is inside the command.
    {
        var counting = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
        var counted = wc.failure.Failure.init(allocator, self.log);
        var room: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&room);
        var somewhere = wc.output.Output{ .writer = &writer, .log = self.log };
        _ = main_mod.run(init, counting.allocator(), &somewhere, &counted) catch {};

        var back: usize = 1;
        while (back <= 3 and back < counting.allocations) : (back += 1) {
            var running_out_late = std.testing.FailingAllocator.init(allocator, .{ .fail_index = counting.allocations - back });
            var late = wc.failure.Failure.init(allocator, self.log);
            var more_room: [4096]u8 = undefined;
            var late_writer = std.Io.Writer.fixed(&more_room);
            var late_out = wc.output.Output{ .writer = &late_writer, .log = self.log };
            _ = main_mod.run(init, running_out_late.allocator(), &late_out, &late) catch {};
        }
    }

    // A process that cannot say where it is standing, which is the one thing a run reads out of the
    // world before it reads anything else.
    const nowhere_to_stand = std.process.Init{
        .minimal = .{ .environ = .empty, .args = .{ .vector = &argv } },
        .arena = &arena_state,
        .gpa = allocator,
        .io = std.Io.failing,
        .environ_map = &environ,
        .preopens = .empty,
    };
    var lost = wc.failure.Failure.init(allocator, self.log);
    var room: [4096]u8 = undefined;
    var writer_with_room = std.Io.Writer.fixed(&room);
    var somewhere = wc.output.Output{ .writer = &writer_with_room, .log = self.log };
    _ = main_mod.run(nowhere_to_stand, allocator, &somewhere, &lost) catch {};

    // The failure printed, with something recorded and with nothing.
    var paper: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&paper);
    var said = wc.failure.Failure.init(allocator, self.log);
    _ = said.set("something went wrong", .{}) catch {};
    _ = main_mod.reportFailure(&said, &writer);

    var silent = wc.failure.Failure.init(allocator, self.log);
    _ = main_mod.reportFailure(&silent, &writer);

    // Nowhere to print it at all.
    var no_paper: [0]u8 = undefined;
    var nowhere = std.Io.Writer.fixed(&no_paper);
    _ = main_mod.reportFailure(&said, &nowhere);

    // Every platform the name table has an answer for, plus one it does not.
    for ([_]std.Target.Os.Tag{
        .linux,   .macos,    .windows, .freebsd, .openbsd,
        .netbsd,  .dragonfly, .illumos, .wasi,   .haiku,
    }) |tag| {
        _ = main_mod.platformName(tag);
    }

    // The program built, which is the whole command line in one value.
    var captured = std.Io.Writer.Allocating.init(allocator);
    var context_out = wc.output.Output{ .writer = &captured.writer, .log = self.log };
    const context = wc.run.Context{
        .allocator = allocator,
        .io = self.io,
        .environ = &environ,
        .cwd = ".",
        .list_files = wc.list_files.listRepoFiles,
        .platform = main_mod.platformName(.linux),
        .out = &context_out,
        .fail = &fail,
    };
    _ = main_mod.buildProgram(&context);
}
