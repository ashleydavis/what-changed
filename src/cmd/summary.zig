//
// The `summary` command: the changed files grouped under the targets they fall under.
//

const std = @import("std");
const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;

//
// Prints each target with the changed files under it, then any changed file no target watches.
//
pub fn summaryCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.report(context, .{ .options = options, .mode = .summary });
}

//
// Builds the `summary` command.
//
pub fn buildSummaryCommand(context: *const Context) *Command {
    return Command.init(context.allocator, "summary")
        .description("Show the changed files grouped under the targets they fall under.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, action);
}

//
// The action, which reads its options and hands them on.
//
// A Zig function pointer captures nothing, so the context arrives through the invocation instead.
//
fn action(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try summaryCommand(context, .{
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

test "summaryCommand groups the changes under their targets" {
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

    try testing.expectEqual(@as(u8, 0), try summaryCommand(&context, .{}));
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "unit: 1 changed") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "documentation: unchanged") != null);
}

test "summaryCommand honours --output" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try summaryCommand(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"appliesHere\"") != null);
}

test "buildSummaryCommand declares the options and help the command line promises" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = buildSummaryCommand(&context);

    try testing.expectEqualStrings("summary", command.command_name);
    try testing.expect(command.findOption("--config") != null);
    try testing.expect(command.findOption("--output") != null);
    try testing.expectEqualStrings("text", command.findOption("--output").?.default_value.?);
    try testing.expect(command.action_fn != null);
}

test "the summary command runs its action through the parser" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    const command = buildSummaryCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{});

    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "No baseline recorded yet") != null);
}
