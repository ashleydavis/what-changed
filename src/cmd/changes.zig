//
// The `changes` command: the changed files as a flat list, without sorting them into targets.
//

const std = @import("std");
const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;

//
// Prints every file that differs from the baseline.
//
pub fn changesCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.report(context, .{ .options = options, .mode = .files });
}

//
// Builds the `changes` command.
//
pub fn buildChangesCommand(context: *const Context) *Command {
    return Command.init(context.allocator, "changes")
        .description("List the files that have changed since the baseline, as a flat list.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, action);
}

fn action(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try changesCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

const testing = std.testing;
const harness = @import("harness.zig");

const ONE_TARGET_CONFIG = "targets:\n  - name: unit\n    paths:\n      - src\n";

test "changesCommand lists the changes without grouping them" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try wc.run.runBaseline(&context, .{}, &.{});
    try scenario.write("src/a.ts", "edited");
    scenario.clear();

    try testing.expectEqual(@as(u8, 0), try changesCommand(&context, .{}));
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "Changed since the baseline:") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "src/a.ts") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "unit:") == null);
}

test "changesCommand honours --output" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try changesCommand(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"changed\"") != null);
}

test "buildChangesCommand declares the command the way the TypeScript does" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = buildChangesCommand(&context);

    try testing.expectEqualStrings("changes", command.command_name);
    try testing.expect(command.findOption("--config") != null);
    try testing.expectEqualStrings("text", command.findOption("--output").?.default_value.?);
}
