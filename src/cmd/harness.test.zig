const std = @import("std");
const harness = @import("harness.zig");
const wc = @import("what-changed");
const Failure = wc.failure.Failure;
const testing = std.testing;

test "a scenario gives each test its own empty project" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try testing.expectEqualStrings("", scenario.printed());
    try testing.expect(!scenario.temporary.has("what-changed.yaml"));
}

test "project writes the config and the files, and the lister reports them" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{ .{ "src/a.ts", "one" }, .{ "src/b.ts", "two" } });

    try testing.expect(scenario.temporary.has("what-changed.yaml"));
    try testing.expect(scenario.temporary.has("src/a.ts"));

    var fail = Failure.init(scenario.allocator());
    const listed = try harness.listFromScenario(scenario.io(), &scenario.environ, scenario.allocator(), scenario.temporary.path, &fail);
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("src/a.ts", listed[0]);
}

test "clear forgets what was printed" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    scenario.out.line("something", .{});
    try testing.expectEqualStrings("something\n", scenario.printed());

    scenario.clear();
    try testing.expectEqualStrings("", scenario.printed());
}

test "the context points at the throwaway project" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    try testing.expectEqualStrings(scenario.temporary.path, context.cwd);
    try testing.expectEqualStrings("linux", context.platform);
    try testing.expectEqualStrings("darwin", scenario.contextOn("darwin").platform);
}
