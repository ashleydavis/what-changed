const std = @import("std");
const commander = @import("commander.zig");
const testing = std.testing;

//
// What the test actions record, so a test can see what reached them.
//
const Recorder = struct {
    ran: bool = false,
    args: []const []const u8 = &.{},
    config: ?[]const u8 = null,
    output: ?[]const u8 = null,
    fail: bool = false,
};

//
// A test action: records what it was given, the way a real one reads its options.
//
fn recordAction(invocation: *commander.Invocation) anyerror!void {
    const recorder: *Recorder = @constCast(@ptrCast(@alignCast(invocation.context)));
    recorder.ran = true;
    recorder.args = invocation.args;
    recorder.config = invocation.option("config");
    recorder.output = invocation.option("output");
    if (recorder.fail) return error.ActionFailed;
    invocation.exit_code = 0;
}

//
// Builds a program shaped like the tool's own, for the tests below.
//
fn buildTestProgram(allocator: std.mem.Allocator, recorder: *Recorder) !*commander.Command {
    const root = commander.Command.init(allocator, "what-changed");
    _ = root.description("Reports which files have changed.")
        .helpOption("--help", "Print this text.")
        .version("dev", "-v, --version", "Print the version.")
        .enablePositionalOptions();

    const summary = commander.Command.init(allocator, "summary");
    _ = summary.description("Show the changed files grouped under the targets they fall under.")
        .option("--config <path>", "The config file to read.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(recorder, recordAction);
    root.addCommand(summary);

    const baseline = commander.Command.init(allocator, "baseline");
    _ = baseline.description("Manage the recorded baseline.");
    _ = baseline.command("capture")
        .alias("update")
        .alias("set")
        .description("Record what the named targets watch as their baseline.")
        .argument("[target names...]", "The targets to capture.")
        .option("--config <path>", "The config file to read.", null)
        .action(recorder, recordAction);
    root.addCommand(baseline);

    const targets = commander.Command.init(allocator, "targets");
    _ = targets.description("Print the affected target names.")
        .option("--output <format>", "How to render the result.", "text")
        .action(recorder, recordAction);
    _ = targets.enablePositionalOptions();
    _ = targets.command("list")
        .description("Print every target that can run on this platform.")
        .option("--output <format>", "How to render the result.", "text")
        .action(recorder, recordAction);
    root.addCommand(targets);

    return root;
}

//
// Runs a command line against that program and hands back what happened.
//
fn runLine(allocator: std.mem.Allocator, recorder: *Recorder, argv: []const []const u8, captured: *std.Io.Writer.Allocating) !commander.Program {
    const root = try buildTestProgram(allocator, recorder);
    var runner = commander.Program{ .out = &captured.writer };
    commander.parse(&runner, root, argv) catch |err| switch (err) {
        error.Displayed, error.Refused => {},
        else => return err,
    };
    return runner;
}

test "Option.name strips the dashes and the placeholder" {
    try testing.expectEqualStrings("config", (commander.Option{ .flags = "--config <path>", .description = "", .default_value = null }).name());
    try testing.expectEqualStrings("output", (commander.Option{ .flags = "--output <format>", .description = "", .default_value = null }).name());
    try testing.expectEqualStrings("force", (commander.Option{ .flags = "--force", .description = "", .default_value = null }).name());
}

test "isOption tells an option from a value" {
    try testing.expect(commander.isOption("--config"));
    try testing.expect(commander.isOption("-v"));
    try testing.expect(!commander.isOption("-"));
    try testing.expect(!commander.isOption("summary"));
    try testing.expect(!commander.isOption(""));
}

test "isVariadic reads the ellipsis in an argument spec" {
    try testing.expect(commander.isVariadic("[target names...]"));
    try testing.expect(!commander.isVariadic("[name]"));
    try testing.expect(!commander.isVariadic("<name>"));
}

test "namedBy matches any spelling in a flag list" {
    try testing.expect(commander.namedBy("-v, --version", "-v"));
    try testing.expect(commander.namedBy("-v, --version", "--version"));
    try testing.expect(commander.namedBy("--help", "--help"));
    try testing.expect(!commander.namedBy("--help", "-h"));
}

test "matches accepts a command's name and every alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const command = commander.Command.init(arena.allocator(), "capture");
    _ = command.alias("update").alias("set");

    try testing.expect(command.matches("capture"));
    try testing.expect(command.matches("update"));
    try testing.expect(command.matches("set"));
    try testing.expect(!command.matches("reset"));
}

test "findOption finds an option by any of its spellings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const command = commander.Command.init(arena.allocator(), "summary");
    _ = command.option("--config <path>", "The config file.", null);

    try testing.expect(command.findOption("--config") != null);
    try testing.expect(command.findOption("--nope") == null);
}

test "command adds a subcommand and returns the child to chain onto" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parent = commander.Command.init(arena.allocator(), "baseline");
    const child = parent.command("capture");

    try testing.expectEqual(@as(usize, 1), parent.subcommands.items.len);
    try testing.expectEqualStrings("capture", child.command_name);
    try testing.expect(parent.findSubcommand("capture") != null);
}

test "an action runs and reads the options it was given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{ "summary", "--config", "custom.yaml" }, &captured);

    try testing.expect(recorder.ran);
    try testing.expectEqualStrings("custom.yaml", recorder.config.?);
    try testing.expectEqual(@as(u8, 0), runner.exit_code);
}

test "an option with a default arrives even when the command line is silent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{"summary"}, &captured);

    try testing.expectEqualStrings("text", recorder.output.?);
    try testing.expect(recorder.config == null);
}

test "an option reaches the subcommand it follows, not the parent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // The regression the whole positional-options rule exists for. Without it "--output" after
    // "list" resolves to the parent's copy, where the subcommand never sees it, and the request for
    // json quietly returns text.
    //
    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "targets", "list", "--output", "json" }, &captured);

    try testing.expect(recorder.ran);
    try testing.expectEqualStrings("json", recorder.output.?);
}

test "a subcommand alias reaches the same action" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for ([_][]const u8{ "capture", "update", "set" }) |word| {
        var recorder = Recorder{};
        var captured = std.Io.Writer.Allocating.init(allocator);
        _ = try runLine(allocator, &recorder, &.{ "baseline", word, "unit" }, &captured);

        try testing.expect(recorder.ran);
        try testing.expectEqualStrings("unit", recorder.args[0]);
    }
}

test "a variadic argument collects every name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "baseline", "capture", "unit", "documentation" }, &captured);

    try testing.expectEqual(@as(usize, 2), recorder.args.len);
    try testing.expectEqualStrings("documentation", recorder.args[1]);
}

test "arguments and options can be given together" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "baseline", "capture", "unit", "--config", "c.yaml" }, &captured);

    try testing.expectEqualStrings("unit", recorder.args[0]);
    try testing.expectEqualStrings("c.yaml", recorder.config.?);
}

test "-- lets an argument that starts with a dash through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "baseline", "capture", "--", "--odd-name" }, &captured);

    try testing.expectEqualStrings("--odd-name", recorder.args[0]);
}

test "an unknown option is refused in commander's words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{"--nosuchoption"}, &captured);

    try testing.expectEqualStrings("error: unknown option '--nosuchoption'", runner.message.?);
    try testing.expect(!recorder.ran);
}

test "an option with no value is refused, quoting the flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{ "summary", "--config" }, &captured);

    try testing.expectEqualStrings("error: option '--config <path>' argument missing", runner.message.?);
}

test "an unknown command is refused and named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{"badcommand"}, &captured);

    try testing.expectEqualStrings("error: unknown command 'badcommand'", runner.message.?);
}

test "an argument a command does not take is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{ "summary", "extra" }, &captured);

    try testing.expect(std.mem.startsWith(u8, runner.message.?, "error: too many arguments"));
}

test "an option a subcommand does not declare is refused rather than ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{ "baseline", "capture", "--output", "json" }, &captured);

    try testing.expectEqualStrings("error: unknown option '--output'", runner.message.?);
}

test "--help prints the help and does not run anything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{"--help"}, &captured);

    try testing.expect(std.mem.startsWith(u8, captured.written(), "Usage: what-changed"));
    try testing.expect(!recorder.ran);
}

test "--help after a command explains that command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "summary", "--help" }, &captured);

    try testing.expect(std.mem.startsWith(u8, captured.written(), "Usage: summary"));
    try testing.expect(!recorder.ran);
}

test "the program's help option can be respelled, and the default one then stops working" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // The program declares "--help" only, so "-h" is not a flag it knows.
    //
    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{"-h"}, &captured);

    try testing.expectEqualStrings("error: unknown option '-h'", runner.message.?);
}

test "--version and -v print the version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for ([_][]const u8{ "--version", "-v" }) |flag| {
        var recorder = Recorder{};
        var captured = std.Io.Writer.Allocating.init(allocator);
        _ = try runLine(allocator, &recorder, &.{flag}, &captured);

        try testing.expectEqualStrings("dev\n", captured.written());
        try testing.expect(!recorder.ran);
    }
}

test "a command with subcommands and no action of its own prints its help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{"baseline"}, &captured);

    try testing.expect(std.mem.startsWith(u8, captured.written(), "Usage: baseline"));
    try testing.expect(!recorder.ran);
}

test "an action that fails makes the parse a refusal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{ .fail = true };
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{"summary"}, &captured);

    try testing.expect(recorder.ran);
    try testing.expectEqual(@as(u8, 1), runner.exit_code);
}

test "renderHelp lays the program out in commander's shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    const root = try buildTestProgram(allocator, &recorder);
    const help = try commander.renderHelp(allocator, root);

    try testing.expect(std.mem.startsWith(u8, help, "Usage: what-changed [options] [command]\n"));
    try testing.expect(std.mem.indexOf(u8, help, "\nOptions:\n") != null);
    try testing.expect(std.mem.indexOf(u8, help, "  -v, --version      Print the version.") != null);
    try testing.expect(std.mem.indexOf(u8, help, "  --help             Print this text.") != null);
    try testing.expect(std.mem.indexOf(u8, help, "\nCommands:\n") != null);
    try testing.expect(std.mem.indexOf(u8, help, "  summary [options]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "  help [command]     display help for command") != null);
}

test "renderHelp names a subcommand's aliases and what it accepts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const baseline = commander.Command.init(allocator, "baseline");
    _ = baseline.command("capture")
        .alias("update")
        .alias("set")
        .description("Record the baseline.")
        .argument("[target names...]", "The targets.")
        .option("--config <path>", "The config file.", null);

    const help = try commander.renderHelp(allocator, baseline);
    try testing.expect(std.mem.indexOf(u8, help, "capture|update|set [options] [target names...]") != null);
}

test "renderHelp shows an option's default the way commander does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // A short description, so the default is not pushed onto the next line by the wrapping. That
    // the long form wraps is checked separately; this is about the default being shown at all.
    //
    const command = commander.Command.init(allocator, "summary");
    _ = command.option("--output <format>", "How to render.", "text");

    const help = try commander.renderHelp(allocator, command);
    try testing.expect(std.mem.indexOf(u8, help, "How to render. (default: \"text\")") != null);
}

test "renderHelp puts the extra text after everything else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const command = commander.Command.init(allocator, "capture");
    _ = command.description("Record the baseline.").addHelpText("after", "\nCapture one target only after it has passed.");

    const help = try commander.renderHelp(allocator, command);
    try testing.expect(std.mem.endsWith(u8, help, "Capture one target only after it has passed.\n"));
}

test "renderHelp wraps a long description rather than running past the width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const command = commander.Command.init(allocator, "targets");
    _ = command.description("Print the names of the targets affected by the current changes, one per line. Targets that cannot run on this platform are never named.");

    const help = try commander.renderHelp(allocator, command);
    var lines = std.mem.splitScalar(u8, help, '\n');
    while (lines.next()) |line| {
        try testing.expect(line.len <= commander.HELP_TOTAL_WIDTH);
    }
}

test "a usage line only claims what the command actually takes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bare = commander.Command.init(allocator, "bare");
    try testing.expect(std.mem.startsWith(u8, try commander.renderHelp(allocator, bare), "Usage: bare\n"));

    const with_options = commander.Command.init(allocator, "opts");
    _ = with_options.option("--config <path>", "The config file.", null);
    try testing.expect(std.mem.startsWith(u8, try commander.renderHelp(allocator, with_options), "Usage: opts [options]\n"));
}
