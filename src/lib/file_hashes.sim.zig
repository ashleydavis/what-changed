// What a run cannot put together for itself in `file_hashes.zig`.
//
// `FileHashes` is a hash map. Built field by field from its type, its entry pointer and its length
// come from separate draws, so the first read faults and every function taking one is stepped over.

const std = @import("std");
const file_hashes = @import("file_hashes.zig");

const FileHashes = file_hashes.FileHashes;

// What a made map is built from: how many paths it holds, and the hash they carry.
pub const MadeHashes = struct {
    // How many entries, so a loop over the map reaches its zero, one and many sides.
    entries: u2,

    // Which path the entries start at. Two maps built from their own states hold different files
    // rather than the same ones, which is what makes one a file the other has lost.
    first: u2,

    // The hash every entry carries. One value rather than one per entry, because what a comparison
    // does with two different hashes is decided by whether they match, not by what they say.
    hash: []const u8,
};

// The paths a made map is keyed by. Written here rather than drawn, because two entries under one
// key are one entry, and a map that can only ever hold one cannot reach a loop's many side.
const paths = [_][]const u8{ "src/a.ts", "src/b.ts", "docs/c.md", "package.json" };

pub fn hashesFrom(state: *MadeHashes, allocator: std.mem.Allocator) FileHashes {
    var hashes: FileHashes = .empty;
    var at: usize = 0;
    while (at < state.entries and at < paths.len) : (at += 1) {
        hashes.put(allocator, paths[(at + state.first) % paths.len], state.hash) catch return hashes;
    }
    return hashes;
}

const sim = @import("sim");
const value = @import("value.zig");
const Subject = sim.Subject(@import("log").Log);

// Reads a map back out of every object it can be handed: one that is not an object at all, one with
// nothing in it, one whole entry, and one holding entries that are not strings.
pub fn runFileHashesScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try file_hashes.fromValue(allocator, .null, self.log);
    _ = try file_hashes.fromValue(allocator, .{ .integer = 1 }, self.log);

    const empty: value.Object = .empty;
    _ = try file_hashes.fromValue(allocator, .{ .object = empty }, self.log);

    var one: value.Object = .empty;
    try one.put(allocator, "src/a.ts", .{ .string = "abc" });
    _ = try file_hashes.fromValue(allocator, .{ .object = one }, self.log);

    var mixed: value.Object = .empty;
    try mixed.put(allocator, "src/a.ts", .{ .string = "abc" });
    try mixed.put(allocator, "src/b.ts", .{ .integer = 1 });
    try mixed.put(allocator, "src/c.ts", .null);
    _ = try file_hashes.fromValue(allocator, .{ .object = mixed }, self.log);

    // And the other way round, over maps of every size.
    var hashes: FileHashes = .empty;
    _ = try file_hashes.toValue(allocator, &hashes, self.log);
    try hashes.put(allocator, "src/a.ts", "abc");
    _ = try file_hashes.toValue(allocator, &hashes, self.log);
    try hashes.put(allocator, "src/b.ts", "def");
    try hashes.put(allocator, "src/c.ts", "ghi");
    _ = try file_hashes.toValue(allocator, &hashes, self.log);
    _ = try file_hashes.sortedKeys(allocator, &hashes, self.log);
}
