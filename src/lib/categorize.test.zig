const std = @import("std");
const config_module = @import("config.zig");
const baseline_store = @import("baseline_store.zig");
const changed_files = @import("changed_files.zig");
const file_hashes_module = @import("file_hashes.zig");
const categorize = @import("categorize.zig");
const file_hashes_test = @import("file_hashes.test.zig");
const Config = config_module.Config;
const TargetConfig = config_module.TargetConfig;
const Baseline = baseline_store.Baseline;
const FileHashes = file_hashes_module.FileHashes;
const testing = std.testing;

//
// Builds a config for a test out of target names and their paths.
//
fn configFor(allocator: std.mem.Allocator, always: []const []const u8, targets: []const struct { []const u8, []const []const u8, []const []const u8 }) !Config {
    var parsed: std.ArrayList(TargetConfig) = .empty;
    for (targets) |target| {
        try parsed.append(allocator, .{
            .name = target[0],
            .paths = try allocator.dupe([]const u8, target[1]),
            .platforms = try allocator.dupe([]const u8, target[2]),
        });
    }

    return .{
        .cache_dir = config_module.DEFAULT_CACHE_DIR,
        .baseline_path = config_module.DEFAULT_BASELINE_PATH,
        .always = try allocator.dupe([]const u8, always),
        .ignore = &.{},
        .targets = try parsed.toOwnedSlice(allocator),
    };
}

test "watchedPathsFor merges the target's paths with the always list, sorted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{ "package.json", "scripts" }, &.{.{ "unit", &.{"src"}, &.{} }});
    const watched = try categorize.watchedPathsFor(allocator, &config, &config.targets[0]);

    try testing.expectEqual(@as(usize, 3), watched.len);
    try testing.expectEqualStrings("package.json", watched[0]);
    try testing.expectEqualStrings("scripts", watched[1]);
    try testing.expectEqualStrings("src", watched[2]);
}

test "watchedPathsFor lists a path shared with the always list only once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{"src"}, &.{.{ "unit", &.{ "src", "e2e" }, &.{} }});
    const watched = try categorize.watchedPathsFor(allocator, &config, &config.targets[0]);

    try testing.expectEqual(@as(usize, 2), watched.len);
    try testing.expectEqualStrings("e2e", watched[0]);
    try testing.expectEqualStrings("src", watched[1]);
}

test "isUnderWatchedPath matches the path itself and anything below it" {
    try testing.expect(categorize.isUnderWatchedPath("src", "src"));
    try testing.expect(categorize.isUnderWatchedPath("src/a.ts", "src"));
    try testing.expect(categorize.isUnderWatchedPath("src/nested/a.ts", "src"));
    try testing.expect(categorize.isUnderWatchedPath("package.json", "package.json"));
}

test "isUnderWatchedPath does not match a directory that merely starts with the same letters" {
    //
    // The bug the separator check exists for. Without it "src" would claim every file under
    // "src-generated", and a target would be reported for changes it does not watch.
    //
    try testing.expect(!categorize.isUnderWatchedPath("src-generated/a.ts", "src"));
    try testing.expect(!categorize.isUnderWatchedPath("source", "src"));
}

test "isUnderWatchedPath does not match a path above the watched one" {
    try testing.expect(!categorize.isUnderWatchedPath("src", "src/nested"));
    try testing.expect(!categorize.isUnderWatchedPath("other/a.ts", "src"));
}

test "isWatchedBy answers for a list of watched paths" {
    try testing.expect(categorize.isWatchedBy("src/a.ts", &.{ "docs", "src" }));
    try testing.expect(!categorize.isWatchedBy("stray/a.ts", &.{ "docs", "src" }));
    try testing.expect(!categorize.isWatchedBy("src/a.ts", &.{}));
}

test "targetAppliesToPlatform lets a target with no platforms run anywhere" {
    const target = TargetConfig{ .name = "unit", .paths = &.{}, .platforms = &.{} };
    try testing.expect(categorize.targetAppliesToPlatform(&target, "linux"));
    try testing.expect(categorize.targetAppliesToPlatform(&target, "darwin"));
    try testing.expect(categorize.targetAppliesToPlatform(&target, "win32"));
}

test "targetAppliesToPlatform is exclusive once a platform is named" {
    var platforms = [_][]const u8{ "linux", "darwin" };
    const target = TargetConfig{ .name = "mobile", .paths = &.{}, .platforms = &platforms };

    try testing.expect(categorize.targetAppliesToPlatform(&target, "linux"));
    try testing.expect(categorize.targetAppliesToPlatform(&target, "darwin"));
    try testing.expect(!categorize.targetAppliesToPlatform(&target, "win32"));
}

test "filesUnderWatchedPaths keeps only what falls under a watched path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try file_hashes_test.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "docs/g.md", "2" },
        .{ "stray/x.ts", "3" },
    });

    var under = try categorize.filesUnderWatchedPaths(allocator, &hashes, &.{ "src", "docs" });
    try testing.expectEqual(@as(usize, 2), under.count());
    try testing.expect(under.get("stray/x.ts") == null);
}

test "pathsUnderWatchedPaths keeps only what falls under a watched path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const under = try categorize.pathsUnderWatchedPaths(allocator, &.{ "src/a.ts", "docs/g.md", "stray/x.ts" }, &.{ "src", "docs" });
    try testing.expectEqual(@as(usize, 2), under.len);
    try testing.expectEqualStrings("src/a.ts", under[0]);
    try testing.expectEqualStrings("docs/g.md", under[1]);
}

test "pathsNotUnderWatchedPaths keeps only what falls under none of them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const outside = try categorize.pathsNotUnderWatchedPaths(allocator, &.{ "src/a.ts", "docs/g.md", "stray/x.ts" }, &.{ "src", "docs" });
    try testing.expectEqual(@as(usize, 1), outside.len);
    try testing.expectEqualStrings("stray/x.ts", outside[0]);
}

test "categorizeChanges puts each changed file under the target that watches it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{
        .{ "unit", &.{"src"}, &.{} },
        .{ "docs", &.{"documentation"}, &.{} },
    });

    var hashes = try file_hashes_test.fromPairs(allocator, &.{
        .{ "src/a.ts", "changed" },
        .{ "documentation/g.txt", "same" },
    });

    var targets: baseline_store.TargetBaselines = .empty;
    try targets.put(allocator, "unit", try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "old" }}));
    try targets.put(allocator, "docs", try file_hashes_test.fromPairs(allocator, &.{.{ "documentation/g.txt", "same" }}));
    const baseline = Baseline{ .targets = targets, .files = .empty };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");

    try testing.expectEqual(@as(usize, 2), categorized.targets.len);
    try testing.expectEqual(@as(usize, 1), categorized.targets[0].changed_files.len);
    try testing.expectEqualStrings("src/a.ts", categorized.targets[0].changed_files[0].path);
    try testing.expectEqual(@as(usize, 0), categorized.targets[1].changed_files.len);
    try testing.expectEqual(@as(usize, 0), categorized.unwatched_files.len);
}

test "categorizeChanges keeps the targets in config order, including the unchanged ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{
        .{ "compile", &.{"src"}, &.{} },
        .{ "test", &.{"src"}, &.{} },
        .{ "smoke", &.{"src"}, &.{} },
    });

    var hashes: FileHashes = .empty;
    const baseline = Baseline{ .targets = .empty, .files = .empty };
    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");

    try testing.expectEqual(@as(usize, 3), categorized.targets.len);
    try testing.expectEqualStrings("compile", categorized.targets[0].name);
    try testing.expectEqualStrings("test", categorized.targets[1].name);
    try testing.expectEqualStrings("smoke", categorized.targets[2].name);
}

test "categorizeChanges treats a target that was never captured as fully changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes = try file_hashes_test.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "src/b.ts", "2" } });
    const baseline = Baseline{ .targets = .empty, .files = .empty };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
    try testing.expect(!categorized.targets[0].ever_captured);
    try testing.expectEqual(@as(usize, 2), categorized.targets[0].changed_files.len);
    try testing.expectEqual(changed_files.FileChangeKind.added, categorized.targets[0].changed_files[0].kind);
}

test "categorizeChanges compares each target against its own record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // Both targets watch the same directory, but only one has been captured since it changed. The
    // rule the per-target baseline exists for: the other must still be reported as affected.
    //
    const config = try configFor(allocator, &.{}, &.{
        .{ "captured", &.{"src"}, &.{} },
        .{ "stale", &.{"src"}, &.{} },
    });

    var hashes = try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "new" }});

    var targets: baseline_store.TargetBaselines = .empty;
    try targets.put(allocator, "captured", try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "new" }}));
    try targets.put(allocator, "stale", try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "old" }}));
    const baseline = Baseline{ .targets = targets, .files = .empty };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
    try testing.expectEqual(@as(usize, 0), categorized.targets[0].changed_files.len);
    try testing.expectEqual(@as(usize, 1), categorized.targets[1].changed_files.len);
}

test "categorizeChanges never gives a wrong-platform target changed files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{
        .{ "here", &.{"src"}, &.{"linux"} },
        .{ "elsewhere", &.{"src"}, &.{"darwin"} },
    });

    var hashes = try file_hashes_test.fromPairs(allocator, &.{.{ "src/a.ts", "1" }});
    const baseline = Baseline{ .targets = .empty, .files = .empty };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");

    try testing.expect(categorized.targets[0].applies_here);
    try testing.expectEqual(@as(usize, 1), categorized.targets[0].changed_files.len);

    try testing.expect(!categorized.targets[1].applies_here);
    try testing.expectEqual(@as(usize, 0), categorized.targets[1].changed_files.len);
}

test "categorizeChanges still counts a wrong-platform target's paths as watched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // The only target watching "mobile" cannot run here. Its files must still not be reported as
    // watched by nothing, or someone goes looking for a gap in the config that is not there.
    //
    const config = try configFor(allocator, &.{}, &.{.{ "mobile", &.{"mobile"}, &.{"darwin"} }});
    var hashes = try file_hashes_test.fromPairs(allocator, &.{.{ "mobile/app.ts", "1" }});
    const baseline = Baseline{ .targets = .empty, .files = .empty };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
    try testing.expectEqual(@as(usize, 0), categorized.unwatched_files.len);
}

test "categorizeChanges calls out a changed file no target watches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes = try file_hashes_test.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "stray/x.ts", "2" } });
    const baseline = Baseline{ .targets = .empty, .files = .empty };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
    try testing.expectEqual(@as(usize, 1), categorized.unwatched_files.len);
    try testing.expectEqualStrings("stray/x.ts", categorized.unwatched_files[0].path);
}

test "categorizeChanges measures unwatched files against the whole-tree record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes = try file_hashes_test.fromPairs(allocator, &.{.{ "stray/x.ts", "same" }});
    const baseline = Baseline{
        .targets = .empty,
        .files = try file_hashes_test.fromPairs(allocator, &.{.{ "stray/x.ts", "same" }}),
    };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
    try testing.expectEqual(@as(usize, 0), categorized.unwatched_files.len);
}

test "categorizeChanges does not report a deleted watched file as an unwatched change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // The whole-tree record still holds the deleted file. Without narrowing it to the unwatched
    // paths, the deletion would be reported twice: once under the target, and again as a file
    // nothing watches.
    //
    const config = try configFor(allocator, &.{}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes: FileHashes = .empty;

    var targets: baseline_store.TargetBaselines = .empty;
    try targets.put(allocator, "unit", try file_hashes_test.fromPairs(allocator, &.{.{ "src/gone.ts", "old" }}));
    const baseline = Baseline{
        .targets = targets,
        .files = try file_hashes_test.fromPairs(allocator, &.{.{ "src/gone.ts", "old" }}),
    };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
    try testing.expectEqual(@as(usize, 1), categorized.targets[0].changed_files.len);
    try testing.expectEqual(@as(usize, 0), categorized.unwatched_files.len);
}

test "unwatchedOnly narrows a record to the files no target watches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorded = try file_hashes_test.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "stray/x.ts", "2" } });
    var narrowed = try categorize.unwatchedOnly(allocator, &recorded, &.{"src"});

    try testing.expectEqual(@as(usize, 1), narrowed.count());
    try testing.expectEqualStrings("2", narrowed.get("stray/x.ts").?);
}

test "capturedFilesFor records everything the target currently watches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{"package.json"}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes = try file_hashes_test.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "package.json", "2" },
        .{ "stray/x.ts", "3" },
    });

    var captured = try categorize.capturedFilesFor(allocator, &config, &config.targets[0], &hashes);
    try testing.expectEqual(@as(usize, 2), captured.count());
    try testing.expectEqualStrings("1", captured.get("src/a.ts").?);
    try testing.expectEqualStrings("2", captured.get("package.json").?);
    try testing.expect(captured.get("stray/x.ts") == null);
}

test "capturedFilesFor records only what it was given, which is only what was read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes = try file_hashes_test.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "docs/b.md", "2" },
    });

    var captured = try categorize.capturedFilesFor(allocator, &config, &config.targets[0], &hashes);
    try testing.expectEqual(@as(usize, 1), captured.count());
    try testing.expectEqualStrings("1", captured.get("src/a.ts").?);
}

test "categorizeChanges gives an unreadable file to the target that watches it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{ .{ "unit", &.{"src"}, &.{} }, .{ "docs", &.{"docs"}, &.{} } });
    var hashes = try file_hashes_test.fromPairs(allocator, &.{.{ "docs/b.md", "2" }});

    //
    // Recorded in the baseline and absent from the hashes, which on its own reads as a deletion.
    // Naming it unreadable is what makes the target's one change say so instead.
    //
    var targets: baseline_store.TargetBaselines = .empty;
    try targets.put(allocator, "unit", try file_hashes_test.fromPairs(allocator, &.{.{ "src/locked.ts", "old" }}));
    const baseline = Baseline{ .targets = targets, .files = .empty };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{"src/locked.ts"}, &baseline, "linux");

    try testing.expectEqual(@as(usize, 1), categorized.targets[0].changed_files.len);
    try testing.expectEqualStrings("src/locked.ts", categorized.targets[0].changed_files[0].path);
    try testing.expectEqual(changed_files.FileChangeKind.unreadable, categorized.targets[0].changed_files[0].kind);

    //
    // The docs target does not watch it, so its only change is its own never-captured file.
    //
    try testing.expectEqual(@as(usize, 1), categorized.targets[1].changed_files.len);
    try testing.expectEqualStrings("docs/b.md", categorized.targets[1].changed_files[0].path);
}

test "categorizeChanges reports an unreadable file no target watches as unwatched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes: FileHashes = .empty;
    const baseline = Baseline{ .targets = .empty, .files = .empty };

    const categorized = try categorize.categorizeChanges(allocator, &config, &hashes, &.{"loose/locked.ts"}, &baseline, "linux");

    try testing.expectEqual(@as(usize, 0), categorized.targets[0].changed_files.len);
    try testing.expectEqual(@as(usize, 1), categorized.unwatched_files.len);
    try testing.expectEqualStrings("loose/locked.ts", categorized.unwatched_files[0].path);
    try testing.expectEqual(changed_files.FileChangeKind.unreadable, categorized.unwatched_files[0].kind);
}
