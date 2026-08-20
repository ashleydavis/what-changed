const std = @import("std");
const wc = @import("what-changed");
const changes = @import("changes.zig");
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

    try testing.expectEqual(@as(u8, 0), try changes.changesCommand(&context, .{}));
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "Changed since the baseline:") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "src/a.ts") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "unit:") == null);
}

test "changesCommand honours --output" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try changes.changesCommand(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"changed\"") != null);
}

test "buildChangesCommand declares the options and help the command line promises" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = changes.buildChangesCommand(&context);

    try testing.expectEqualStrings("changes", command.command_name);
    try testing.expect(command.findOption("--config") != null);
    try testing.expectEqualStrings("text", command.findOption("--output").?.default_value.?);
}
