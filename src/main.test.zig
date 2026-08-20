const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");
const commander = wc.commander;
const Failure = wc.failure.Failure;
const testing = std.testing;
const harness = @import("cmd/harness.zig");
const wc = @import("what-changed");

test "platformName uses the names a config is written against" {
    //
    // Node's names, not Zig's: "darwin" rather than "macos", "win32" rather than "windows". A config
    // saying `platforms: [darwin]` has to keep meaning macOS.
    //
    const name = main.platformName();
    try testing.expect(name.len > 0);
    try testing.expect(std.mem.indexOfScalar(u8, name, ' ') == null);

    switch (builtin.os.tag) {
        .linux => try testing.expectEqualStrings("linux", name),
        .macos => try testing.expectEqualStrings("darwin", name),
        .windows => try testing.expectEqualStrings("win32", name),
        else => {},
    }
}

test "reportFailure prints the message and exits non-zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    _ = fail.set("what-changed config field \"targets\" must be a non-empty array, got []", .{}) catch {};

    var captured = std.Io.Writer.Allocating.init(arena.allocator());
    try testing.expectEqual(@as(u8, 1), main.reportFailure(&fail, &captured.writer));
    try testing.expectEqualStrings("what-changed config field \"targets\" must be a non-empty array, got []\n", captured.written());
}

test "reportFailure says something even when nothing was recorded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    var captured = std.Io.Writer.Allocating.init(arena.allocator());

    try testing.expectEqual(@as(u8, 1), main.reportFailure(&fail, &captured.writer));
    try testing.expect(captured.written().len > 1);
}

test "buildProgram declares every command the tool has" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const program = main.buildProgram(&context);

    for ([_][]const u8{ "summary", "changes", "targets", "baseline", "cache", "version" }) |name| {
        try testing.expect(program.findSubcommand(name) != null);
    }

    //
    // The program declares no --config of its own. Declaring it in both places makes the parser
    // resolve it to the program's copy, where nothing reads it.
    //
    try testing.expect(program.findOption("--config") == null);
    try testing.expect(program.positional_options);
}

test "the program help names every command and the usage line a script looks for" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const help = try commander.renderHelp(scenario.allocator(), main.buildProgram(&context));

    try testing.expect(std.mem.startsWith(u8, help, "Usage: what-changed [options] [command]"));
    for ([_][]const u8{ "summary", "changes", "targets", "baseline", "cache", "version" }) |name| {
        try testing.expect(std.mem.indexOf(u8, help, name) != null);
    }
    try testing.expect(std.mem.indexOf(u8, help, "what-changed targets list") != null);

    //
    // Printing usage rather than reporting is the point of the no-command case: the first thing
    // someone tries must not have a side effect they did not ask for.
    //
    try testing.expect(std.mem.indexOf(u8, help, "Changed since the baseline") == null);
}

test "the program's help option is --help, and -h is not one of its spellings" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const program = main.buildProgram(&context);

    try testing.expect(program.isHelpFlag("--help"));
    try testing.expect(!program.isHelpFlag("-h"));
    try testing.expect(program.isVersionFlag("-v"));
    try testing.expect(program.isVersionFlag("--version"));
}

test "an unknown option is refused through the whole program" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var runner = commander.Program{ .out = &captured.writer };

    try testing.expectError(error.Refused, commander.parse(&runner, main.buildProgram(&context), &.{"--nosuchoption"}));
    try testing.expectEqualStrings("error: unknown option '--nosuchoption'", runner.message.?);
}

test "--config reaches the subcommand it follows" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});
    try scenario.write("other.yaml", "targets:\n  - name: other\n    paths:\n      - src\n");

    const context = scenario.context();
    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var runner = commander.Program{ .out = &captured.writer };

    try commander.parse(&runner, main.buildProgram(&context), &.{ "targets", "--config", "other.yaml" });
    try testing.expectEqualStrings("other\n", scenario.printed());
}

test "an action's failure comes back as a refusal with its own message" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var runner = commander.Program{ .out = &captured.writer };

    try testing.expectError(error.Refused, commander.parse(&runner, main.buildProgram(&context), &.{ "summary", "--output", "xml" }));
    try testing.expect(std.mem.indexOf(u8, scenario.fail.text(), "Unknown --output format") != null);
}
