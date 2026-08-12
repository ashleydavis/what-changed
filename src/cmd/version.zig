const std = @import("std");
const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;

//
// The `version` command: which build this is.
//

//
// Says which build this is, and where it came from when CI built it.
//
// A released build has its commit hash and build date written into lib/version.zig by the workflow.
// A build from source reports "dev" for all of it, which is the answer that is actually true: there
// is no tag or commit that produced it.
//
pub fn versionCommand(context: *const Context, output: ?[]const u8) wc.failure.Error!u8 {
    const allocator = context.allocator;

    const format = try wc.output.parseOutputFormat(output, context.fail);
    const is_built = !std.mem.eql(u8, wc.version.build_metadata.commit_hash, "dev");

    if (format != .text) {
        var object = wc.value.newObject(allocator);
        try object.put(allocator, "version", wc.value.str(wc.version.version));
        try object.put(allocator, "commitHash", wc.value.str(wc.version.build_metadata.commit_hash));
        try object.put(allocator, "buildDate", wc.value.str(wc.version.build_metadata.build_date));
        try object.put(allocator, "isPreRelease", wc.value.boolean(wc.version.build_metadata.is_pre_release));
        try wc.output.printStructured(allocator, context.out, .{ .object = object }, format);
        return 0;
    }

    context.out.line("what-changed {s}", .{wc.version.version});

    if (is_built) {
        const commit = wc.version.build_metadata.commit_hash;
        context.out.line("Commit: {s}", .{commit[0..@min(8, commit.len)]});
        if (!std.mem.eql(u8, wc.version.build_metadata.build_date, "development")) {
            context.out.line("Built: {s}", .{wc.version.build_metadata.build_date});
        }
        if (wc.version.build_metadata.is_pre_release) {
            context.out.line("Type: pre-release build", .{});
        }
    } else {
        context.out.line("Built from source, not from a release.", .{});
    }

    return 0;
}

//
// Builds the `version` command.
//
pub fn buildVersionCommand(context: *const Context) *Command {
    return Command.init(context.allocator, "version")
        .description("Print the version and which build this is.")
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, action);
}

fn action(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try versionCommand(context, invocation.option("output"));
}

const testing = std.testing;
const harness = @import("harness.zig");

test "versionCommand names the tool and its version" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    try testing.expectEqual(@as(u8, 0), try versionCommand(&context, null));

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
    _ = try versionCommand(&context, null);

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
    _ = try versionCommand(&context, "json");

    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"version\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"commitHash\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"buildDate\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"isPreRelease\"") != null);
}

test "versionCommand renders yaml too" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    _ = try versionCommand(&context, "yaml");
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
    try testing.expectError(error.Failed, versionCommand(&context, "xml"));
    try testing.expect(std.mem.indexOf(u8, scenario.fail.text(), "Unknown --output format") != null);
}

test "buildVersionCommand declares only --output" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = buildVersionCommand(&context);

    try testing.expectEqualStrings("version", command.command_name);
    try testing.expect(command.findOption("--output") != null);
    try testing.expect(command.findOption("--config") == null);
}

test "the version command runs through the parser" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = buildVersionCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{ "--output", "json" });

    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"commitHash\"") != null);
}
