const std = @import("std");
const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;
const Failure = wc.failure.Failure;

//
// The `baseline` command and its subcommands.
//
// The baseline is the reference point every report is measured against. It is deliberately not part
// of the file hash cache: losing the cache costs a slow run, losing this changes the answer.
//

//
// Resolves the baseline file the config points at.
//
pub fn resolveBaselinePath(context: *const Context, options: ReportOptions) wc.failure.Error![]const u8 {
    const config_path = try wc.config.resolveConfigPath(context.allocator, options.config, context.cwd, context.fail);
    const root_dir = wc.files.dirName(config_path);
    const config = try wc.config.loadConfig(context.allocator, config_path, context.fail);
    return wc.files.resolvePath(context.allocator, root_dir, config.baseline_path);
}

//
// Records what the named targets currently watch as their baseline. With no names, every target.
//
pub fn baselineSetCommand(context: *const Context, options: ReportOptions, target_names: []const []const u8) wc.failure.Error!u8 {
    return wc.run.runBaseline(context, options, target_names);
}

//
// Forgets the baseline, so the next report treats every file as new.
//
pub fn baselineResetCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    const baseline_path = try resolveBaselinePath(context, options);

    wc.baseline_store.baselineReset(context.allocator, baseline_path) catch |err| {
        return context.fail.set("Failed to reset the baseline at \"{s}\": {s}", .{ baseline_path, wc.files.describeError(err) });
    };

    context.out.line("Baseline reset. The next report will treat every file as new.", .{});
    return 0;
}

//
// Says where the baseline is kept and how much is in it.
//
pub fn baselineShowCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    const allocator = context.allocator;

    const baseline_path = try resolveBaselinePath(context, options);
    var baseline = try wc.baseline_store.loadBaseline(allocator, baseline_path);
    const format = try wc.output.parseOutputFormat(options.output, context.fail);

    const target_names = try allocator.dupe([]const u8, baseline.targets.keys());
    std.mem.sort([]const u8, target_names, {}, wc.file_hashes.lessThanPath);

    if (format != .text) {
        var targets = wc.value.newArray(allocator);
        for (target_names) |name| {
            var entry = wc.value.newObject(allocator);
            try entry.put(allocator, "name", wc.value.str(name));
            try entry.put(allocator, "fileCount", wc.value.int(@intCast(baseline.targets.get(name).?.count())));
            try targets.append(.{ .object = entry });
        }

        var object = wc.value.newObject(allocator);
        try object.put(allocator, "baselinePath", wc.value.str(baseline_path));
        try object.put(allocator, "targets", .{ .array = targets });
        try wc.output.printStructured(allocator, context.out, .{ .object = object }, format);
        return 0;
    }

    context.out.line("Baseline file: {s}", .{baseline_path});
    if (target_names.len == 0) {
        context.out.line("No target has been captured yet, so everything counts as changed.", .{});
        return 0;
    }

    //
    // One line per target rather than one per file. The file lists are per target and overlap
    // heavily, so printing them all would be thousands of lines saying the same thing repeatedly.
    //
    context.out.line("{d} target(s) captured:", .{target_names.len});
    for (target_names) |name| {
        context.out.line("  {s}: {d} file(s)", .{ name, baseline.targets.get(name).?.count() });
    }
    return 0;
}

//
// Builds the `baseline` command.
//
pub fn baselineCommand(context: *const Context) *Command {
    const cmd = Command.init(context.allocator, "baseline")
        .description("Manage the recorded baseline that changes are measured against.");

    _ = cmd.command("capture")
        .alias("update")
        .alias("set")
        .description("Record what the named targets watch as their baseline. With no names, every target.")
        .argument("[target names...]", "The targets to capture. With none, every target in the config is captured.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .addHelpText("after",
        \\
        \\Capture one target only after that target has actually passed. Capturing a target says "this suite
        \\passed against these files", so capturing one that did not run marks it as up to date when it is not.
    )
        .action(context, captureAction);

    _ = cmd.command("reset")
        .description("Forget the baseline, so the next report treats every file as new.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .action(context, resetAction);

    _ = cmd.command("show")
        .description("Show where the baseline is kept and what is recorded in it.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, showAction);

    return cmd;
}

fn captureAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try baselineSetCommand(context, .{ .config = invocation.option("config") }, invocation.args);
}

fn resetAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try baselineResetCommand(context, .{ .config = invocation.option("config") });
}

fn showAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try baselineShowCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

const testing = std.testing;
const harness = @import("harness.zig");

test "resolveBaselinePath resolves the config's path against the config's directory" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "baselinePath: recorded/base.json\ntargets:\n  - name: unit\n    paths:\n      - src\n");

    const context = scenario.context();
    const path = try resolveBaselinePath(&context, .{});
    try testing.expect(std.mem.endsWith(u8, path, "/recorded/base.json"));
    try testing.expect(std.mem.startsWith(u8, path, scenario.temporary.path));
}

test "resolveBaselinePath falls back to the default location" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "targets:\n  - name: unit\n    paths:\n      - src\n");

    const context = scenario.context();
    try testing.expect(std.mem.endsWith(u8, try resolveBaselinePath(&context, .{}), "/.what-changed/baseline.json"));
}

test "baselineShowCommand says nothing is captured when nothing is" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "targets:\n  - name: unit\n    paths:\n      - src\n");

    const context = scenario.context();
    try testing.expectEqual(@as(u8, 0), try baselineShowCommand(&context, .{}));
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "Baseline file: ") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "No target has been captured yet") != null);
}

test "baselineShowCommand counts each captured target, in name order" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n  - name: docs\n    paths:\n      - documentation\n", &.{
        .{ "src/a.ts", "one" },
        .{ "src/b.ts", "two" },
        .{ "documentation/g.txt", "docs" },
    });

    const context = scenario.context();
    _ = try baselineSetCommand(&context, .{}, &.{});
    scenario.clear();

    _ = try baselineShowCommand(&context, .{});
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "2 target(s) captured:") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "  docs: 1 file(s)") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "  unit: 2 file(s)") != null);
}

test "baselineShowCommand renders json when asked" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try baselineSetCommand(&context, .{}, &.{});
    scenario.clear();

    _ = try baselineShowCommand(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"baselinePath\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"name\": \"unit\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"fileCount\": 1") != null);
}

test "baselineResetCommand empties the baseline and says so" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try baselineSetCommand(&context, .{}, &.{});
    scenario.clear();

    try testing.expectEqual(@as(u8, 0), try baselineResetCommand(&context, .{}));
    try testing.expectEqualStrings("Baseline reset. The next report will treat every file as new.\n", scenario.printed());

    scenario.clear();
    _ = try baselineShowCommand(&context, .{});
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "No target has been captured yet") != null);
}

test "baselineResetCommand leaves the file behind rather than deleting it" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try baselineResetCommand(&context, .{});

    //
    // Written rather than deleted, for the same reason the cache reset writes: a delete of a
    // computed path can take something real with it if the path is ever wrong.
    //
    try testing.expect(scenario.temporary.has(".what-changed/baseline.json"));
}

test "baselineSetCommand hands the names through to the run" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n  - name: docs\n    paths:\n      - documentation\n", &.{
        .{ "src/a.ts", "one" },
        .{ "documentation/g.txt", "docs" },
    });

    const context = scenario.context();
    _ = try baselineSetCommand(&context, .{}, &.{"unit"});
    try testing.expectEqualStrings("Captured the baseline for 1 target(s): unit.\n", scenario.printed());
}

test "baselineCommand declares capture, reset and show, with capture's aliases" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = baselineCommand(&context);

    try testing.expectEqualStrings("baseline", command.command_name);
    try testing.expect(command.findSubcommand("capture") != null);
    try testing.expect(command.findSubcommand("update") != null);
    try testing.expect(command.findSubcommand("set") != null);
    try testing.expect(command.findSubcommand("reset") != null);
    try testing.expect(command.findSubcommand("show") != null);

    //
    // Capture takes names and a config, and deliberately no --output: it prints one line of prose.
    //
    const capture = command.findSubcommand("capture").?;
    try testing.expect(capture.argument_spec != null);
    try testing.expect(capture.findOption("--config") != null);
    try testing.expect(capture.findOption("--output") == null);
}

test "baseline capture takes its target names through the parser" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n  - name: docs\n    paths:\n      - documentation\n", &.{
        .{ "src/a.ts", "one" },
        .{ "documentation/g.txt", "docs" },
    });

    const context = scenario.context();
    const command = baselineCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{ "capture", "unit" });

    try testing.expectEqualStrings("Captured the baseline for 1 target(s): unit.\n", scenario.printed());
}

test "the capture help warns against capturing a suite that did not run" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = baselineCommand(&context);
    const help = try commander.renderHelp(scenario.allocator(), command.findSubcommand("capture").?);

    try testing.expect(std.mem.indexOf(u8, help, "only after that target has actually passed") != null);
}
