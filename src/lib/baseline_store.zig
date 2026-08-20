const std = @import("std");
const value = @import("value.zig");
const files = @import("files.zig");
const failure = @import("failure.zig");
const cache_store = @import("cache_store.zig");
const file_hashes_module = @import("file_hashes.zig");

const Value = value.Value;
const Failure = failure.Failure;

//
// A map of repository-relative path to content hash. Re-exported here because everything that
// stores hashes reaches for it through this module.
//
pub const FileHashes = file_hashes_module.FileHashes;

//
// Each target's recorded file hashes, keyed by target name.
//
pub const TargetBaselines = std.StringArrayHashMapUnmanaged(FileHashes);

//
// What each target saw the last time it was captured.
//
// Per target rather than one snapshot of the whole tree, because targets pass at different moments.
// A single tree-wide baseline can only be recorded when everything has passed together: recording it
// after one suite would mark every other suite as up to date without them having run. That failure
// is silent and it lets a broken commit through, which makes it the worst one this tool can have.
//
pub const Baseline = struct {
    //
    // For each target, the hashes of the files it watched when it was last captured. A target absent
    // from here has never been captured, so everything under it counts as changed.
    //
    targets: TargetBaselines,

    //
    // Every file's hash at the most recent capture of any kind. Used only to decide whether a file
    // that no target watches has changed, since such a file has no target record to compare against.
    //
    files: FileHashes,
};

//
// The baseline is stored on its own, in its own file, deliberately apart from the file hash cache.
//
// They are not the same kind of thing. The file hash cache exists so the tool does not redo work,
// and throwing it away costs one slow run. The baseline is the answer to "changed since when", and
// throwing it away changes what the tool reports. Keeping them in one directory invited exactly the
// mistake of clearing one and losing the other.
//

//
// A baseline, and how the file it came from read.
//
pub const LoadedBaseline = struct {
    //
    // What was recorded. Empty whenever there was nothing usable to read.
    //
    baseline: Baseline,

    //
    // Whether the file was read, was not there, or was there and unusable.
    //
    // Carried so a caller can tell "never captured" from "captured and now unreadable". Both leave
    // the baseline empty and both mean everything counts as changed, but only one of them is
    // something to go and fix, and `baseline show` should not describe it as the other.
    //
    source: cache_store.JsonObjectFile,
};

//
// Loads the baseline. A missing file, or JSON that will not parse or is not a plain object, reads as
// no baseline at all rather than as an error, so a damaged file costs a full report and never a
// crash. Which of those it was comes back in `source`.
//
// A file written by an older version, which held a flat path-to-hash map rather than this structure,
// also reads as no baseline. Everything then counts as changed, which is the safe direction: the
// first run after an upgrade does the work rather than skipping it.
//
pub fn loadBaseline(io: std.Io, allocator: std.mem.Allocator, baseline_path: []const u8) std.mem.Allocator.Error!LoadedBaseline {
    const source = try cache_store.readJsonObject(io, allocator, baseline_path);
    return .{ .baseline = try toBaseline(allocator, source.contentOrNull()), .source = source };
}

//
// Reads a parsed JSON object as a baseline, treating either half that is not a plain object as
// absent.
//
pub fn toBaseline(allocator: std.mem.Allocator, parsed: Value) std.mem.Allocator.Error!Baseline {
    var targets: TargetBaselines = .empty;

    if (value.get(parsed, "targets")) |raw_targets| {
        if (value.isPlainObject(raw_targets)) {
            var walker = raw_targets.object.iterator();
            while (walker.next()) |entry| {
                try targets.put(allocator, entry.key_ptr.*, try file_hashes_module.fromValue(allocator, entry.value_ptr.*));
            }
        }
    }

    const recorded_files = if (value.get(parsed, "files")) |raw_files|
        try file_hashes_module.fromValue(allocator, raw_files)
    else
        FileHashes.empty;

    return .{ .targets = targets, .files = recorded_files };
}

//
// Renders a baseline as the JSON object it is stored as.
//
pub fn baselineToValue(allocator: std.mem.Allocator, baseline: *const Baseline) std.mem.Allocator.Error!Value {
    //
    // Target names are sorted so that two runs recording the same thing write byte-identical files,
    // whatever order the config happened to list the targets in.
    //
    const names = try allocator.dupe([]const u8, baseline.targets.keys());
    std.mem.sort([]const u8, names, {}, file_hashes_module.lessThanPath);

    var targets: value.Object = .empty;
    for (names) |name| {
        const recorded = baseline.targets.get(name).?;
        try targets.put(allocator, name, try file_hashes_module.toValue(allocator, &recorded));
    }

    var object: value.Object = .empty;
    try object.put(allocator, "targets", .{ .object = targets });
    try object.put(allocator, "files", try file_hashes_module.toValue(allocator, &baseline.files));
    return .{ .object = object };
}

//
// Returns a copy of the baseline with the named targets' records replaced, leaving every other
// target's record exactly as it was.
//
// This is what makes a per-target capture safe. Capturing one target must not touch another's
// record, because the other has not been re-run and nothing new is known about it.
//
pub fn withCapturedTargets(allocator: std.mem.Allocator, baseline: *const Baseline, captured: *const TargetBaselines, recorded_files: FileHashes) std.mem.Allocator.Error!Baseline {
    var targets: TargetBaselines = .empty;

    var existing = baseline.targets.iterator();
    while (existing.next()) |entry| {
        try targets.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    var replacing = captured.iterator();
    while (replacing.next()) |entry| {
        try targets.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    return .{ .targets = targets, .files = recorded_files };
}

//
// What a capture is about to write, so the change applied under the lock has everything it needs.
//
const Capture = struct {
    captured: *const TargetBaselines,
    files: FileHashes,
};

//
// Merges a capture into whatever the baseline file currently holds.
//
// This runs inside the lock, on contents read inside the lock, which is what makes a concurrent
// capture safe: the merge starts from what the other writer left, not from what this process read
// before waiting.
//
fn applyCapture(capture: Capture, allocator: std.mem.Allocator, current: Value) std.mem.Allocator.Error!Value {
    const existing = try toBaseline(allocator, current);
    const merged = try withCapturedTargets(allocator, &existing, capture.captured, capture.files);
    return baselineToValue(allocator, &merged);
}

//
// Records the named targets' hashes into the baseline, leaving every other target's record alone.
//
// This is the only way a capture reaches the file. Several processes capture at once, because a
// parallel suite captures each target as that target passes, and the read and the write have to be
// one indivisible step: two captures that both read the same baseline and then both write it back
// would each keep only their own target, and whichever wrote second would discard the other's.
//
pub fn captureTargets(io: std.Io, allocator: std.mem.Allocator, baseline_path: []const u8, captured: *const TargetBaselines, recorded_files: FileHashes, fail: *Failure) failure.Error!void {
    try cache_store.updateJsonFile(io, allocator, baseline_path, Capture{ .captured = captured, .files = recorded_files }, applyCapture, fail);
}

//
// Records a baseline, creating the directory above it if it is not there yet.
//
pub fn saveBaseline(io: std.Io, allocator: std.mem.Allocator, baseline_path: []const u8, baseline: *const Baseline) !void {
    try cache_store.writeJsonFile(io, allocator, baseline_path, try baselineToValue(allocator, baseline));
}

//
// Forgets the baseline, so the next report treats every file as new.
//
// An empty baseline is written rather than the file being deleted, for the same reason the cache
// reset writes rather than deletes: everything that reads it treats empty and absent alike, and a
// write cannot go wrong the way a delete of a computed path can.
//
pub fn baselineReset(io: std.Io, allocator: std.mem.Allocator, baseline_path: []const u8) !void {
    const empty = Baseline{ .targets = .empty, .files = .empty };
    try saveBaseline(io, allocator, baseline_path, &empty);
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("baseline_store.test.zig");
}
