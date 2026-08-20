const std = @import("std");
const wc = @import("what-changed");
const targets = @import("targets.zig");
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

    try testing.expectEqual(@as(u8, 0), try targets.targetsCommand(&context, .{}));
    try testing.expectEqualStrings("unit\n", scenario.printed());
}

test "targetsListCommand names every runnable target whatever has changed" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try wc.run.runBaseline(&context, .{}, &.{});

    scenario.clear();
    _ = try targets.targetsCommand(&context, .{});
    try testing.expectEqualStrings("", scenario.printed());

    scenario.clear();
    try testing.expectEqual(@as(u8, 0), try targets.targetsListCommand(&context, .{}));
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
    _ = try targets.targetsListCommand(&context, .{});
    try testing.expectEqualStrings("here-only\n", scenario.printed());
}

test "buildTargetsCommand declares the list subcommand and turns positional options on" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = targets.buildTargetsCommand(&context);

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
    const command = targets.buildTargetsCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{ "list", "--output", "json" });

    //
    // The regression guard, driven through the parser rather than by calling the action directly:
    // the request for json has to reach the subcommand.
    //
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"targets\"") != null);
}
