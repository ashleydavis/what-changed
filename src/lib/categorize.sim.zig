// The deterministic simulation for `categorize.zig`: the two places a name has to line up.
//
// A target runs here when the platform it was asked about is one it names, and it is compared
// against its own record when the baseline holds one under its name. Both turn on two strings being
// equal, and a run that draws each of them on its own almost never draws the same one twice.

const std = @import("std");
const sim = @import("sim");
const categorize = @import("categorize.zig");
const config_module = @import("config.zig");
const baseline_store = @import("baseline_store.zig");
const file_hashes = @import("file_hashes.zig");
const annotate_mod = @import("log");

const Subject = sim.Subject(annotate_mod.Log);

pub fn runNamesLineUpScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var watched: [1][]const u8 = .{"src"};
    var here: [1][]const u8 = .{"linux"};
    var targets: [1]config_module.TargetConfig = .{
        .{ .name = "compile", .paths = &watched, .platforms = &here },
    };
    const config = config_module.Config{
        .cache_dir = ".cache",
        .baseline_path = ".baseline.json",
        .always = &.{},
        .ignore = &.{},
        .targets = &targets,
    };

    _ = categorize.targetAppliesToPlatform(&targets[0], "linux", self.log);

    var hashes: file_hashes.FileHashes = .empty;
    try hashes.put(allocator, "src/a.ts", "abc");

    var recorded: file_hashes.FileHashes = .empty;
    try recorded.put(allocator, "src/a.ts", "was-abc");

    var captured: baseline_store.TargetBaselines = .empty;
    try captured.put(allocator, "compile", recorded);

    const before = baseline_store.Baseline{ .targets = captured, .files = recorded };
    _ = try categorize.categorizeChanges(allocator, &config, &hashes, &.{}, &before, "linux", self.log);
}
