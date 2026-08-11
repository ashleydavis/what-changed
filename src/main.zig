const std = @import("std");
const builtin = @import("builtin");
const wc = @import("what-changed");

const commander = wc.commander;
const baseline_cmd = @import("cmd/baseline.zig");
const cache_cmd = @import("cmd/cache.zig");
const changes_cmd = @import("cmd/changes.zig");
const summary_cmd = @import("cmd/summary.zig");
const targets_cmd = @import("cmd/targets.zig");
const version_cmd = @import("cmd/version.zig");

const Failure = wc.failure.Failure;
const Output = wc.output.Output;
const Context = wc.run.Context;

//
// The entry point. It holds nothing but the command line definition and the wiring from the real
// process to the flow in lib/run.zig, so there is nothing here that a test would want to reach.
//
// Everything the flows need from the world outside them (the working directory, the file lister, the
// platform, where output goes) is gathered here and passed in. That is the whole reason the rest of
// the tool can be tested without a git repository and without touching the process's own state.
//

//
// How big a buffer stdout gets.
//
// Output is one report of at most a few thousand lines, so this holds most runs in a single write.
// It matters more than it looks: an unbuffered writer makes a syscall per line, and a report of a
// thousand changed files would then be a thousand syscalls.
//
const STDOUT_BUFFER_BYTES = 64 * 1024;

//
// The extra text under the program's own help.
//
const HELP_EXAMPLES =
    \\
    \\Examples:
    \\  what-changed summary             Show the changed files, grouped by target
    \\  what-changed changes             Show the changed files as a flat list
    \\  what-changed targets             Print the affected target names, one per line
    \\  what-changed targets list        Print every target that can run on this platform
    \\  what-changed baseline capture    Record the current tree as the baseline
    \\  what-changed baseline reset      Forget the baseline
    \\  what-changed baseline show       Show what is recorded
    \\  what-changed cache capture       Refresh the file hash cache
    \\  what-changed cache reset         Empty the file hash cache
    \\  what-changed cache show          Show what is cached
    \\  what-changed version             Print the version and which build this is
    \\
    \\Resources:
    \\  📖 https://github.com/ashleydavis/what-changed
;

//
// Builds the whole command line: the program, its options, and every subcommand.
//
// The same definition as the TypeScript's `main`, in the same order, so the two can be read side by
// side.
//
pub fn buildProgram(context: *const Context) *commander.Command {
    const program = commander.program(context.allocator)
        .name("what-changed")
        .description("Reports which files have changed since the recorded baseline, and which of the project's targets those changes fall under.")
        //
        // --config belongs to each subcommand, not here. Declaring it in both places makes the
        // parser resolve it to this one, where nothing reads it, and the value silently never
        // reaches the command that was asked for.
        //
        .helpOption("--help", "Print this text.")
        .version(wc.version.version, "-v, --version", "Print the version.")
        .addHelpText("after", HELP_EXAMPLES)
        .enablePositionalOptions(); // An option after a subcommand name belongs to that subcommand.

    program.addCommand(summary_cmd.buildSummaryCommand(context));
    program.addCommand(changes_cmd.buildChangesCommand(context));
    program.addCommand(targets_cmd.buildTargetsCommand(context));
    program.addCommand(baseline_cmd.baselineCommand(context));
    program.addCommand(cache_cmd.cacheCommand(context));
    program.addCommand(version_cmd.buildVersionCommand(context));

    return program;
}

pub fn main(init: std.process.Init) u8 {
    //
    // One arena for the whole run, freed on the way out.
    //
    // Every allocation this tool makes is needed until the run ends and none of it is needed after,
    // which is exactly the case an arena is for. It also means no function below has to think about
    // freeing anything, and no failure path can leak.
    //
    const allocator = init.arena.allocator();

    //
    // Every filesystem call in this project goes through the one the runtime provided, rather than
    // each part of the tool creating its own.
    //
    wc.files.setIo(init.io);

    var stdout_buffer: [STDOUT_BUFFER_BYTES]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var out = Output{ .writer = &stdout_file.interface };

    var fail = Failure.init(allocator);

    const exit_code = run(init, allocator, &out, &fail) catch |err| blk: {
        if (err == error.OutOfMemory and fail.message == null) {
            _ = fail.set("what-changed ran out of memory.", .{}) catch {};
        }

        var stderr_buffer: [512]u8 = undefined;
        var stderr_file = std.Io.File.stderr().writer(init.io, &stderr_buffer);
        const code = reportFailure(&fail, &stderr_file.interface);
        stderr_file.interface.flush() catch {};
        break :blk code;
    };

    //
    // Flushed before exiting, or a buffered report is thrown away when the process ends. The failure
    // is noticed rather than ignored: output that never arrived is a failed run, however well the
    // work behind it went.
    //
    stdout_file.interface.flush() catch {
        out.failed = true;
    };
    if (out.failed) {
        var complaint: [128]u8 = undefined;
        var stderr_file = std.Io.File.stderr().writer(init.io, &complaint);
        stderr_file.interface.writeAll("what-changed could not write its output.\n") catch {};
        stderr_file.interface.flush() catch {};
        return 1;
    }

    return exit_code;
}

//
// Prints a failure the way the TypeScript's catch does, and gives the exit code to use.
//
// Takes the writer rather than reaching for stderr itself, so a test can read what it wrote instead
// of the message landing in the middle of the test run's own output.
//
fn reportFailure(fail: *Failure, writer: *std.Io.Writer) u8 {
    writer.print("{s}\n", .{fail.text()}) catch {};
    return 1;
}

//
// Builds the command line and runs whatever it asked for.
//
fn run(init: std.process.Init, allocator: std.mem.Allocator, out: *Output, fail: *Failure) wc.failure.Error!u8 {
    const argv = init.minimal.args.toSlice(allocator) catch |err| {
        return fail.set("Failed to read the command line: {s}", .{@errorName(err)});
    };

    //
    // argv[0] is the program's own path, which nothing here reads.
    //
    const arguments = if (argv.len > 1) argv[1..] else &[_][:0]const u8{};

    var widened: std.ArrayList([]const u8) = .empty;
    for (arguments) |argument| {
        try widened.append(allocator, argument);
    }

    const cwd = std.process.currentPathAlloc(init.io, allocator) catch |err| {
        return fail.set("Failed to read the working directory: {s}", .{wc.files.describeError(err)});
    };

    const context = try allocator.create(Context);
    context.* = .{
        .allocator = allocator,
        .cwd = cwd,
        .list_files = wc.list_files.listRepoFiles,
        .platform = platformName(),
        .out = out,
        .fail = fail,
    };

    const program = buildProgram(context);

    //
    // With no subcommand there is nothing to do, so the usage text is what the user wants. Doing a
    // report instead would mean the one invocation someone tries first has a side effect they did
    // not ask for and cannot see coming.
    //
    if (widened.items.len == 0) {
        try commander.writeHelp(out.writer, program, allocator);
        return 0;
    }

    var runner = commander.Program{ .out = out.writer };
    commander.parse(&runner, program, widened.items) catch |err| switch (err) {
        //
        // Help and the version printed successfully, which is not a failure.
        //
        error.Displayed => return 0,

        //
        // Either the command line was wrong, in which case the parser left the message, or an action
        // failed, in which case it left one of its own.
        //
        error.Refused => {
            if (runner.message) |message| {
                _ = fail.set("{s}", .{message}) catch {};
            }
            return error.Failed;
        },

        error.OutOfMemory => return error.OutOfMemory,
    };

    return runner.exit_code;
}

//
// What this platform is called in a config's "platforms" list.
//
// The names are Node's, from `process.platform`, rather than Zig's own. A config has to mean the
// same thing to both ports, and the TypeScript is what the existing configs were written against.
//
pub fn platformName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "win32",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        .dragonfly => "dragonfly",
        .illumos => "sunos",
        else => @tagName(builtin.os.tag),
    };
}

const testing = std.testing;
const harness = @import("cmd/harness.zig");

test "platformName uses the names a config is written against" {
    //
    // Node's names, not Zig's: "darwin" rather than "macos", "win32" rather than "windows". A config
    // saying `platforms: [darwin]` has to mean the same thing to both ports.
    //
    const name = platformName();
    try testing.expect(name.len > 0);
    try testing.expect(std.mem.indexOfScalar(u8, name, ' ') == null);

    switch (builtin.os.tag) {
        .linux => try testing.expectEqualStrings("linux", name),
        .macos => try testing.expectEqualStrings("darwin", name),
        .windows => try testing.expectEqualStrings("win32", name),
        else => {},
    }
}

test "reportFailure prints the message and exits non-zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    _ = fail.set("what-changed config field \"targets\" must be a non-empty array, got []", .{}) catch {};

    var captured = std.Io.Writer.Allocating.init(arena.allocator());
    try testing.expectEqual(@as(u8, 1), reportFailure(&fail, &captured.writer));
    try testing.expectEqualStrings("what-changed config field \"targets\" must be a non-empty array, got []\n", captured.written());
}

test "reportFailure says something even when nothing was recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    var captured = std.Io.Writer.Allocating.init(arena.allocator());

    try testing.expectEqual(@as(u8, 1), reportFailure(&fail, &captured.writer));
    try testing.expect(captured.written().len > 1);
}

test "buildProgram declares every command the tool has" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const program = buildProgram(&context);

    for ([_][]const u8{ "summary", "changes", "targets", "baseline", "cache", "version" }) |name| {
        try testing.expect(program.findSubcommand(name) != null);
    }

    //
    // The program declares no --config of its own. Declaring it in both places is what made the
    // TypeScript resolve it to the program's copy, where nothing read it.
    //
    try testing.expect(program.findOption("--config") == null);
    try testing.expect(program.positional_options);
}

test "the program help names every command and the usage line a script looks for" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const help = try commander.renderHelp(scenario.allocator(), buildProgram(&context));

    try testing.expect(std.mem.startsWith(u8, help, "Usage: what-changed [options] [command]"));
    for ([_][]const u8{ "summary", "changes", "targets", "baseline", "cache", "version" }) |name| {
        try testing.expect(std.mem.indexOf(u8, help, name) != null);
    }
    try testing.expect(std.mem.indexOf(u8, help, "what-changed targets list") != null);

    //
    // Printing usage rather than reporting is the point of the no-command case: the first thing
    // someone tries must not have a side effect they did not ask for.
    //
    try testing.expect(std.mem.indexOf(u8, help, "Changed since the baseline") == null);
}

test "the program's help option is --help, and -h is not one of its spellings" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const program = buildProgram(&context);

    try testing.expect(program.isHelpFlag("--help"));
    try testing.expect(!program.isHelpFlag("-h"));
    try testing.expect(program.isVersionFlag("-v"));
    try testing.expect(program.isVersionFlag("--version"));
}

test "an unknown option is refused through the whole program" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var runner = commander.Program{ .out = &captured.writer };

    try testing.expectError(error.Refused, commander.parse(&runner, buildProgram(&context), &.{"--nosuchoption"}));
    try testing.expectEqualStrings("error: unknown option '--nosuchoption'", runner.message.?);
}

test "--config reaches the subcommand it follows" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});
    try scenario.write("other.yaml", "targets:\n  - name: other\n    paths:\n      - src\n");

    const context = scenario.context();
    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var runner = commander.Program{ .out = &captured.writer };

    try commander.parse(&runner, buildProgram(&context), &.{ "targets", "--config", "other.yaml" });
    try testing.expectEqualStrings("other\n", scenario.printed());
}

test "an action's failure comes back as a refusal with its own message" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var runner = commander.Program{ .out = &captured.writer };

    try testing.expectError(error.Refused, commander.parse(&runner, buildProgram(&context), &.{ "summary", "--output", "xml" }));
    try testing.expect(std.mem.indexOf(u8, scenario.fail.text(), "Unknown --output format") != null);
}
