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

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("categorize.test.zig");
}
