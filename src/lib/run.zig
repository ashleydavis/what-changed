const std = @import("std");
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
    unreadable: [][]const u8,
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
    const allocator = context.allocator;

    const config_path = try config_module.resolveConfigPath(context.io, allocator, options.config, context.cwd, context.fail);
    const root_dir = files.dirName(config_path);
    const config = try config_module.loadConfig(context.io, allocator, config_path, context.fail);

    const cache_dir = try files.resolvePath(allocator, root_dir, config.cache_dir);
    var cache = try cache_store.loadCache(context.io, allocator, cache_dir);

    const listed = try context.list_files(context.io, context.environ, allocator, root_dir, context.fail);
    const file_paths = try list_files.filterIgnoredFiles(allocator, listed, config.ignore);
    const hashed = try file_hash.hashFiles(context.io, allocator, root_dir, file_paths, &cache.file_hashes);

    var pruned = try cache_store.pruneFileHashes(allocator, &cache.file_hashes, file_paths);
    cache_store.saveFileHashes(context.io, allocator, cache_dir, &pruned) catch |err| {
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
    const allocator = context.allocator;

    var tree = try hashFileTree(context, request.options);

    //
    // The baseline is filtered by the same rule as the file list. Without this, adding an extension
    // to ignore would report every already-recorded file of that type as deleted.
    //
    const baseline_path = try files.resolvePath(allocator, tree.root_dir, tree.config.baseline_path);
    const loaded = try baseline_store.loadBaseline(context.io, allocator, baseline_path);
    const baseline = try filterIgnoredBaseline(allocator, &loaded, tree.config.ignore);

    const format = try output_module.parseOutputFormat(request.options.output, context.fail);

    //
    // An empty baseline is not a special case, it is the case where nothing has been seen before, so
    // every file diffs as added. Falling out of the ordinary comparison rather than short-circuiting
    // is what keeps the views agreeing: it is not possible for "targets" to say everything is
    // affected while "changes" says there is nothing to report.
    //
    const has_baseline = baseline.targets.count() > 0;
    const categorized = try categorize.categorizeChanges(allocator, &tree.config, &tree.file_hashes, tree.unreadable, &baseline, context.platform);

    //
    // A target that cannot run on this platform never has changed files, so this cannot name one.
    //
    var target_names: std.ArrayList([]const u8) = .empty;
    for (categorized.targets) |target| {
        if (target.changed_files.len > 0) {
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
        .changes = try allChangedFiles(allocator, categorized),
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
pub fn allChangedFiles(allocator: std.mem.Allocator, categorized: CategorizedChanges) std.mem.Allocator.Error![]ChangedFile {
    var by_path: std.StringArrayHashMapUnmanaged(ChangedFile) = .empty;

    for (categorized.targets) |target| {
        for (target.changed_files) |change| {
            try by_path.put(allocator, change.path, change);
        }
    }
    for (categorized.unwatched_files) |change| {
        try by_path.put(allocator, change.path, change);
    }

    const changes = try allocator.dupe(ChangedFile, by_path.values());
    std.mem.sort(ChangedFile, changes, {}, lessThanChangedFile);
    return changes;
}

//
// Orders two changes by path, for sorting.
//
fn lessThanChangedFile(_: void, left: ChangedFile, right: ChangedFile) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

//
// Renders a result in the view and format that were asked for.
//
pub fn renderReport(allocator: std.mem.Allocator, out: *Output, result: ReportResult, mode: ReportMode, format: OutputFormat) std.mem.Allocator.Error!void {
    if (format != .text) {
        return output_module.printStructured(allocator, out, try structuredReport(allocator, result, mode), format);
    }

    if (mode == .targets) {
        return reportTargetNames(out, result.target_names);
    }

    //
    // Said before the listing rather than instead of it. With no baseline every file really has
    // changed as far as this tool is concerned, so the files are still listed; this only explains
    // why the list is the whole project.
    //
    if (!result.has_baseline) {
        out.line("No baseline recorded yet, so every file counts as new. {d} file(s) in the working tree.", .{result.file_count});
        out.blank();
    }

    if (mode == .files) {
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
pub fn structuredReport(allocator: std.mem.Allocator, result: ReportResult, mode: ReportMode) std.mem.Allocator.Error!Value {
    if (mode == .targets) {
        var names = value.newArray(allocator);
        for (result.target_names) |name| {
            try names.append(value.str(name));
        }

        var object = value.newObject(allocator);
        try object.put(allocator, "targets", .{ .array = names });
        return .{ .object = object };
    }

    if (mode == .files) {
        var object = value.newObject(allocator);
        try object.put(allocator, "hasBaseline", value.boolean(result.has_baseline));
        try object.put(allocator, "fileCount", value.int(@intCast(result.file_count)));
        try object.put(allocator, "changed", try changed_files.toValueArray(allocator, result.changes));
        return .{ .object = object };
    }

    var targets = value.newArray(allocator);
    for (result.categorized.targets) |target| {
        var watched = value.newArray(allocator);
        for (target.watched_paths) |watched_path| {
            try watched.append(value.str(watched_path));
        }

        var entry = value.newObject(allocator);
        try entry.put(allocator, "name", value.str(target.name));
        try entry.put(allocator, "watchedPaths", .{ .array = watched });
        try entry.put(allocator, "appliesHere", value.boolean(target.applies_here));
        try entry.put(allocator, "changed", try changed_files.toValueArray(allocator, target.changed_files));
        try targets.append(.{ .object = entry });
    }

    var object = value.newObject(allocator);
    try object.put(allocator, "hasBaseline", value.boolean(result.has_baseline));
    try object.put(allocator, "fileCount", value.int(@intCast(result.file_count)));
    try object.put(allocator, "targets", .{ .array = targets });
    try object.put(allocator, "unwatched", try changed_files.toValueArray(allocator, result.categorized.unwatched_files));
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
    const allocator = context.allocator;

    const config_path = try config_module.resolveConfigPath(context.io, allocator, options.config, context.cwd, context.fail);
    const config = try config_module.loadConfig(context.io, allocator, config_path, context.fail);
    const format = try output_module.parseOutputFormat(options.output, context.fail);

    var names: std.ArrayList([]const u8) = .empty;
    for (config.targets) |*target| {
        if (categorize.targetAppliesToPlatform(target, context.platform)) {
            try names.append(allocator, target.name);
        }
    }

    if (format != .text) {
        var rendered = value.newArray(allocator);
        for (names.items) |name| {
            try rendered.append(value.str(name));
        }

        var object = value.newObject(allocator);
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
    const allocator = context.allocator;

    var tree = try hashFileTree(context, options);

    //
    // An unknown name is refused rather than ignored. Capturing a name that matches no target would
    // report success while recording nothing, and the caller would believe a suite had been marked
    // as passed when it had not.
    //
    for (target_names) |requested| {
        var known = false;
        for (tree.config.targets) |target| {
            if (std.mem.eql(u8, target.name, requested)) known = true;
        }
        if (!known) {
            return context.fail.set("\"{s}\" is not a target in \"{s}\". Known targets: {s}", .{
                requested, tree.config_path, try joinTargetNames(allocator, tree.config),
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
        if (target_names.len == 0 or containsName(target_names, target.name)) {
            try to_capture.append(allocator, target);
        }
    }

    var captured: baseline_store.TargetBaselines = .empty;
    for (to_capture.items) |*target| {
        try captured.put(allocator, target.name, try categorize.capturedFilesFor(allocator, &tree.config, target, &tree.file_hashes));
    }

    const baseline_path = try files.resolvePath(allocator, tree.root_dir, tree.config.baseline_path);
    try baseline_store.captureTargets(context.io, allocator, baseline_path, &captured, tree.file_hashes, context.fail);

    var names: std.ArrayList([]const u8) = .empty;
    for (to_capture.items) |target| {
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
fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

//
// Every target name in the config, comma separated, for the message that refuses an unknown one.
//
fn joinTargetNames(allocator: std.mem.Allocator, config: Config) std.mem.Allocator.Error![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (config.targets) |target| {
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
        out.line("{s}", .{name});
    }
}

//
// Drops the ignored extensions from a recorded baseline, so a change to ignore does not read as a
// pile of deletions on the next run.
//
pub fn filterIgnoredBaseline(allocator: std.mem.Allocator, baseline: *const Baseline, ignore: []const []const u8) std.mem.Allocator.Error!Baseline {
    if (ignore.len == 0) {
        return baseline.*;
    }

    var targets: baseline_store.TargetBaselines = .empty;
    var walker = baseline.targets.iterator();
    while (walker.next()) |entry| {
        try targets.put(allocator, entry.key_ptr.*, try filterIgnoredFileHashes(allocator, entry.value_ptr, ignore));
    }

    return .{
        .targets = targets,
        .files = try filterIgnoredFileHashes(allocator, &baseline.files, ignore),
    };
}

//
// Drops the ignored extensions from one set of recorded file hashes.
//
pub fn filterIgnoredFileHashes(allocator: std.mem.Allocator, recorded: *const FileHashes, ignore: []const []const u8) std.mem.Allocator.Error!FileHashes {
    var filtered: FileHashes = .empty;

    var walker = recorded.iterator();
    while (walker.next()) |entry| {
        if (!list_files.isIgnoredFile(entry.key_ptr.*, ignore)) {
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
        out.line("No files have changed since the baseline. {d} file(s) checked.", .{file_count});
        return;
    }

    out.line("Changed since the baseline:", .{});
    for (try changed_files.formatChangedFiles(allocator, changes)) |line| {
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
        out.line("No files have changed since the baseline. {d} file(s) checked.", .{file_count});
        return;
    }

    out.line("Changed since the baseline:", .{});
    out.blank();

    for (categorized.targets) |target| {
        //
        // Said rather than left out. "unchanged" would be a lie about a target that could not have
        // run whatever changed, and dropping the line entirely would leave someone wondering whether
        // they had misspelled the target's name.
        //
        if (!target.applies_here) {
            out.line("  {s}: wrong-platform", .{target.name});
            continue;
        }
        if (target.changed_files.len == 0) {
            out.line("  {s}: unchanged", .{target.name});
            continue;
        }
        out.line("  {s}: {d} changed", .{ target.name, target.changed_files.len });
        for (try changed_files.formatChangedFiles(allocator, target.changed_files)) |line| {
            out.line("  {s}", .{line});
        }
    }

    if (categorized.unwatched_files.len > 0) {
        out.blank();
        out.line("  Watched by no target: {d} changed", .{categorized.unwatched_files.len});
        for (try changed_files.formatChangedFiles(allocator, categorized.unwatched_files)) |line| {
            out.line("  {s}", .{line});
        }
    }

    out.blank();
    out.line("{d} changed, {d} file(s) checked.", .{ changes.len, file_count });
}

const testing = std.testing;

//
// A file lister that answers with a fixed list, so the flow can be driven without a git repository.
//
// The list is a module-level value because a Zig function pointer carries no captured state, so the
// fake lister has nowhere else to keep it. A test sets it just before the run it belongs to.
//
var fake_file_list: []const []const u8 = &.{};

fn fakeLister(io: std.Io, environ: *const std.process.Environ.Map, allocator: std.mem.Allocator, root_dir: []const u8, fail: *Failure) failure.Error![][]const u8 {
    _ = io;
    _ = environ;
    _ = root_dir;
    _ = fail;
    return allocator.dupe([]const u8, fake_file_list);
}

//
// A file lister that fails the way a directory outside a git repository does.
//
fn failingLister(io: std.Io, environ: *const std.process.Environ.Map, allocator: std.mem.Allocator, root_dir: []const u8, fail: *Failure) failure.Error![][]const u8 {
    _ = io;
    _ = environ;
    _ = allocator;
    return fail.set("git ls-files failed in \"{s}\" with exit code 128: fatal: not a git repository", .{root_dir});
}

//
// Everything a run test needs: a throwaway project on disk, an `Io` of its own, and somewhere to
// collect what was printed.
//
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    test_io: files.TestIo,
    temporary: files.TemporaryDir,
    captured: std.Io.Writer.Allocating,
    out: Output,
    fail: Failure,

    //
    // Empty, because the fake lister never spawns anything. Held here so the context can point at a
    // real map rather than the test run's own environment.
    //
    environ: std.process.Environ.Map,

    //
    // Heap allocated, because the `Io` handed out points back at the `TestIo` inside this struct and
    // a copy of the struct would leave that pointer aimed at the wrong place.
    //
    fn create() !*Harness {
        const harness = try testing.allocator.create(Harness);
        harness.* = .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .test_io = .init(),
            .temporary = undefined,
            .captured = undefined,
            .out = undefined,
            .fail = undefined,
            .environ = undefined,
        };
        harness.temporary = try files.TemporaryDir.create(harness.test_io.io());
        harness.environ = std.process.Environ.Map.init(harness.arena.allocator());
        harness.captured = std.Io.Writer.Allocating.init(harness.arena.allocator());
        harness.out = .{ .writer = &harness.captured.writer };
        harness.fail = Failure.init(harness.arena.allocator());
        return harness;
    }

    fn destroy(self: *Harness) void {
        self.temporary.destroy();
        self.test_io.deinit();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    //
    // The `Io` everything this test does goes through.
    //
    fn io(self: *Harness) std.Io {
        return self.test_io.io();
    }

    fn allocator(self: *Harness) std.mem.Allocator {
        return self.arena.allocator();
    }

    //
    // Writes a config and the files it describes, and points the fake lister at them.
    //
    fn project(self: *Harness, config_text: []const u8, tree: []const struct { []const u8, []const u8 }) !void {
        try self.temporary.write("what-changed.yaml", config_text);

        var paths: std.ArrayList([]const u8) = .empty;
        for (tree) |entry| {
            try self.temporary.write(entry[0], entry[1]);
            try paths.append(self.allocator(), entry[0]);
        }
        fake_file_list = try paths.toOwnedSlice(self.allocator());
    }

    //
    // The context a run is driven with.
    //
    fn context(self: *Harness, platform: []const u8) Context {
        return .{
            .allocator = self.allocator(),
            .io = self.io(),
            .environ = &self.environ,
            .cwd = self.temporary.path,
            .list_files = fakeLister,
            .platform = platform,
            .out = &self.out,
            .fail = &self.fail,
        };
    }

    //
    // What has been printed so far.
    //
    fn printed(self: *Harness) []const u8 {
        return self.captured.written();
    }

    //
    // Forgets what has been printed, so one test can check several runs in turn.
    //
    fn clear(self: *Harness) void {
        self.captured.clearRetainingCapacity();
    }
};

//
// The config the flow tests use: two targets watching separate directories, ignoring markdown.
//
const TWO_TARGET_CONFIG =
    \\ignore:
    \\  - .md
    \\
    \\targets:
    \\  - name: unit
    \\    paths:
    \\      - src
    \\
    \\  - name: documentation
    \\    paths:
    \\      - documentation
;

test "report with no baseline says so and still lists every file" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{
        .{ "src/a.ts", "original source" },
        .{ "documentation/guide.txt", "original docs" },
    });

    const context = harness.context("linux");
    try testing.expectEqual(@as(u8, 0), try compareFileTree(&context, .{ .options = .{}, .mode = .summary }));

    try testing.expect(std.mem.indexOf(u8, harness.printed(), "No baseline recorded yet, so every file counts as new.") != null);
    //
    // The note explains the listing, it does not replace it. With no baseline every file really has
    // changed as far as this tool is concerned, so the files are still reported.
    //
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "src/a.ts") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "unit: 1 changed") != null);
}

test "report says nothing changed straight after a capture" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "original" }});
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    harness.clear();

    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "No files have changed since the baseline.") != null);
}

test "report puts an edit under the target that watches it and not the other" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{
        .{ "src/a.ts", "original" },
        .{ "documentation/guide.txt", "docs" },
    });
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");
    harness.clear();

    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "unit: 1 changed") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "documentation: unchanged") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "src/a.ts") != null);
}

test "report never mentions a file with an ignored extension" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{
        .{ "src/a.ts", "source" },
        .{ "src/notes.md", "notes" },
    });
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/notes.md", "edited notes");
    harness.clear();

    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "notes.md") == null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "No files have changed") != null);
}

test "report calls out a changed file no target watches" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{
        .{ "src/a.ts", "source" },
        .{ "stray/thing.ts", "stray" },
    });
    const context = harness.context("linux");

    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "Watched by no target") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "stray/thing.ts") != null);
}

test "report in files mode lists the changes flat, without grouping them" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");
    harness.clear();

    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .files });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "Changed since the baseline:") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "src/a.ts") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "unit:") == null);
}

test "report in targets mode prints one affected name per line and nothing else" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{
        .{ "src/a.ts", "source" },
        .{ "documentation/guide.txt", "docs" },
    });
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");
    harness.clear();

    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings("unit\n", harness.printed());
}

test "report in targets mode prints nothing when nothing changed" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    harness.clear();

    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings("", harness.printed());
}

test "reporting is not destructive: a second look reports the same change" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");

    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    const first = try harness.allocator().dupe(u8, harness.printed());

    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings(first, harness.printed());
}

test "report renders json and yaml from the same comparison" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");

    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{ .output = "json" }, .mode = .files });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"changed\"") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"kind\": \"modified\"") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "Changed since the baseline:") == null);

    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{ .output = "yaml" }, .mode = .files });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "changed:") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "kind: modified") != null);
}

test "report refuses an unknown output format" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    try testing.expectError(error.Failed, compareFileTree(&context, .{ .options = .{ .output = "xml" }, .mode = .files }));
    try testing.expect(std.mem.indexOf(u8, harness.fail.text(), "Unknown --output format") != null);
}

test "report says wrong-platform rather than unchanged, and json records it" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(
        \\targets:
        \\  - name: here-only
        \\    paths:
        \\      - src
        \\    platforms:
        \\      - linux
        \\
        \\  - name: elsewhere-only
        \\    paths:
        \\      - src
        \\    platforms:
        \\      - darwin
    , &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");

    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "elsewhere-only: wrong-platform") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "elsewhere-only: unchanged") == null);
    //
    // The file the wrong-platform target watches is still watched, so it is not called out as
    // watched by nothing.
    //
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "Watched by no target") == null);

    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "here-only") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "elsewhere-only") == null);

    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{ .output = "json" }, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"appliesHere\": false") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"appliesHere\": true") != null);
}

test "report reads the config named on the command line" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    try harness.temporary.write("other.yaml", "targets:\n  - name: other\n    paths:\n      - src\n");

    const context = harness.context("linux");
    _ = try compareFileTree(&context, .{ .options = .{ .config = "other.yaml" }, .mode = .targets });
    try testing.expectEqualStrings("other\n", harness.printed());
}

test "report fails and names the config that is not there" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    try testing.expectError(error.Failed, compareFileTree(&context, .{ .options = .{ .config = "definitely-not-here.yaml" }, .mode = .summary }));
    try testing.expect(std.mem.indexOf(u8, harness.fail.text(), "definitely-not-here.yaml") != null);
}

test "report passes on the file lister's failure" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{});

    var context = harness.context("linux");
    context.list_files = failingLister;

    try testing.expectError(error.Failed, compareFileTree(&context, .{ .options = .{}, .mode = .summary }));
    try testing.expect(std.mem.indexOf(u8, harness.fail.text(), "git ls-files failed") != null);
}

test "report does not read a file twice when the cache is warm" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .targets });

    //
    // The cache is written by every run, so the second one finds an entry whose mtime and size still
    // match and answers from it.
    //
    var cache = try cache_store.loadCache(harness.io(), harness.allocator(), try harness.temporary.join(harness.allocator(), ".what-changed/cache"));
    try testing.expectEqual(@as(usize, 1), cache.file_hashes.count());
    try testing.expectEqual(@as(u64, 6), cache.file_hashes.get("src/a.ts").?.size);
}

test "runBaseline captures every target when none is named" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{
        .{ "src/a.ts", "source" },
        .{ "documentation/guide.txt", "docs" },
    });
    const context = harness.context("linux");

    try testing.expectEqual(@as(u8, 0), try runBaseline(&context, .{}, &.{}));
    try testing.expectEqualStrings("Captured the baseline for 2 target(s): unit, documentation.\n", harness.printed());

    var baseline = try baseline_store.loadBaseline(harness.io(), harness.allocator(), try harness.temporary.join(harness.allocator(), ".what-changed/baseline.json"));
    try testing.expectEqual(@as(usize, 2), baseline.targets.count());
}

test "runBaseline captures only the named target and leaves the others affected" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{
        .{ "src/a.ts", "source" },
        .{ "documentation/guide.txt", "docs" },
    });
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "changed for both");
    try harness.temporary.write("documentation/guide.txt", "changed for both");

    harness.clear();
    _ = try runBaseline(&context, .{}, &.{"unit"});
    try testing.expectEqualStrings("Captured the baseline for 1 target(s): unit.\n", harness.printed());

    //
    // The rule the per-target baseline exists for. Capturing "unit" after the unit suite passed must
    // not mark "documentation" as up to date, because that suite never ran.
    //
    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings("documentation\n", harness.printed());
}

test "runBaseline refuses an unknown target name and names the known ones" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    try testing.expectError(error.Failed, runBaseline(&context, .{}, &.{"nosuchtarget"}));
    try testing.expect(std.mem.indexOf(u8, harness.fail.text(), "\"nosuchtarget\" is not a target in") != null);
    try testing.expect(std.mem.indexOf(u8, harness.fail.text(), "Known targets: unit, documentation") != null);
}

test "runBaseline records nothing at all when one of the names is unknown" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    try testing.expectError(error.Failed, runBaseline(&context, .{}, &.{ "unit", "nosuchtarget" }));

    //
    // Refused as a whole rather than partly applied. A capture that recorded "unit" and then failed
    // would leave the caller believing nothing had been recorded when something had.
    //
    var baseline = try baseline_store.loadBaseline(harness.io(), harness.allocator(), try harness.temporary.join(harness.allocator(), ".what-changed/baseline.json"));
    try testing.expectEqual(@as(usize, 0), baseline.targets.count());
}

test "runBaseline records only what each target watches" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{
        .{ "src/a.ts", "source" },
        .{ "documentation/guide.txt", "docs" },
        .{ "stray/x.ts", "stray" },
    });
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});

    var baseline = try baseline_store.loadBaseline(harness.io(), harness.allocator(), try harness.temporary.join(harness.allocator(), ".what-changed/baseline.json"));
    try testing.expectEqual(@as(usize, 1), baseline.targets.get("unit").?.count());
    try testing.expect(baseline.targets.get("unit").?.get("stray/x.ts") == null);

    //
    // The whole-tree record holds everything, which is what the unwatched comparison needs.
    //
    try testing.expectEqual(@as(usize, 3), baseline.files.count());
}

test "runCacheCapture stores the hashes and touches no baseline" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{ .{ "src/a.ts", "source" }, .{ "documentation/guide.txt", "docs" } });
    const context = harness.context("linux");

    try testing.expectEqual(@as(u8, 0), try runCacheCapture(&context, .{}));
    try testing.expectEqualStrings("Cache captured. 2 file hash(es) stored. The baseline is untouched.\n", harness.printed());

    var cache = try cache_store.loadCache(harness.io(), harness.allocator(), try harness.temporary.join(harness.allocator(), ".what-changed/cache"));
    try testing.expectEqual(@as(usize, 2), cache.file_hashes.count());

    //
    // Nothing about what is reported has changed, which is the difference between the cache and the
    // baseline.
    //
    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "No baseline recorded yet") != null);
}

test "listTargets names every runnable target whatever has changed" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(
        \\targets:
        \\  - name: unit
        \\    paths:
        \\      - src
        \\  - name: here-only
        \\    paths:
        \\      - src
        \\    platforms:
        \\      - linux
        \\  - name: elsewhere-only
        \\    paths:
        \\      - src
        \\    platforms:
        \\      - darwin
    , &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});
    harness.clear();

    //
    // Nothing has changed, so "targets" names none, but "targets list" names them all the same.
    //
    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings("", harness.printed());

    harness.clear();
    try testing.expectEqual(@as(u8, 0), try listTargets(&context, .{}));
    try testing.expectEqualStrings("unit\nhere-only\n", harness.printed());
}

test "listTargets renders json when asked" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try listTargets(&context, .{ .output = "json" });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"targets\"") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"unit\"") != null);
}

test "listTargets needs neither a baseline nor a file listing" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{});

    var context = harness.context("linux");
    context.list_files = failingLister;

    //
    // The lister would fail if it were called. That it is not is the point: "what could run here" is
    // a question about the config, so it works outside a git repository.
    //
    try testing.expectEqual(@as(u8, 0), try listTargets(&context, .{}));
    try testing.expectEqualStrings("unit\ndocumentation\n", harness.printed());
}

test "allChangedFiles deduplicates a file watched by several targets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const change = ChangedFile{ .path = "src/a.ts", .kind = .modified, .hash = "new", .previous_hash = "old" };
    var shared = [_]ChangedFile{change};
    var stray = [_]ChangedFile{.{ .path = "stray/x.ts", .kind = .added, .hash = "1", .previous_hash = "" }};

    var targets = [_]categorize.TargetChanges{
        .{ .name = "a", .watched_paths = &.{}, .applies_here = true, .ever_captured = true, .changed_files = &shared },
        .{ .name = "b", .watched_paths = &.{}, .applies_here = true, .ever_captured = true, .changed_files = &shared },
    };

    const all = try allChangedFiles(allocator, .{ .targets = &targets, .unwatched_files = &stray });
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("src/a.ts", all[0].path);
    try testing.expectEqualStrings("stray/x.ts", all[1].path);
}

test "allChangedFiles of nothing is nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try allChangedFiles(allocator, .{ .targets = &.{}, .unwatched_files = &.{} })).len);
}

test "structuredReport renders only what each view is about" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var changes = [_]ChangedFile{.{ .path = "src/a.ts", .kind = .added, .hash = "1", .previous_hash = "" }};
    var watched = [_][]const u8{"src"};
    var targets = [_]categorize.TargetChanges{
        .{ .name = "unit", .watched_paths = &watched, .applies_here = true, .ever_captured = false, .changed_files = &changes },
    };
    var names = [_][]const u8{"unit"};

    const result = ReportResult{
        .has_baseline = false,
        .file_count = 3,
        .changes = &changes,
        .categorized = .{ .targets = &targets, .unwatched_files = &.{} },
        .target_names = &names,
    };

    const as_targets = try structuredReport(allocator, result, .targets);
    try testing.expectEqual(@as(usize, 1), as_targets.object.count());
    try testing.expectEqualStrings("unit", value.get(as_targets, "targets").?.array.items[0].string);

    const as_files = try structuredReport(allocator, result, .files);
    try testing.expectEqual(false, value.get(as_files, "hasBaseline").?.bool);
    try testing.expectEqual(@as(i64, 3), value.get(as_files, "fileCount").?.integer);
    try testing.expectEqual(@as(usize, 1), value.get(as_files, "changed").?.array.items.len);

    const as_summary = try structuredReport(allocator, result, .summary);
    const first = value.get(as_summary, "targets").?.array.items[0];
    try testing.expectEqualStrings("unit", value.get(first, "name").?.string);
    try testing.expectEqualStrings("src", value.get(first, "watchedPaths").?.array.items[0].string);
    try testing.expectEqual(true, value.get(first, "appliesHere").?.bool);
    try testing.expectEqual(@as(usize, 0), value.get(as_summary, "unwatched").?.array.items.len);
}

test "reportTargetNames prints one name per line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var captured = std.Io.Writer.Allocating.init(arena.allocator());
    var out = Output{ .writer = &captured.writer };

    reportTargetNames(&out, &.{ "unit", "documentation" });
    try testing.expectEqualStrings("unit\ndocumentation\n", captured.written());

    captured.clearRetainingCapacity();
    reportTargetNames(&out, &.{});
    try testing.expectEqualStrings("", captured.written());
}

test "filterIgnoredBaseline drops the ignored extensions from every record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var targets: baseline_store.TargetBaselines = .empty;
    try targets.put(allocator, "unit", try file_hashes_module.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "src/notes.md", "2" },
    }));

    const baseline = Baseline{
        .targets = targets,
        .files = try file_hashes_module.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "README.md", "3" } }),
    };

    var filtered = try filterIgnoredBaseline(allocator, &baseline, &.{".md"});
    try testing.expectEqual(@as(usize, 1), filtered.targets.get("unit").?.count());
    try testing.expect(filtered.targets.get("unit").?.get("src/notes.md") == null);
    try testing.expectEqual(@as(usize, 1), filtered.files.count());
}

test "filterIgnoredBaseline with nothing ignored changes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const baseline = Baseline{
        .targets = .empty,
        .files = try file_hashes_module.fromPairs(allocator, &.{.{ "README.md", "1" }}),
    };

    var unchanged = try filterIgnoredBaseline(allocator, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), unchanged.files.count());
}

test "filterIgnoredFileHashes keeps only what is not ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorded = try file_hashes_module.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "README.md", "2" },
        .{ "notes.txt", "3" },
    });

    var filtered = try filterIgnoredFileHashes(allocator, &recorded, &.{ ".md", ".txt" });
    try testing.expectEqual(@as(usize, 1), filtered.count());
    try testing.expectEqualStrings("1", filtered.get("src/a.ts").?);
}

test "adding an ignored extension does not read as a pile of deletions" {
    var harness = try Harness.create();
    defer harness.destroy();

    //
    // Captured with markdown watched, then read back with markdown ignored. Without filtering the
    // baseline the same way as the file list, every recorded .md file would be reported as deleted.
    //
    try harness.project(
        \\targets:
        \\  - name: unit
        \\    paths:
        \\      - src
    , &.{ .{ "src/a.ts", "source" }, .{ "src/notes.md", "notes" } });
    const context = harness.context("linux");

    _ = try runBaseline(&context, .{}, &.{});

    try harness.temporary.write("what-changed.yaml",
        \\ignore:
        \\  - .md
        \\
        \\targets:
        \\  - name: unit
        \\    paths:
        \\      - src
    );

    harness.clear();
    _ = try compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "No files have changed") != null);
}

test "reportChangedFiles says how many were checked when nothing changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var captured = std.Io.Writer.Allocating.init(allocator);
    var out = Output{ .writer = &captured.writer };

    try reportChangedFiles(allocator, &out, &.{}, 42);
    try testing.expectEqualStrings("No files have changed since the baseline. 42 file(s) checked.\n", captured.written());
}

test "reportChangedFiles lists each change and counts them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var captured = std.Io.Writer.Allocating.init(allocator);
    var out = Output{ .writer = &captured.writer };

    try reportChangedFiles(allocator, &out, &.{
        .{ .path = "src/a.ts", .kind = .modified, .hash = "0123456789abcdef00", .previous_hash = "old" },
    }, 4);

    try testing.expectEqualStrings(
        \\Changed since the baseline:
        \\  M  0123456789abcdef  src/a.ts
        \\
        \\1 changed, 4 file(s) checked.
        \\
    , captured.written());
}

test "reportCategorizedChanges renders the whole summary view" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var captured = std.Io.Writer.Allocating.init(allocator);
    var out = Output{ .writer = &captured.writer };

    var unit_changes = [_]ChangedFile{.{ .path = "src/a.ts", .kind = .added, .hash = "aaaabbbbccccdddd11", .previous_hash = "" }};
    var stray = [_]ChangedFile{.{ .path = "stray/x.ts", .kind = .added, .hash = "1111222233334444ff", .previous_hash = "" }};

    var targets = [_]categorize.TargetChanges{
        .{ .name = "unit", .watched_paths = &.{}, .applies_here = true, .ever_captured = true, .changed_files = &unit_changes },
        .{ .name = "documentation", .watched_paths = &.{}, .applies_here = true, .ever_captured = true, .changed_files = &.{} },
        .{ .name = "elsewhere-only", .watched_paths = &.{}, .applies_here = false, .ever_captured = true, .changed_files = &.{} },
    };

    try reportCategorizedChanges(allocator, &out, .{ .targets = &targets, .unwatched_files = &stray }, &unit_changes, 9);

    try testing.expectEqualStrings(
        \\Changed since the baseline:
        \\
        \\  unit: 1 changed
        \\    A  aaaabbbbccccdddd  src/a.ts
        \\  documentation: unchanged
        \\  elsewhere-only: wrong-platform
        \\
        \\  Watched by no target: 1 changed
        \\    A  1111222233334444  stray/x.ts
        \\
        \\1 changed, 9 file(s) checked.
        \\
    , captured.written());
}

test "renderReport in text mode explains a missing baseline before listing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var captured = std.Io.Writer.Allocating.init(allocator);
    var out = Output{ .writer = &captured.writer };

    var changes = [_]ChangedFile{.{ .path = "src/a.ts", .kind = .added, .hash = "abcdef0123456789ff", .previous_hash = "" }};

    try renderReport(allocator, &out, .{
        .has_baseline = false,
        .file_count = 1,
        .changes = &changes,
        .categorized = .{ .targets = &.{}, .unwatched_files = &.{} },
        .target_names = &.{},
    }, .files, .text);

    try testing.expectEqualStrings(
        \\No baseline recorded yet, so every file counts as new. 1 file(s) in the working tree.
        \\
        \\Changed since the baseline:
        \\  A  abcdef0123456789  src/a.ts
        \\
        \\1 changed, 1 file(s) checked.
        \\
    , captured.written());
}

test "renderReport in targets mode never explains a missing baseline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var captured = std.Io.Writer.Allocating.init(allocator);
    var out = Output{ .writer = &captured.writer };

    var names = [_][]const u8{"unit"};
    try renderReport(allocator, &out, .{
        .has_baseline = false,
        .file_count = 1,
        .changes = &.{},
        .categorized = .{ .targets = &.{}, .unwatched_files = &.{} },
        .target_names = &names,
    }, .targets, .text);

    //
    // A script reads this list. Prose in it would have to be filtered out by every caller.
    //
    try testing.expectEqualStrings("unit\n", captured.written());
}
