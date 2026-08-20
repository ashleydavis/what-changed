const std = @import("std");
const wc = @import("what-changed");
const cache = @import("cache.zig");
const commander = wc.commander;
const testing = std.testing;
const harness = @import("harness.zig");

const ONE_TARGET_CONFIG = "targets:\n  - name: unit\n    paths:\n      - src\n";

test "resolveCacheDir resolves the config's path against the config's directory" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", "cacheDir: tmp/hashes\ntargets:\n  - name: unit\n    paths:\n      - src\n");

    const context = scenario.context();
    const directory = try cache.resolveCacheDir(&context, .{});
    try testing.expect(std.mem.endsWith(u8, directory, "/tmp/hashes"));
    try testing.expect(std.mem.startsWith(u8, directory, scenario.temporary.path));
}

test "resolveCacheDir falls back to the default location" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", ONE_TARGET_CONFIG);

    const context = scenario.context();
    try testing.expect(std.mem.endsWith(u8, try cache.resolveCacheDir(&context, .{}), "/.what-changed/cache"));
}

test "cacheShowCommand says where the cache is and how much is in it" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{ .{ "src/a.ts", "one" }, .{ "src/b.ts", "two" } });

    const context = scenario.context();
    _ = try cache.cacheCaptureCommand(&context, .{});
    scenario.clear();

    try testing.expectEqual(@as(u8, 0), try cache.cacheShowCommand(&context, .{}));
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "Cache directory: ") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "2 file hash(es) cached.") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "This is a file hash cache only.") != null);
}

test "cacheShowCommand reports an empty cache rather than failing" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.write("what-changed.yaml", ONE_TARGET_CONFIG);

    const context = scenario.context();
    _ = try cache.cacheShowCommand(&context, .{});
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "0 file hash(es) cached.") != null);
}

test "cacheShowCommand renders json when asked" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try cache.cacheCaptureCommand(&context, .{});
    scenario.clear();

    _ = try cache.cacheShowCommand(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"cacheDir\"") != null);
    try testing.expect(std.mem.indexOf(u8, scenario.printed(), "\"entryCount\": 1") != null);
}

test "cacheCaptureCommand stores the hashes and says how many" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{ .{ "src/a.ts", "one" }, .{ "src/b.ts", "two" } });

    const context = scenario.context();
    try testing.expectEqual(@as(u8, 0), try cache.cacheCaptureCommand(&context, .{}));
    try testing.expectEqualStrings("Cache captured. 2 file hash(es) stored. The baseline is untouched.\n", scenario.printed());
}

test "cacheResetCommand empties the cache and leaves the baseline alone" {
    var scenario = try harness.Scenario.create();
    defer scenario.destroy();

    try scenario.project(ONE_TARGET_CONFIG, &.{.{ "src/a.ts", "one" }});

    const context = scenario.context();
    _ = try wc.run.runBaseline(&context, .{}, &.{});
    _ = try cache.cacheCaptureCommand(&context, .{});
    scenario.clear();

    try testing.expectEqual(@as(u8, 0), try cache.cacheResetCommand(&context, .{}));
    try testing.expectEqualStrings("Cache reset. The next report will rehash every file. The baseline is untouched.\n", scenario.printed());

    scenario.clear();
    _ = try cache.cacheShowCommand(&context, .{});
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
    _ = try cache.cacheResetCommand(&context, .{});

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
    const command = cache.cacheCommand(&context);

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
    const command = cache.cacheCommand(&context);

    var captured = std.Io.Writer.Allocating.init(scenario.allocator());
    var program = commander.Program{ .out = &captured.writer };
    try commander.parse(&program, command, &.{"capture"});

    try testing.expectEqualStrings("Cache captured. 2 file hash(es) stored. The baseline is untouched.\n", scenario.printed());
}
