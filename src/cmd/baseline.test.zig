const std = @import("std");
const baseline = @import("baseline.zig");
const commander = wc.commander;
const testing = std.testing;
const harness = @import("harness.zig");
const wc = @import("what-changed");

test "resolveBaselinePath resolves the config's path against the config's directory" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "baselinePath: recorded/base.json\ntargets:\n  - name: unit\n    paths:\n      - src\n");

    const context = scenario.context();
    const path = try baseline.resolveBaselinePath(&context, .{});
    try testing.expect(std.mem.endsWith(u8, path, "/recorded/base.json"));
    try testing.expect(std.mem.startsWith(u8, path, scenario.temporary.path));
}

test "resolveBaselinePath falls back to the default location" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "targets:\n  - name: unit\n    paths:\n      - src\n");

    const context = scenario.context();
    try testing.expect(std.mem.endsWith(u8, try baseline.resolveBaselinePath(&context, .{}), "/.what-changed/baseline.json"));
}

test "baselineShowCommand says nothing is captured when nothing is" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "targets:\n  - name: unit\n    paths:\n      - src\n");

    const context = scenario.context();
    try testing.expectEqual(@as(u8, 0), try baseline.baselineShowCommand(&context, .{}));
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "Baseline file: ") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "No target has been captured yet") != null);
}

test "baselineShowCommand says a damaged baseline is there rather than never captured" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "targets:\n  - name: unit\n    paths:\n      - src\n");
    try scenario.write(".what-changed/baseline.json", "{ not json");

    const context = scenario.context();
    try testing.expectEqual(@as(u8, 0), try baseline.baselineShowCommand(&context, .{}));

    //
    // The file is sitting right there, so saying nothing has ever been captured would send someone
    // looking for a capture step that already ran.
    //
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "The file is there and is not valid JSON.") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "No target has been captured yet") == null);
}

test "baselineShowCommand says a baseline holding the wrong kind of JSON is there" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "targets:\n  - name: unit\n    paths:\n      - src\n");
    try scenario.write(".what-changed/baseline.json", "[1, 2]");

    const context = scenario.context();
    _ = try baseline.baselineShowCommand(&context, .{});
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "The file is there and does not hold a JSON object.") != null);
}

test "baselineShowCommand reports the file's status in json" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "targets:\n  - name: unit\n    paths:\n      - src\n");
    try scenario.write(".what-changed/baseline.json", "{ not json");

    const context = scenario.context();
    _ = try baseline.baselineShowCommand(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"status\": \"notJson\"") != null);

    scenario.clear();

    //
    // A project that has captured nothing reports "absent", so a script can tell the two apart the
    // same way the text output does.
    //
    var fresh = try harness.Scenario.create();
    defer fresh.destroy();
    try fresh.write("what-changed.yaml", "targets:\n  - name: unit\n    paths:\n      - src\n");

    const fresh_context = fresh.context();
    _ = try baseline.baselineShowCommand(&fresh_context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, fresh.printed(), "\"status\": \"absent\"") != null);
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
    _ = try baseline.baselineSetCommand(&context, .{}, &.{});
    scenario.clear();

    _ = try baseline.baselineShowCommand(&context, .{});
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "2 target(s) captured:") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "  docs: 1 file(s)") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "  unit: 2 file(s)") != null);
}

test "baselineShowCommand renders json when asked" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try baseline.baselineSetCommand(&context, .{}, &.{});
    scenario.clear();

    _ = try baseline.baselineShowCommand(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"baselinePath\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"name\": \"unit\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"fileCount\": 1") != null);
}

test "baselineResetCommand empties the baseline and says so" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try baseline.baselineSetCommand(&context, .{}, &.{});
    scenario.clear();

    try testing.expectEqual(@as(u8, 0), try baseline.baselineResetCommand(&context, .{}));
    try testing.expectEqualStrings("Baseline reset. The next report will treat every file as new.\n", scenario.printed());

    scenario.clear();
    _ = try baseline.baselineShowCommand(&context, .{});
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "No target has been captured yet") != null);
}

test "baselineResetCommand leaves the file behind rather than deleting it" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project("targets:\n  - name: unit\n    paths:\n      - src\n", &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try baseline.baselineResetCommand(&context, .{});

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
    _ = try baseline.baselineSetCommand(&context, .{}, &.{"unit"});
    try testing.expectEqualStrings("Captured the baseline for 1 target(s): unit.\n", scenario.printed());
}

test "baselineCommand declares capture, reset and show, with capture's aliases" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = baseline.baselineCommand(&context);

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
    const command = baseline.baselineCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{ "capture", "unit" });

    try testing.expectEqualStrings("Captured the baseline for 1 target(s): unit.\n", scenario.printed());
}

test "the capture help warns against capturing a suite that did not run" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = baseline.baselineCommand(&context);
    const help = try commander.renderHelp(scenario.allocator(), command.findSubcommand("capture").?);

    try testing.expect(std.mem.indexOf(u8, help, "only after that target has actually passed") != null);
}
