const std = @import("std");
const wc = @import("what-changed");
const summary = @import("summary.zig");
const commander = wc.commander;
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

    try testing.expectEqual(@as(u8, 0), try summary.summaryCommand(&context, .{}));
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "unit: 1 changed") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "documentation: unchanged") != null);
}

test "summaryCommand honours --output" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try summary.summaryCommand(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"appliesHere\"") != null);
}

test "buildSummaryCommand declares the options and help the command line promises" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = summary.buildSummaryCommand(&context);

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
    const command = summary.buildSummaryCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{});

    try testing.expectEqual(@as(u8, 0), program.exit_code);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "No baseline recorded yet") != null);
}
