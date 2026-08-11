//
// The `targets` command: the names of the targets affected by the current changes, and `targets
// list`, the names of every target that could run here at all.
//

const std = @import("std");
const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;

//
// Prints one affected target name per line, and nothing else, so a script can read the list without
// picking it out of prose.
//
pub fn targetsCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.report(context, .{ .options = options, .mode = .targets });
}

//
// Prints every target the config declares that can run on this platform, whatever has changed.
//
// This is the list a script wants when it is running everything rather than only what changed.
// Taking it from here rather than keeping its own copy is what stops that path from asking for a
// target the machine has no toolchain for.
//
pub fn targetsListCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.listTargets(context, options);
}

//
// Builds the `targets` command and its `list` subcommand.
//
pub fn buildTargetsCommand(context: *const Context) *Command {
    const cmd = Command.init(context.allocator, "targets")
        .description("Print the names of the targets affected by the current changes, one per line. Targets that cannot run on this platform are never named.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, action);

    //
    // This command has both its own options and a subcommand declaring the same option names.
    // Without positional options "--output" after "list" resolves to this command's copy, where the
    // subcommand never sees it: the flag is accepted, silently ignored, and the default used
    // instead. The same mistake as the --config one smoke scenario 3b guards against.
    //
    _ = cmd.enablePositionalOptions();

    _ = cmd.command("list")
        .description("Print every target that can run on this platform, one per line, regardless of what changed.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, listAction);

    return cmd;
}

fn action(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try targetsCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

fn listAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try targetsListCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

const testing = std.testing;
const harness = @import("harness.zig");

const TWO_TARGET_CONFIG =
    \\targets:
    \\  - name: unit
    \\    paths:
    \\      - src
    \\  - name: documentation
    \\    paths:
    \\      - documentation
;

test "targetsCommand names only the affected targets" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(TWO_TARGET_CONFIG, &.{
        .{ "src/a.ts", "one" },
        .{ "documentation/g.txt", "docs" },
    });

    const context = scenario.context();
    _ = try wc.run.runBaseline(&context, .{}, &.{});
    try scenario.write("src/a.ts", "edited");
    scenario.clear();

    try testing.expectEqual(@as(u8, 0), try targetsCommand(&context, .{}));
    try testing.expectEqualStrings("unit\n", scenario.printed());
}

test "targetsListCommand names every runnable target whatever has changed" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try wc.run.runBaseline(&context, .{}, &.{});

    scenario.clear();
    _ = try targetsCommand(&context, .{});
    try testing.expectEqualStrings("", scenario.printed());

    scenario.clear();
    try testing.expectEqual(@as(u8, 0), try targetsListCommand(&context, .{}));
    try testing.expectEqualStrings("unit\ndocumentation\n", scenario.printed());
}

test "targetsListCommand excludes a target that cannot run here" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(
        \\targets:
        \\  - name: here-only
        \\    paths:
        \\      - src
        \\    platforms:
        \\      - linux
        \\  - name: elsewhere-only
        \\    paths:
        \\      - src
        \\    platforms:
        \\      - darwin
    , &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try targetsListCommand(&context, .{});
    try testing.expectEqualStrings("here-only\n", scenario.printed());
}

test "buildTargetsCommand declares the list subcommand and turns positional options on" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = buildTargetsCommand(&context);

    try testing.expectEqualStrings("targets", command.command_name);
    try testing.expect(command.positional_options);
    try testing.expect(command.findSubcommand("list") != null);
    try testing.expect(command.findSubcommand("list").?.findOption("--output") != null);
}

test "--output after list reaches the subcommand rather than its parent" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    const command = buildTargetsCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{ "list", "--output", "json" });

    //
    // The regression guard, driven through the parser rather than by calling the action directly:
    // the request for json has to reach the subcommand.
    //
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"targets\"") != null);
}
