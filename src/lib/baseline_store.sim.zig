// What a run cannot put together for itself in `baseline_store.zig`.
//
// A baseline's target records are a hash map of hash maps, and neither survives being built field by
// field from its type.

const std = @import("std");
const baseline_store = @import("baseline_store.zig");
const file_hashes = @import("file_hashes.zig");

const TargetBaselines = baseline_store.TargetBaselines;

// What a made set of target records is built from: how many targets were captured, and what each of
// them recorded.
pub const MadeTargets = struct {
    // How many targets, so a loop over them reaches its zero, one and many sides.
    entries: u2,

    // How many files each target recorded.
    files: u2,

    // The digest every recorded file carries.
    hash: []const u8,
};

// The target names a made record is keyed by, and the paths under each. Written here rather than
// drawn, for the reason a map keyed by one drawn string can only ever hold one entry.
// The same names a made target goes by, so a baseline holds a record for a target a config
// declares rather than for one nothing has ever heard of.
const names = @import("config.sim.zig").target_names;
const paths = [_][]const u8{ "src/a.ts", "src/b.ts", "docs/c.md", "package.json" };

pub fn targetsFrom(state: *MadeTargets, allocator: std.mem.Allocator) TargetBaselines {
    var targets: TargetBaselines = .empty;
    var at: usize = 0;
    while (at < state.entries and at < names.len) : (at += 1) {
        var recorded: file_hashes.FileHashes = .empty;
        var file: usize = 0;
        while (file < state.files and file < paths.len) : (file += 1) {
            recorded.put(allocator, paths[file], state.hash) catch break;
        }
        targets.put(allocator, names[at], recorded) catch return targets;
    }
    return targets;
}



const sim = @import("sim");
const value = @import("value.zig");
const Subject = sim.Subject(@import("log").Log);
