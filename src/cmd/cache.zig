const std = @import("std");
const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;

//
// The `cache` command and its subcommands.
//
// This is the file hash cache only: the per-file hashes kept so an unchanged file is never read
// twice. Nothing in it affects what the tool reports, so emptying it costs one slow run and nothing
// else. The baseline is a different thing entirely and lives elsewhere, under `what-changed
// baseline`.
//

//
// Resolves the cache directory the config points at.
//
pub fn resolveCacheDir(context: *const Context, options: ReportOptions) wc.failure.Error![]const u8 {
    const config_path = try wc.config.resolveConfigPath(context.io, context.allocator, options.config, context.cwd, context.fail);
    const root_dir = wc.files.dirName(config_path);
    const config = try wc.config.loadConfig(context.io, context.allocator, config_path, context.fail);
    return wc.files.resolvePath(context.allocator, root_dir, config.cache_dir);
}

//
// Empties the file hash cache, so the next report rehashes every file.
//
pub fn cacheResetCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    const cache_dir = try resolveCacheDir(context, options);

    wc.cache_store.cacheReset(context.io, context.allocator, cache_dir) catch |err| {
        return context.fail.set("Failed to reset the cache in \"{s}\": {s}", .{ cache_dir, wc.files.describeError(err) });
    };

    context.out.line("Cache reset. The next report will rehash every file. The baseline is untouched.", .{});
    return 0;
}

//
// Rehashes the current tree and stores the result, so the next report has nothing to read.
//
// This is only ever a speed-up. It records no baseline and changes nothing about what a later report
// will say has changed.
//
pub fn cacheCaptureCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.runCacheCapture(context, options);
}

//
// Says where the cache is kept and how much is in it.
//
pub fn cacheShowCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    const allocator = context.allocator;

    const cache_dir = try resolveCacheDir(context, options);
    var cache = try wc.cache_store.loadCache(context.io, allocator, cache_dir);
    const entry_count = cache.file_hashes.count();
    const format = try wc.output.parseOutputFormat(options.output, context.fail);

    if (format != .text) {
        var object = wc.value.newObject(allocator);
        try object.put(allocator, "cacheDir", wc.value.str(cache_dir));
        try object.put(allocator, "entryCount", wc.value.int(@intCast(entry_count)));
        try wc.output.printStructured(allocator, context.out, .{ .object = object }, format);
        return 0;
    }

    context.out.line("Cache directory: {s}", .{cache_dir});
    context.out.line("{d} file hash(es) cached.", .{entry_count});
    context.out.blank();
    context.out.line("This is a file hash cache only. Resetting it changes nothing about what is reported.", .{});
    return 0;
}

//
// Builds the `cache` command.
//
pub fn cacheCommand(context: *const Context) *Command {
    const cmd = Command.init(context.allocator, "cache")
        .description("Manage the file hash cache. Nothing in it affects what is reported.");

    _ = cmd.command("capture")
        .alias("update")
        .description("Refresh the cached hashes for the current tree, so the next report is fast.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .action(context, captureAction);

    _ = cmd.command("reset")
        .description("Empty the cache, so the next report rehashes every file. The baseline is untouched.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .action(context, resetAction);

    _ = cmd.command("show")
        .description("Show where the cache is kept and how much is in it.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, showAction);

    return cmd;
}

fn captureAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try cacheCaptureCommand(context, .{ .config = invocation.option("config") });
}

fn resetAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try cacheResetCommand(context, .{ .config = invocation.option("config") });
}

fn showAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try cacheShowCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

const testing = std.testing;
const harness = @import("harness.zig");

const ONE_TARGET_CONFIG = "targets:\n  - name: unit\n    paths:\n      - src\n";

test "resolveCacheDir resolves the config's path against the config's directory" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "cacheDir: tmp/hashes\ntargets:\n  - name: unit\n    paths:\n      - src\n");

    const context = scenario.context();
    const directory = try resolveCacheDir(&context, .{});
    try testing.expect(std.mem.endsWith(u8, directory, "/tmp/hashes"));
    try testing.expect(std.mem.startsWith(u8, directory, scenario.temporary.path));
}

test "resolveCacheDir falls back to the default location" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", ONE_TARGET_CONFIG);

    const context = scenario.context();
    try testing.expect(std.mem.endsWith(u8, try resolveCacheDir(&context, .{}), "/.what-changed/cache"));
}

test "cacheShowCommand says where the cache is and how much is in it" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{ .{ "src/a.ts", "one" }, .{ "src/b.ts", "two" } });

    const context = scenario.context();
    _ = try cacheCaptureCommand(&context, .{});
    scenario.clear();

    try testing.expectEqual(@as(u8, 0), try cacheShowCommand(&context, .{}));
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "Cache directory: ") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "2 file hash(es) cached.") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "This is a file hash cache only.") != null);
}

test "cacheShowCommand reports an empty cache rather than failing" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", ONE_TARGET_CONFIG);

    const context = scenario.context();
    _ = try cacheShowCommand(&context, .{});
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "0 file hash(es) cached.") != null);
}

test "cacheShowCommand renders json when asked" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try cacheCaptureCommand(&context, .{});
    scenario.clear();

    _ = try cacheShowCommand(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"cacheDir\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"entryCount\": 1") != null);
}

test "cacheCaptureCommand stores the hashes and says how many" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{ .{ "src/a.ts", "one" }, .{ "src/b.ts", "two" } });

    const context = scenario.context();
    try testing.expectEqual(@as(u8, 0), try cacheCaptureCommand(&context, .{}));
    try testing.expectEqualStrings("Cache captured. 2 file hash(es) stored. The baseline is untouched.\n", scenario.printed());
}

test "cacheResetCommand empties the cache and leaves the baseline alone" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try wc.run.runBaseline(&context, .{}, &.{});
    _ = try cacheCaptureCommand(&context, .{});
    scenario.clear();

    try testing.expectEqual(@as(u8, 0), try cacheResetCommand(&context, .{}));
    try testing.expectEqualStrings("Cache reset. The next report will rehash every file. The baseline is untouched.\n", scenario.printed());

    scenario.clear();
    _ = try cacheShowCommand(&context, .{});
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "0 file hash(es) cached.") != null);

    //
    // The baseline is what says whether anything changed. Resetting the cache must not move it, or
    // "cache reset" would quietly become "run everything again".
    //
    scenario.clear();
    _ = try wc.run.compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "No files have changed since the baseline") != null);
}

test "cacheReset cannot reach the baseline, because they are different directories" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try wc.run.runBaseline(&context, .{}, &.{});
    _ = try cacheResetCommand(&context, .{});

    //
    // The cache is under its own subdirectory precisely so this can never go wrong.
    //
    try testing.expect(scenario.temporary.has(".what-changed/baseline.json"));
    try testing.expect(scenario.temporary.has(".what-changed/cache/file-hashes.json"));
}

test "cacheCommand declares capture, reset and show, with capture's alias" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    const context = scenario.context();
    const command = cacheCommand(&context);

    try testing.expectEqualStrings("cache", command.command_name);
    try testing.expect(command.findSubcommand("capture") != null);
    try testing.expect(command.findSubcommand("update") != null);
    try testing.expect(command.findSubcommand("reset") != null);
    try testing.expect(command.findSubcommand("show") != null);
    try testing.expect(command.findSubcommand("show").?.findOption("--output") != null);
}

test "cache capture runs through the parser" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{ .{ "src/a.ts", "one" }, .{ "src/b.ts", "two" } });

    const context = scenario.context();
    const command = cacheCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{"capture"});

    try testing.expectEqualStrings("Cache captured. 2 file hash(es) stored. The baseline is untouched.\n", scenario.printed());
}
