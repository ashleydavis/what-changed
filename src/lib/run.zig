const std = @import("std");
const annotate_mod = @import("log");

//
// The branch markers a fault run reads back. `an` is a compile-time flag: the binary people run is
// built with it off, so every `if (an) annotate(...)` below compiles to nothing there.
//
const Log = annotate_mod.Log;
const an = annotate_mod.an;
const annotate = annotate_mod.annotate;
const files = @import("files.zig");
const value = @import("value.zig");
const failure = @import("failure.zig");
const config_module = @import("config.zig");
const cache_store = @import("cache_store.zig");
const baseline_store = @import("baseline_store.zig");
const categorize = @import("categorize.zig");
const changed_files = @import("changed_files.zig");
const file_hash = @import("file_hash.zig");
const file_hashes_module = @import("file_hashes.zig");
const list_files = @import("list_files.zig");
const output_module = @import("output.zig");

const Failure = failure.Failure;
const Value = value.Value;
const Config = config_module.Config;
const Baseline = baseline_store.Baseline;
const FileHashes = file_hashes_module.FileHashes;
const ChangedFile = changed_files.ChangedFile;
const CategorizedChanges = categorize.CategorizedChanges;
const FileLister = list_files.FileLister;
const Output = output_module.Output;
const OutputFormat = output_module.OutputFormat;

//
// Which of the three views of the same comparison to print.
//
// "summary" groups the changed files under the targets that watch them, "files" lists them flat, and
// "targets" prints only the affected target names for a script to read. All three do exactly the
// same work and differ only in what they print, so they can never disagree about what changed.
//
pub const ReportMode = enum {
    summary,
    files,
    targets,
};

//
// The options every reporting command takes.
//
pub const ReportOptions = struct {
    //
    // The config file to read, relative to the working directory.
    //
    config: ?[]const u8 = null,

    //
    // How to render the result: text, json or yaml. Absent means text.
    //
    output: ?[]const u8 = null,
};

//
// The options the reporting flow needs, which is the command's own options plus the view to print.
//
pub const ReportRequest = struct {
    //
    // The command's own options.
    //
    options: ReportOptions,

    //
    // Which view to print.
    //
    mode: ReportMode,
};

//
// What a report found, as data, before anything decides how to render it.
//
// Every output format is built from this one object, so the text a person reads and the JSON a script
// reads can never disagree about what changed.
//
pub const ReportResult = struct {
    //
    // Whether a baseline was recorded at all. With none, nothing can be called changed or unchanged.
    //
    has_baseline: bool,

    //
    // How many files were checked.
    //
    file_count: usize,

    //
    // Every file that differs from the baseline. With no baseline every file is here, as an addition.
    //
    changes: []ChangedFile,

    //
    // The same changed files, sorted into the targets that watch them, plus the ones no target
    // watches. Always present: it is derived from `changes` and never computed separately.
    //
    categorized: CategorizedChanges,

    //
    // The names of the targets that have changes, taken from `categorized`.
    //
    target_names: [][]const u8,
};

//
// Everything a run needs from the world outside it.
//
// The working directory, the file lister and the platform are arguments rather than reads of the
// process, so the flow can be driven against a throwaway directory and a chosen file list without
// touching the real process state or needing a git repository to point at. `out` is here for the
// same reason: a test reads what a report printed instead of capturing the process's output.
//
pub const Context = struct {
    //
    // Where memory for this run comes from. An arena in the CLI, so nothing is freed until the run
    // is over, which is exactly how long every allocation here is needed.
    //
    allocator: std.mem.Allocator,

    //
    // How every filesystem call this run makes is performed.
    //
    // Carried here rather than reached for, so a run only ever touches the implementation it was
    // handed: the CLI passes the one the runtime gave the process, and a test passes its own.
    //
    io: std.Io,

    //
    // The environment every child process this run spawns is given.
    //
    // Carried for the same reason as `io`: `git ls-files` reads `GIT_DIR`, `GIT_WORK_TREE` and
    // `GIT_CONFIG_GLOBAL`, so the environment decides which files the tool reports on. The CLI passes
    // the one the runtime gave the process, and a test passes its own rather than having the file
    // list depend on whatever the test runner happened to be started with.
    //
    environ: *const std.process.Environ.Map,

    //
    // The directory the tool was invoked from.
    //
    cwd: []const u8,

    //
    // How the file list is obtained.
    //
    list_files: FileLister,

    //
    // The platform name a target's "platforms" list is matched against.
    //
    platform: []const u8,

    //
    // Where the output goes.
    //
    out: *Output,

    //
    // Where the message goes when something fails.
    //
    fail: *Failure,
};

//
// What every run has in common: the config, where its files live, and the hashes of everything in
// the tree right now.
//
// Three of the four commands need exactly this and differ only in what they do afterwards, so it is
// worked out once here rather than three times over.
//
const HashedFileTree = struct {
    //
    // The config file that was read, as an absolute path.
    //
    // Carried so a message that refuses an unknown target name can say which file the known names
    // came from, which is the one thing that makes such a message actionable.
    //
    config_path: []const u8,

    //
    // The directory holding the config file, which is what every relative path in the config and
    // every listed file path is resolved against.
    //
    // The config's own location defines the project root rather than the working directory, so a run
    // from a subdirectory reports on the same tree as a run from the top.
    //
    root_dir: []const u8,

    //
    // The parsed config: the targets, the ignore rules and where the baseline and cache live.
    //
    config: Config,

    //
    // Where the file hash cache lives, resolved against `root_dir`.
    //
    // Resolved once here rather than again by each caller, so a run cannot read one cache and write
    // another.
    //
    cache_dir: []const u8,

    //
    // Every file in the tree that survived the ignore rules, relative to `root_dir`.
    //
    // Kept alongside the hashes because pruning the cache needs the list of paths that still exist,
    // which the hashes alone do not give: they say what a file hashed to, not whether it was listed.
    //
    file_paths: [][]const u8,

    //
    // What each file that could be read hashes to right now. This is the picture of the tree that
    // the baseline is compared against.
    //
    // A file that is gone is not in here, which is how the comparison reports it as deleted. Nor is
    // one that could not be read: those are in `unreadable` instead, so the two are not confused.
    //
    file_hashes: FileHashes,

    //
    // The files that are on disk and could not be read, relative to `root_dir`.
    //
    // Each one is reported as a change of its own kind. A file whose content cannot be seen cannot be
    // called unchanged, and saying so is the difference between a permission problem being noticed
    // and it reading as a deletion on every run for as long as it lasts.
    //
    unreadable: []file_hash.UnreadableFile,
};

//
// Reads the config, lists the files, hashes them, and writes the refreshed hash cache back to disk.
//
// This is where nearly all of a run's time goes: the callers only compare these hashes against the
// baseline and print.
//
// The cache is written whatever happens next, because the per-file hashes are only ever an
// optimisation: they say nothing about what changed, so recording them cannot make a later report
// wrong however the run that computed them ends.
//
fn hashFileTree(context: *const Context, options: ReportOptions) failure.Error!HashedFileTree {
    const log = context.fail.log;
    const allocator = context.allocator;

    const config_path = try config_module.resolveConfigPath(context.io, allocator, options.config, context.cwd, context.fail);
    const root_dir = files.dirName(config_path);
    const config = try config_module.loadConfig(context.io, allocator, config_path, context.fail);

    const cache_dir = try files.resolvePath(allocator, root_dir, config.cache_dir);
    var cache = try cache_store.loadCache(context.io, allocator, cache_dir, log);

    const listed = try context.list_files(context.io, context.environ, allocator, root_dir, context.fail);
    const file_paths = try list_files.filterIgnoredFiles(allocator, listed, config.ignore, log);
    const hashed = try file_hash.hashFiles(context.io, allocator, root_dir, file_paths, &cache.file_hashes, log);

    var pruned = try cache_store.pruneFileHashes(allocator, &cache.file_hashes, file_paths, log);
    cache_store.saveFileHashes(context.io, allocator, cache_dir, &pruned, log) catch |err| {
        if (an) annotate(log, "hashFileTree-cache-will-not-write", "", .{});
        return context.fail.set("Failed to write the file hash cache in \"{s}\": {s}", .{ cache_dir, files.describeError(err) });
    };

    return .{
        .config_path = config_path,
        .root_dir = root_dir,
        .config = config,
        .cache_dir = cache_dir,
        .file_paths = file_paths,
        .file_hashes = hashed.hashes,
        .unreadable = hashed.unreadable,
    };
}

//
// Hashes the tree and compares it against the baseline, printing what it found to `context.out` and
// returning the exit code the process should use.
//
// All three of "summary", "changes" and "targets" are this one function with a different `mode`, so
// the comparison happens once and only the rendering differs. Two views cannot disagree about what
// changed because there is only ever one comparison for them to disagree about.
//
pub fn compareFileTree(context: *const Context, request: ReportRequest) failure.Error!u8 {
    const log = context.fail.log;
    const allocator = context.allocator;

    var tree = try hashFileTree(context, request.options);

    //
    // The baseline is filtered by the same rule as the file list. Without this, adding an extension
    // to ignore would report every already-recorded file of that type as deleted.
    //
    const baseline_path = try files.resolvePath(allocator, tree.root_dir, tree.config.baseline_path);
    const loaded = (try baseline_store.loadBaseline(context.io, allocator, baseline_path, log)).baseline;
    const baseline = try filterIgnoredBaseline(allocator, &loaded, tree.config.ignore, log);

    const format = try output_module.parseOutputFormat(request.options.output, context.fail);

    //
    // An empty baseline is not a special case, it is the case where nothing has been seen before, so
    // every file diffs as added. Falling out of the ordinary comparison rather than short-circuiting
    // is what keeps the views agreeing: it is not possible for "targets" to say everything is
    // affected while "changes" says there is nothing to report.
    //
    const has_baseline = baseline.targets.count() > 0;
    const categorized = try categorize.categorizeChanges(allocator, &tree.config, &tree.file_hashes, tree.unreadable, &baseline, context.platform, log);

    //
    // A target that cannot run on this platform never has changed files, so this cannot name one.
    //
    // A config holds at least one target, because `parseConfig` refuses one that does not, and
    // there is one of these per target.
    std.debug.assert(categorized.targets.len > 0);

    var target_names: std.ArrayList([]const u8) = .empty;
    for (categorized.targets) |target| {
        if (an) annotate(log, "compareFileTree-targets-iteration", "", .{});
        if (target.changed_files.len > 0) {
            if (an) annotate(log, "compareFileTree-target-affected", "", .{});
            try target_names.append(allocator, target.name);
        }
    }

    try renderReport(allocator, context.out, .{
        .has_baseline = has_baseline,
        //
        // Every file that was listed, not every file that was hashed. A deleted or unreadable file
        // was still checked, and leaving it out would make the count drop for a reason the report
        // goes on to name.
        //
        .file_count = tree.file_paths.len,
        .changes = try allChangedFiles(allocator, categorized, log),
        .categorized = categorized,
        .target_names = try target_names.toOwnedSlice(allocator),
    }, request.mode, format);

    return 0;
}

//
// Every changed file across every target, plus the ones no target watches, deduplicated by path and
// sorted.
//
// Targets overlap, so the same file routinely appears under several of them. This is what the flat
// "changes" view shows, and building it from the same per-target results the summary uses is what
// stops the two views disagreeing.
//
pub fn allChangedFiles(allocator: std.mem.Allocator, categorized: CategorizedChanges, log: Log) std.mem.Allocator.Error![]ChangedFile {
    var by_path: std.StringArrayHashMapUnmanaged(ChangedFile) = .empty;

    for (categorized.targets) |target| {
        if (an) annotate(log, "allChangedFiles-targets-iteration", "", .{});
        for (target.changed_files) |change| {
            if (an) annotate(log, "allChangedFiles-changes-iteration", "", .{});
            try by_path.put(allocator, change.path, change);
        }
    }
    for (categorized.unwatched_files) |change| {
        if (an) annotate(log, "allChangedFiles-unwatched-iteration", "", .{});
        try by_path.put(allocator, change.path, change);
    }

    const changes = try allocator.dupe(ChangedFile, by_path.values());
    std.mem.sort(ChangedFile, changes, changed_files.Ordering{ .log = log }, lessThanChangedFile);
    return changes;
}

//
// Orders two changes by path, for sorting.
//
fn lessThanChangedFile(_: changed_files.Ordering, left: ChangedFile, right: ChangedFile) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

//
// Renders a result in the view and format that were asked for.
//
pub fn renderReport(allocator: std.mem.Allocator, out: *Output, result: ReportResult, mode: ReportMode, format: OutputFormat) std.mem.Allocator.Error!void {
    if (format != .text) {
        if (an) annotate(out.log, "renderReport-machine-readable", "", .{});
        return output_module.printStructured(allocator, out, try structuredReport(allocator, result, mode, out.log), format);
    }

    if (mode == .targets) {
        if (an) annotate(out.log, "renderReport-target-names-only", "", .{});
        return reportTargetNames(out, result.target_names);
    }

    //
    // Said before the listing rather than instead of it. With no baseline every file really has
    // changed as far as this tool is concerned, so the files are still listed; this only explains
    // why the list is the whole project.
    //
    if (!result.has_baseline) {
        if (an) annotate(out.log, "renderReport-no-baseline", "", .{});
        out.line("No baseline recorded yet, so every file counts as new. {d} file(s) in the working tree.", .{result.file_count});
        out.blank();
    }

    if (mode == .files) {
        if (an) annotate(out.log, "renderReport-a-flat-list", "", .{});
        return reportChangedFiles(allocator, out, result.changes, result.file_count);
    }

    return reportCategorizedChanges(allocator, out, result.categorized, result.changes, result.file_count);
}

//
// Turns a result into the object the machine-readable formats render.
//
// Each view renders only what that view is about, so a caller asking for "targets" gets a list of
// names rather than a whole report it then has to dig through.
//
pub fn structuredReport(allocator: std.mem.Allocator, result: ReportResult, mode: ReportMode, log: Log) std.mem.Allocator.Error!Value {
    if (mode == .targets) {
        if (an) annotate(log, "structuredReport-target-names-only", "", .{});
        var names = value.newArray(allocator);
        for (result.target_names) |name| {
            if (an) annotate(log, "structuredReport-names-iteration", "", .{});
            try names.append(value.str(name));
        }

        var object: value.Object = .empty;
        try object.put(allocator, "targets", .{ .array = names });
        return .{ .object = object };
    }

    if (mode == .files) {
        if (an) annotate(log, "structuredReport-a-flat-list", "", .{});
        var object: value.Object = .empty;
        try object.put(allocator, "hasBaseline", value.boolean(result.has_baseline));
        try object.put(allocator, "fileCount", value.int(@intCast(result.file_count)));
        try object.put(allocator, "changed", try changed_files.toValueArray(allocator, result.changes, log));
        return .{ .object = object };
    }

    var targets = value.newArray(allocator);
    for (result.categorized.targets) |target| {
        if (an) annotate(log, "structuredReport-targets-iteration", "", .{});
        var watched = value.newArray(allocator);
        for (target.watched_paths) |watched_path| {
            if (an) annotate(log, "structuredReport-watched-iteration", "", .{});
            try watched.append(value.str(watched_path));
        }

        var entry: value.Object = .empty;
        try entry.put(allocator, "name", value.str(target.name));
        try entry.put(allocator, "watchedPaths", .{ .array = watched });
        try entry.put(allocator, "appliesHere", value.boolean(target.applies_here));
        try entry.put(allocator, "changed", try changed_files.toValueArray(allocator, target.changed_files, log));
        try targets.append(.{ .object = entry });
    }

    var object: value.Object = .empty;
    try object.put(allocator, "hasBaseline", value.boolean(result.has_baseline));
    try object.put(allocator, "fileCount", value.int(@intCast(result.file_count)));
    try object.put(allocator, "targets", .{ .array = targets });
    try object.put(allocator, "unwatched", try changed_files.toValueArray(allocator, result.categorized.unwatched_files, log));
    return .{ .object = object };
}

//
// Names every target in the config that can run on this platform, whatever has changed.
//
// This reads the config and nothing else: no file listing, no hashing, no baseline. It answers "what
// could this project run here", which is a question about the config rather than about the working
// tree, so it needs neither a git repository nor a recorded baseline.
//
pub fn listTargets(context: *const Context, options: ReportOptions) failure.Error!u8 {
    const log = context.fail.log;
    const allocator = context.allocator;

    const config_path = try config_module.resolveConfigPath(context.io, allocator, options.config, context.cwd, context.fail);
    const config = try config_module.loadConfig(context.io, allocator, config_path, context.fail);
    const format = try output_module.parseOutputFormat(options.output, context.fail);

    // As above: a config that parsed holds at least one target.
    std.debug.assert(config.targets.len > 0);

    var names: std.ArrayList([]const u8) = .empty;
    for (config.targets) |*target| {
        if (an) annotate(log, "listTargets-targets-iteration", "", .{});
        if (categorize.targetAppliesToPlatform(target, context.platform, log)) {
            if (an) annotate(log, "listTargets-runs-here", "", .{});
            try names.append(allocator, target.name);
        }
    }

    if (format != .text) {
        if (an) annotate(log, "listTargets-machine-readable", "", .{});
        var rendered = value.newArray(allocator);
        for (names.items) |name| {
            if (an) annotate(log, "listTargets-names-iteration", "", .{});
            try rendered.append(value.str(name));
        }

        var object: value.Object = .empty;
        try object.put(allocator, "targets", .{ .array = rendered });
        try output_module.printStructured(allocator, context.out, .{ .object = object }, format);
        return 0;
    }

    reportTargetNames(context.out, names.items);
    return 0;
}

//
// Records the current tree as the baseline that later reports measure against.
//
pub fn runBaseline(context: *const Context, options: ReportOptions, target_names: []const []const u8) failure.Error!u8 {
    const log = context.fail.log;
    const allocator = context.allocator;

    var tree = try hashFileTree(context, options);

    //
    // An unknown name is refused rather than ignored. Capturing a name that matches no target would
    // report success while recording nothing, and the caller would believe a suite had been marked
    // as passed when it had not.
    //
    // As above: a config that parsed holds at least one target.
    std.debug.assert(tree.config.targets.len > 0);

    for (target_names) |requested| {
        if (an) annotate(log, "runBaseline-requested-iteration", "", .{});
        var known = false;
        for (tree.config.targets) |target| {
            if (an) annotate(log, "runBaseline-known-iteration", "", .{});
            if (std.mem.eql(u8, target.name, requested)) {
                if (an) annotate(log, "runBaseline-a-known-name", "", .{});
                known = true;
            }
        }
        if (!known) {
            if (an) annotate(log, "runBaseline-an-unknown-name", "", .{});
            return context.fail.set("\"{s}\" is not a target in \"{s}\". Known targets: {s}", .{
                requested, tree.config_path, try joinTargetNames(allocator, tree.config, log),
            });
        }
    }

    //
    // With no names every target is captured, which is what a run of the whole set means. With names
    // only those are, and every other target's record is left exactly as it was, because nothing new
    // is known about them.
    //
    var to_capture: std.ArrayList(config_module.TargetConfig) = .empty;
    for (tree.config.targets) |target| {
        if (an) annotate(log, "runBaseline-config-targets-iteration", "", .{});
        if (target_names.len == 0 or containsName(target_names, target.name, log)) {
            if (an) annotate(log, "runBaseline-capturing-this-one", "", .{});
            try to_capture.append(allocator, target);
        }
    }

    // With no names every target is captured, and with names every one of them has already been
    // matched against a target above, so there is always at least one.
    std.debug.assert(to_capture.items.len > 0);

    var captured: baseline_store.TargetBaselines = .empty;
    for (to_capture.items) |*target| {
        if (an) annotate(log, "runBaseline-capturing-iteration", "", .{});
        try captured.put(allocator, target.name, try categorize.capturedFilesFor(allocator, &tree.config, target, &tree.file_hashes, log));
    }

    const baseline_path = try files.resolvePath(allocator, tree.root_dir, tree.config.baseline_path);
    try baseline_store.captureTargets(context.io, allocator, baseline_path, &captured, tree.file_hashes, context.fail);

    var names: std.ArrayList([]const u8) = .empty;
    for (to_capture.items) |target| {
        if (an) annotate(log, "runBaseline-naming-iteration", "", .{});
        try names.append(allocator, target.name);
    }

    context.out.line("Captured the baseline for {d} target(s): {s}.", .{
        to_capture.items.len, try std.mem.join(allocator, ", ", names.items),
    });
    return 0;
}

//
// True when a name is in the list.
//
pub fn containsName(names: []const []const u8, name: []const u8, log: Log) bool {
    for (names) |candidate| {
        if (an) annotate(log, "containsName-names-iteration", "", .{});
        if (std.mem.eql(u8, candidate, name)) {
            if (an) annotate(log, "containsName-found", "", .{});
            return true;
        }
    }
    return false;
}

//
// Every target name in the config, comma separated, for the message that refuses an unknown one.
//
pub fn joinTargetNames(allocator: std.mem.Allocator, config: Config, log: Log) std.mem.Allocator.Error![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (config.targets) |target| {
        if (an) annotate(log, "joinTargetNames-targets-iteration", "", .{});
        try names.append(allocator, target.name);
    }
    return std.mem.join(allocator, ", ", names.items);
}

//
// Rehashes the current tree and stores the result in the file hash cache, recording no baseline.
//
// Only ever a speed-up: what a later report says has changed is decided by the baseline, which this
// does not touch.
//
pub fn runCacheCapture(context: *const Context, options: ReportOptions) failure.Error!u8 {
    var tree = try hashFileTree(context, options);

    context.out.line("Cache captured. {d} file hash(es) stored. The baseline is untouched.", .{tree.file_hashes.count()});
    return 0;
}

//
// Prints one target name per line and nothing else, so a shell script can read the list without
// having to pick it out of prose. Nothing changed means no output at all, which reads as an empty
// list rather than as a line a script would have to special-case.
//
pub fn reportTargetNames(out: *Output, names: []const []const u8) void {
    for (names) |name| {
        if (an) annotate(out.log, "reportTargetNames-names-iteration", "", .{});
        out.line("{s}", .{name});
    }
}

//
// Drops the ignored extensions from a recorded baseline, so a change to ignore does not read as a
// pile of deletions on the next run.
//
pub fn filterIgnoredBaseline(allocator: std.mem.Allocator, baseline: *const Baseline, ignore: []const []const u8, log: Log) std.mem.Allocator.Error!Baseline {
    if (ignore.len == 0) {
        if (an) annotate(log, "filterIgnoredBaseline-nothing-ignored", "", .{});
        return baseline.*;
    }

    var targets: baseline_store.TargetBaselines = .empty;
    var walker = baseline.targets.iterator();
    while (walker.next()) |entry| {
        if (an) annotate(log, "filterIgnoredBaseline-targets-iteration", "", .{});
        try targets.put(allocator, entry.key_ptr.*, try filterIgnoredFileHashes(allocator, entry.value_ptr, ignore, log));
    }

    return .{
        .targets = targets,
        .files = try filterIgnoredFileHashes(allocator, &baseline.files, ignore, log),
    };
}

//
// Drops the ignored extensions from one set of recorded file hashes.
//
pub fn filterIgnoredFileHashes(allocator: std.mem.Allocator, recorded: *const FileHashes, ignore: []const []const u8, log: Log) std.mem.Allocator.Error!FileHashes {
    var filtered: FileHashes = .empty;

    var walker = recorded.iterator();
    while (walker.next()) |entry| {
        if (an) annotate(log, "filterIgnoredFileHashes-recorded-iteration", "", .{});
        if (!list_files.isIgnoredFile(entry.key_ptr.*, ignore, log)) {
            if (an) annotate(log, "filterIgnoredFileHashes-kept", "", .{});
            try filtered.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return filtered;
}

//
// Prints every file that differs from the baseline, with its hash. This is the flat view, for "what
// have I actually touched", as opposed to the per-target view below.
//
pub fn reportChangedFiles(allocator: std.mem.Allocator, out: *Output, changes: []const ChangedFile, file_count: usize) std.mem.Allocator.Error!void {
    if (changes.len == 0) {
        if (an) annotate(out.log, "reportChangedFiles-nothing-changed", "", .{});
        out.line("No files have changed since the baseline. {d} file(s) checked.", .{file_count});
        return;
    }

    out.line("Changed since the baseline:", .{});
    for (try changed_files.formatChangedFiles(allocator, changes, out.log)) |line| {
        if (an) annotate(out.log, "reportChangedFiles-lines-iteration", "", .{});
        out.line("{s}", .{line});
    }
    out.blank();
    out.line("{d} changed, {d} file(s) checked.", .{ changes.len, file_count });
}

//
// Prints each target with the changed files that fall under it, then any changed file that no target
// watches. This is the main view: it answers "what changed, and what does it affect".
//
pub fn reportCategorizedChanges(allocator: std.mem.Allocator, out: *Output, categorized: CategorizedChanges, changes: []const ChangedFile, file_count: usize) std.mem.Allocator.Error!void {
    if (changes.len == 0) {
        if (an) annotate(out.log, "reportCategorizedChanges-nothing-changed", "", .{});
        out.line("No files have changed since the baseline. {d} file(s) checked.", .{file_count});
        return;
    }

    out.line("Changed since the baseline:", .{});
    out.blank();

    for (categorized.targets) |target| {
        if (an) annotate(out.log, "reportCategorizedChanges-targets-iteration", "", .{});
        //
        // Said rather than left out. "unchanged" would be a lie about a target that could not have
        // run whatever changed, and dropping the line entirely would leave someone wondering whether
        // they had misspelled the target's name.
        //
        if (!target.applies_here) {
            if (an) annotate(out.log, "reportCategorizedChanges-wrong-platform", "", .{});
            out.line("  {s}: wrong-platform", .{target.name});
            continue;
        }
        if (target.changed_files.len == 0) {
            if (an) annotate(out.log, "reportCategorizedChanges-target-unchanged", "", .{});
            out.line("  {s}: unchanged", .{target.name});
            continue;
        }
        out.line("  {s}: {d} changed", .{ target.name, target.changed_files.len });
        for (try changed_files.formatChangedFiles(allocator, target.changed_files, out.log)) |line| {
            if (an) annotate(out.log, "reportCategorizedChanges-target-lines-iteration", "", .{});
            out.line("  {s}", .{line});
        }
    }

    if (categorized.unwatched_files.len > 0) {
        if (an) annotate(out.log, "reportCategorizedChanges-some-unwatched", "", .{});
        out.blank();
        out.line("  Watched by no target: {d} changed", .{categorized.unwatched_files.len});
        for (try changed_files.formatChangedFiles(allocator, categorized.unwatched_files, out.log)) |line| {
            if (an) annotate(out.log, "reportCategorizedChanges-unwatched-lines-iteration", "", .{});
            out.line("  {s}", .{line});
        }
    }

    out.blank();
    out.line("{d} changed, {d} file(s) checked.", .{ changes.len, file_count });
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("run.test.zig");
}
