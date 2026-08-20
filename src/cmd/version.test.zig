const std = @import("std");
const wc = @import("what-changed");
const version = @import("version.zig");
const commander = wc.commander;
const testing = std.testing;
const harness = @import("harness.zig");

test "versionCommand names the tool and its version" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    try testing.expectEqual(@as(u8, 0), try version.versionCommand(&context, null));

    //
    // Which version, not what it is: the release workflow rewrites the value, so asserting it would
    // fail on exactly the builds that ship.
    //
    try testing.expect(std.mem.startsWith(u8, scenario.printed(), "what-changed "));
    try testing.expect(scenario.printed().len > "what-changed \n".len);
}

test "versionCommand says a working copy is not a release" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    _ = try version.versionCommand(&context, null);

    //
    // True of a build from source, which is what this test runs as. A release build says which
    // commit it came from instead, and the branch for that is exercised by reading the metadata.
    //
    if (std.mem.eql(u8, wc.version.build_metadata.commit_hash, "dev")) {
        try testing.expect(std.mem.indexOf(u8, scenario.printed(), "Built from source, not from a release.") != null);
    } else {
        try testing.expect(std.mem.indexOf(u8, scenario.printed(), "Commit: ") != null);
    }
}

test "versionCommand renders every field as json" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    _ = try version.versionCommand(&context, "json");

    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"version\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"commitHash\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"buildDate\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"isPreRelease\"") != null);
}

test "versionCommand renders yaml too" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    _ = try version.versionCommand(&context, "yaml");
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "version:") != null);

    //
    // That the field is rendered, not what it holds. A tagged release stamps it false and a
    // pre-release stamps it true, so asserting either value fails on exactly the builds that ship.
    //
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "isPreRelease:") != null);
}

test "versionCommand refuses an unknown format" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    try testing.expectError(error.Failed, version.versionCommand(&context, "xml"));
    try testing.expect(std.mem.indexOf(u8, scenario.fail.text(), "Unknown --output format") != null);
}

test "buildVersionCommand declares only --output" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = version.buildVersionCommand(&context);

    try testing.expectEqualStrings("version", command.command_name);
    try testing.expect(command.findOption("--output") != null);
    try testing.expect(command.findOption("--config") == null);
}

test "the version command runs through the parser" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = version.buildVersionCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{ "--output", "json" });

    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"commitHash\"") != null);
}
