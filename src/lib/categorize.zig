const std = @import("std");
const config_module = @import("config.zig");
const baseline_store = @import("baseline_store.zig");
const changed_files = @import("changed_files.zig");
const file_hashes_module = @import("file_hashes.zig");

const Config = config_module.Config;
const TargetConfig = config_module.TargetConfig;
const Baseline = baseline_store.Baseline;
const FileHashes = file_hashes_module.FileHashes;
const ChangedFile = changed_files.ChangedFile;

//
// One target, and the changed files that fall under the paths it watches.
//
pub const TargetChanges = struct {
    //
    // The target's name.
    //
    name: []const u8,

    //
    // The paths this target watches: its own, plus the config's "always" list, sorted and
    // deduplicated.
    //
    watched_paths: [][]const u8,

    //
    // Whether this target applies on the platform the tool is running on.
    //
    // False means the target declared platforms and this is not one of them, so it can never run
    // here whatever changed. It is reported rather than dropped, so a target missing from the output
    // is visibly excluded instead of silently absent.
    //
    applies_here: bool,

    //
    // Whether this target has ever been captured. False means it has no record to compare against,
    // so everything it watches counts as changed and it is affected by definition.
    //
    ever_captured: bool,

    //
    // The files under this target's watched paths that differ from what it recorded when it was last
    // captured.
    //
    // Always empty for a target that does not apply here. A target that cannot run is not affected
    // by anything, so there is nothing for a caller to act on.
    //
    changed_files: []ChangedFile,
};

//
// Every target's changes, plus the changed files that no target accounts for.
//
pub const CategorizedChanges = struct {
    //
    // One entry per target in the config, in config order, including targets with no changes.
    //
    targets: []TargetChanges,

    //
    // Changed files that fall under no target's watched paths. These are the interesting ones: a
    // file nothing watches is a file whose change nothing will react to, which is usually a gap in
    // the config rather than a deliberate choice.
    //
    unwatched_files: []ChangedFile,
};

//
// Returns every path a target watches: its own paths plus the ones every target watches.
//
pub fn watchedPathsFor(allocator: std.mem.Allocator, config: *const Config, target: *const TargetConfig) std.mem.Allocator.Error![][]const u8 {
    var merged: std.StringArrayHashMapUnmanaged(void) = .empty;

    for (target.paths) |watched_path| {
        try merged.put(allocator, watched_path, {});
    }
    for (config.always) |watched_path| {
        try merged.put(allocator, watched_path, {});
    }

    const paths = try allocator.dupe([]const u8, merged.keys());
    std.mem.sort([]const u8, paths, {}, file_hashes_module.lessThanPath);
    return paths;
}

//
// True when a file falls under a watched path.
//
// A watched path is either the file itself or a directory above it. The separator check is what
// stops "src" matching "srcircus/a.ts": without it any path that merely starts with the same letters
// would count, and a target would report changes it does not actually watch.
//
pub fn isUnderWatchedPath(file_path: []const u8, watched_path: []const u8) bool {
    if (std.mem.eql(u8, file_path, watched_path)) return true;
    return file_path.len > watched_path.len and
        std.mem.startsWith(u8, file_path, watched_path) and
        file_path[watched_path.len] == '/';
}

//
// True when a file falls under any of the watched paths.
//
pub fn isWatchedBy(file_path: []const u8, watched_paths: []const []const u8) bool {
    for (watched_paths) |watched_path| {
        if (isUnderWatchedPath(file_path, watched_path)) return true;
    }
    return false;
}

//
// True when a target can run on the given platform.
//
// An empty list means every platform, which is the default, so a config that says nothing about
// platforms behaves as it always did. A non-empty list is exclusive: some targets need a toolchain
// that only exists on one operating system, and a machine without it cannot run them however much
// has changed. That is why nothing overrides this, including a caller's own force flag.
//
pub fn targetAppliesToPlatform(target: *const TargetConfig, platform: []const u8) bool {
    if (target.platforms.len == 0) return true;

    for (target.platforms) |declared| {
        if (std.mem.eql(u8, declared, platform)) return true;
    }
    return false;
}

//
// Narrows a set of file hashes to those falling under the given watched paths.
//
pub fn filesUnderWatchedPaths(allocator: std.mem.Allocator, hashes: *const FileHashes, watched_paths: []const []const u8) std.mem.Allocator.Error!FileHashes {
    var under: FileHashes = .empty;

    var walker = hashes.iterator();
    while (walker.next()) |entry| {
        if (isWatchedBy(entry.key_ptr.*, watched_paths)) {
            try under.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return under;
}

//
// Narrows a list of paths to those falling under the given watched paths.
//
// The same rule as `filesUnderWatchedPaths`, for the paths that have no hash to carry: a file that
// could not be read still belongs to whichever targets watch it.
//
pub fn pathsUnderWatchedPaths(allocator: std.mem.Allocator, paths: []const []const u8, watched_paths: []const []const u8) std.mem.Allocator.Error![][]const u8 {
    var under: std.ArrayList([]const u8) = .empty;
    for (paths) |path| {
        if (isWatchedBy(path, watched_paths)) {
            try under.append(allocator, path);
        }
    }
    return under.toOwnedSlice(allocator);
}

//
// The other half of `pathsUnderWatchedPaths`: the paths no target watches.
//
pub fn pathsNotUnderWatchedPaths(allocator: std.mem.Allocator, paths: []const []const u8, watched_paths: []const []const u8) std.mem.Allocator.Error![][]const u8 {
    var outside: std.ArrayList([]const u8) = .empty;
    for (paths) |path| {
        if (!isWatchedBy(path, watched_paths)) {
            try outside.append(allocator, path);
        }
    }
    return outside.toOwnedSlice(allocator);
}

//
// Works out, for every target, which of the files it watches have changed since that target was last
// captured.
//
// Each target is compared against its own record, not against one snapshot of the whole tree. That
// is what lets a caller run one suite, capture just that target, and leave every other target
// correctly reported as still needing to run.
//
pub fn categorizeChanges(allocator: std.mem.Allocator, config: *const Config, hashes: *const FileHashes, unreadable: []const []const u8, baseline: *const Baseline, platform: []const u8) std.mem.Allocator.Error!CategorizedChanges {
    var targets: std.ArrayList(TargetChanges) = .empty;

    for (config.targets) |*target| {
        const watched_paths = try watchedPathsFor(allocator, config, target);
        const applies_here = targetAppliesToPlatform(target, platform);
        const recorded = baseline.targets.get(target.name);

        var changes: []ChangedFile = &.{};
        if (applies_here) {
            var under = try filesUnderWatchedPaths(allocator, hashes, watched_paths);
            const empty: FileHashes = .empty;
            const compared_against = if (recorded) |*existing| existing else &empty;
            changes = try changed_files.diffFileHashes(
                allocator,
                &under,
                compared_against,
                try pathsUnderWatchedPaths(allocator, unreadable, watched_paths),
            );
        }

        try targets.append(allocator, .{
            .name = target.name,
            .watched_paths = watched_paths,
            .applies_here = applies_here,
            .ever_captured = recorded != null,
            .changed_files = changes,
        });
    }

    //
    // Watched paths are what decides this, not whether the target applies here. A file watched only
    // by a target that cannot run on this platform is still watched: reporting it as watched by
    // nothing would send someone looking for a gap in the config that is not there.
    //
    var all_watched_paths: std.ArrayList([]const u8) = .empty;
    for (targets.items) |target| {
        try all_watched_paths.appendSlice(allocator, target.watched_paths);
    }

    var unwatched: FileHashes = .empty;
    var walker = hashes.iterator();
    while (walker.next()) |entry| {
        if (!isWatchedBy(entry.key_ptr.*, all_watched_paths.items)) {
            try unwatched.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    //
    // Files no target watches have no target record to compare against, so they are measured against
    // the whole-tree record instead. That is the only thing it is used for.
    //
    var recorded_unwatched = try unwatchedOnly(allocator, &baseline.files, all_watched_paths.items);
    const unwatched_files = try changed_files.diffFileHashes(
        allocator,
        &unwatched,
        &recorded_unwatched,
        try pathsNotUnderWatchedPaths(allocator, unreadable, all_watched_paths.items),
    );

    return .{
        .targets = try targets.toOwnedSlice(allocator),
        .unwatched_files = unwatched_files,
    };
}

//
// Narrows a whole-tree record to the files that no target watches, so a deletion of a watched file
// is not also reported as an unwatched change.
//
pub fn unwatchedOnly(allocator: std.mem.Allocator, recorded: *const FileHashes, all_watched_paths: []const []const u8) std.mem.Allocator.Error!FileHashes {
    var unwatched: FileHashes = .empty;

    var walker = recorded.iterator();
    while (walker.next()) |entry| {
        if (!isWatchedBy(entry.key_ptr.*, all_watched_paths)) {
            try unwatched.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return unwatched;
}

//
// The file hashes a target should record when it is captured: everything it currently watches.
//
// `hashes` holds only files that were read, so a file that is gone or unreadable is already absent
// and a capture records real content hashes and nothing else.
//
pub fn capturedFilesFor(allocator: std.mem.Allocator, config: *const Config, target: *const TargetConfig, hashes: *const FileHashes) std.mem.Allocator.Error!FileHashes {
    return filesUnderWatchedPaths(allocator, hashes, try watchedPathsFor(allocator, config, target));
}

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
    const watched = try watchedPathsFor(allocator, &config, &config.targets[0]);

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
    const watched = try watchedPathsFor(allocator, &config, &config.targets[0]);

    try testing.expectEqual(@as(usize, 2), watched.len);
    try testing.expectEqualStrings("e2e", watched[0]);
    try testing.expectEqualStrings("src", watched[1]);
}

test "isUnderWatchedPath matches the path itself and anything below it" {
    try testing.expect(isUnderWatchedPath("src", "src"));
    try testing.expect(isUnderWatchedPath("src/a.ts", "src"));
    try testing.expect(isUnderWatchedPath("src/nested/a.ts", "src"));
    try testing.expect(isUnderWatchedPath("package.json", "package.json"));
}

test "isUnderWatchedPath does not match a directory that merely starts with the same letters" {
    //
    // The bug the separator check exists for. Without it "src" would claim every file under
    // "srcircus", and a target would report changes it does not watch.
    //
    try testing.expect(!isUnderWatchedPath("srcircus/a.ts", "src"));
    try testing.expect(!isUnderWatchedPath("src-other/a.ts", "src"));
    try testing.expect(!isUnderWatchedPath("source", "src"));
}

test "isUnderWatchedPath does not match a path above the watched one" {
    try testing.expect(!isUnderWatchedPath("src", "src/nested"));
    try testing.expect(!isUnderWatchedPath("other/a.ts", "src"));
}

test "isWatchedBy answers for a list of watched paths" {
    try testing.expect(isWatchedBy("src/a.ts", &.{ "docs", "src" }));
    try testing.expect(!isWatchedBy("stray/a.ts", &.{ "docs", "src" }));
    try testing.expect(!isWatchedBy("src/a.ts", &.{}));
}

test "targetAppliesToPlatform lets a target with no platforms run anywhere" {
    const target = TargetConfig{ .name = "unit", .paths = &.{}, .platforms = &.{} };
    try testing.expect(targetAppliesToPlatform(&target, "linux"));
    try testing.expect(targetAppliesToPlatform(&target, "darwin"));
    try testing.expect(targetAppliesToPlatform(&target, "win32"));
}

test "targetAppliesToPlatform is exclusive once a platform is named" {
    var platforms = [_][]const u8{ "linux", "darwin" };
    const target = TargetConfig{ .name = "mobile", .paths = &.{}, .platforms = &platforms };

    try testing.expect(targetAppliesToPlatform(&target, "linux"));
    try testing.expect(targetAppliesToPlatform(&target, "darwin"));
    try testing.expect(!targetAppliesToPlatform(&target, "win32"));
}

test "filesUnderWatchedPaths keeps only what falls under a watched path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hashes = try file_hashes_module.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "docs/g.md", "2" },
        .{ "stray/x.ts", "3" },
    });

    var under = try filesUnderWatchedPaths(allocator, &hashes, &.{ "src", "docs" });
    try testing.expectEqual(@as(usize, 2), under.count());
    try testing.expect(under.get("stray/x.ts") == null);
}

test "pathsUnderWatchedPaths keeps only what falls under a watched path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const under = try pathsUnderWatchedPaths(allocator, &.{ "src/a.ts", "docs/g.md", "stray/x.ts" }, &.{ "src", "docs" });
    try testing.expectEqual(@as(usize, 2), under.len);
    try testing.expectEqualStrings("src/a.ts", under[0]);
    try testing.expectEqualStrings("docs/g.md", under[1]);
}

test "pathsNotUnderWatchedPaths keeps only what falls under none of them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const outside = try pathsNotUnderWatchedPaths(allocator, &.{ "src/a.ts", "docs/g.md", "stray/x.ts" }, &.{ "src", "docs" });
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

    var hashes = try file_hashes_module.fromPairs(allocator, &.{
        .{ "src/a.ts", "changed" },
        .{ "documentation/g.txt", "same" },
    });

    var targets: baseline_store.TargetBaselines = .empty;
    try targets.put(allocator, "unit", try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "old" }}));
    try targets.put(allocator, "docs", try file_hashes_module.fromPairs(allocator, &.{.{ "documentation/g.txt", "same" }}));
    const baseline = Baseline{ .targets = targets, .files = .empty };

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");

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
    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");

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
    var hashes = try file_hashes_module.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "src/b.ts", "2" } });
    const baseline = Baseline{ .targets = .empty, .files = .empty };

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
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

    var hashes = try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "new" }});

    var targets: baseline_store.TargetBaselines = .empty;
    try targets.put(allocator, "captured", try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "new" }}));
    try targets.put(allocator, "stale", try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "old" }}));
    const baseline = Baseline{ .targets = targets, .files = .empty };

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
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

    var hashes = try file_hashes_module.fromPairs(allocator, &.{.{ "src/a.ts", "1" }});
    const baseline = Baseline{ .targets = .empty, .files = .empty };

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");

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
    var hashes = try file_hashes_module.fromPairs(allocator, &.{.{ "mobile/app.ts", "1" }});
    const baseline = Baseline{ .targets = .empty, .files = .empty };

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
    try testing.expectEqual(@as(usize, 0), categorized.unwatched_files.len);
}

test "categorizeChanges calls out a changed file no target watches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes = try file_hashes_module.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "stray/x.ts", "2" } });
    const baseline = Baseline{ .targets = .empty, .files = .empty };

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
    try testing.expectEqual(@as(usize, 1), categorized.unwatched_files.len);
    try testing.expectEqualStrings("stray/x.ts", categorized.unwatched_files[0].path);
}

test "categorizeChanges measures unwatched files against the whole-tree record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes = try file_hashes_module.fromPairs(allocator, &.{.{ "stray/x.ts", "same" }});
    const baseline = Baseline{
        .targets = .empty,
        .files = try file_hashes_module.fromPairs(allocator, &.{.{ "stray/x.ts", "same" }}),
    };

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
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
    try targets.put(allocator, "unit", try file_hashes_module.fromPairs(allocator, &.{.{ "src/gone.ts", "old" }}));
    const baseline = Baseline{
        .targets = targets,
        .files = try file_hashes_module.fromPairs(allocator, &.{.{ "src/gone.ts", "old" }}),
    };

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{}, &baseline, "linux");
    try testing.expectEqual(@as(usize, 1), categorized.targets[0].changed_files.len);
    try testing.expectEqual(@as(usize, 0), categorized.unwatched_files.len);
}

test "unwatchedOnly narrows a record to the files no target watches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorded = try file_hashes_module.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "stray/x.ts", "2" } });
    var narrowed = try unwatchedOnly(allocator, &recorded, &.{"src"});

    try testing.expectEqual(@as(usize, 1), narrowed.count());
    try testing.expectEqualStrings("2", narrowed.get("stray/x.ts").?);
}

test "capturedFilesFor records everything the target currently watches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{"package.json"}, &.{.{ "unit", &.{"src"}, &.{} }});
    var hashes = try file_hashes_module.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "package.json", "2" },
        .{ "stray/x.ts", "3" },
    });

    var captured = try capturedFilesFor(allocator, &config, &config.targets[0], &hashes);
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
    var hashes = try file_hashes_module.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "docs/b.md", "2" },
    });

    var captured = try capturedFilesFor(allocator, &config, &config.targets[0], &hashes);
    try testing.expectEqual(@as(usize, 1), captured.count());
    try testing.expectEqualStrings("1", captured.get("src/a.ts").?);
}

test "categorizeChanges gives an unreadable file to the target that watches it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try configFor(allocator, &.{}, &.{ .{ "unit", &.{"src"}, &.{} }, .{ "docs", &.{"docs"}, &.{} } });
    var hashes = try file_hashes_module.fromPairs(allocator, &.{.{ "docs/b.md", "2" }});

    //
    // Recorded in the baseline and absent from the hashes, which on its own reads as a deletion.
    // Naming it unreadable is what makes the target's one change say so instead.
    //
    var targets: baseline_store.TargetBaselines = .empty;
    try targets.put(allocator, "unit", try file_hashes_module.fromPairs(allocator, &.{.{ "src/locked.ts", "old" }}));
    const baseline = Baseline{ .targets = targets, .files = .empty };

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{"src/locked.ts"}, &baseline, "linux");

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

    const categorized = try categorizeChanges(allocator, &config, &hashes, &.{"loose/locked.ts"}, &baseline, "linux");

    try testing.expectEqual(@as(usize, 0), categorized.targets[0].changed_files.len);
    try testing.expectEqual(@as(usize, 1), categorized.unwatched_files.len);
    try testing.expectEqualStrings("loose/locked.ts", categorized.unwatched_files[0].path);
    try testing.expectEqual(changed_files.FileChangeKind.unreadable, categorized.unwatched_files[0].kind);
}
