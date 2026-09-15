// The deterministic simulation for `config.zig`: one config per thing it refuses.
//
// Every check in this file is reached by reading a config, and a config drawn from a corpus of
// strings is never one. What a good config parses to is the unit tests' subject; what is here is one
// example of each thing the parser has a branch for, so every refusal is reached at least once.

const std = @import("std");
const sim = @import("sim");
const config = @import("config.zig");
const failure = @import("failure.zig");
const files = @import("files.zig");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;
const Subject = sim.Subject(Log);

// The smallest config that is accepted, which every case below is a variation on.
const smallest =
    \\targets:
    \\  - name: compile
    \\    paths:
    \\      - src
;

// One config per branch. Whether each is accepted is beside the point: a refusal is a branch like
// any other, and most of these are here for the branch that refuses them.
const configs = [_][]const u8{
    smallest,

    // Not an object at all: a list, a number, and nothing.
    "- one\n- two\n",
    "42\n",
    "",

    // The two path fields: absent, set, empty, and set to something that is not a string.
    "cacheDir: .cache\nbaselinePath: .baseline.json\n" ++ "\n" ++ smallest,
    "cacheDir: \"\"\n" ++ smallest,
    "cacheDir: 42\n" ++ smallest,
    "baselinePath: []\n" ++ smallest,

    // `always`: absent, empty, one, several, not an array, and holding something that is not a
    // string, an empty string, an absolute path and a path that climbs out.
    "always: []\n" ++ smallest,
    "always:\n  - package.json\n" ++ smallest,
    "always:\n  - package.json\n  - tsconfig.json\n  - bun.lock\n" ++ smallest,
    "always: package.json\n" ++ smallest,
    "always:\n  - 42\n" ++ smallest,
    "always:\n  - \"\"\n" ++ smallest,
    "always:\n  - /etc/passwd\n" ++ smallest,
    "always:\n  - ../outside\n" ++ smallest,

    // `ignore`: the same set, plus the two spellings this field refuses on its own.
    "ignore: []\n" ++ smallest,
    "ignore:\n  - .md\n" ++ smallest,
    "ignore:\n  - .md\n  - .txt\n  - .log\n" ++ smallest,
    "ignore: .md\n" ++ smallest,
    "ignore:\n  - 42\n" ++ smallest,
    "ignore:\n  - \"\"\n" ++ smallest,
    "ignore:\n  - md\n" ++ smallest,
    "ignore:\n  - .\n" ++ smallest,
    "ignore:\n  - .md/x\n" ++ smallest,

    // `targets`: absent, not an array, empty, one, several.
    "always:\n  - package.json\n",
    "targets: compile\n",
    "targets: []\n",
    "targets:\n  - name: a\n    paths:\n      - src\n  - name: b\n    paths:\n      - lib\n  - name: c\n    paths:\n      - doc\n",

    // A target that is not an object, and every way its name can be wrong.
    "targets:\n  - compile\n",
    "targets:\n  - paths:\n      - src\n",
    "targets:\n  - name: 42\n    paths:\n      - src\n",
    "targets:\n  - name: \"\"\n    paths:\n      - src\n",
    "targets:\n  - name: a\n    paths:\n      - src\n  - name: a\n    paths:\n      - lib\n",

    // Every way a target's paths can be wrong, and a target watching several.
    "targets:\n  - name: a\n",
    "targets:\n  - name: a\n    paths: src\n",
    "targets:\n  - name: a\n    paths: []\n",
    "targets:\n  - name: a\n    paths:\n      - src\n      - lib\n      - doc\n",
    "targets:\n  - name: a\n    paths:\n      - 42\n",
    "targets:\n  - name: a\n    paths:\n      - \"\"\n",
    "targets:\n  - name: a\n    paths:\n      - /etc/passwd\n",
    "targets:\n  - name: a\n    paths:\n      - ../outside\n",

    // `platforms`: absent, an empty list, one, several, not a list, and holding something that is
    // not a string or is an empty one.
    "targets:\n  - name: a\n    paths:\n      - src\n    platforms: []\n",
    "targets:\n  - name: a\n    paths:\n      - src\n    platforms:\n      - linux\n",
    "targets:\n  - name: a\n    paths:\n      - src\n    platforms:\n      - linux\n      - darwin\n      - win32\n",
    "targets:\n  - name: a\n    paths:\n      - src\n    platforms: linux\n",
    "targets:\n  - name: a\n    paths:\n      - src\n    platforms:\n      - 42\n",
    "targets:\n  - name: a\n    paths:\n      - src\n    platforms:\n      - \"\"\n",
};

// Reads every config above in both formats. The same text is not valid in both, so the JSON side is
// a handful written as JSON rather than the same list again.
pub fn runConfigScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (configs) |text| {
        var fail = failure.Failure.init(allocator, self.log);
        _ = config.parseConfig(allocator, text, .yaml, &fail) catch {};
    }

    const as_json = [_][]const u8{
        "{\"targets\": [{\"name\": \"compile\", \"paths\": [\"src\"]}]}",
        "[1, 2]",
        "{\"targets\": [{\"name\": \"a\", \"paths\": [\"src\"], \"platforms\": [\"linux\"]}]}",
        "{ not json",
    };
    for (as_json) |text| {
        var fail = failure.Failure.init(allocator, self.log);
        _ = config.parseConfig(allocator, text, .json, &fail) catch {};
    }
}



// The names a made target goes by. The same list the recorded baselines use, so a run meets a
// baseline that holds a record for a target the config declares, which is what the comparison
// against a target's own record turns on.
pub const target_names = [_][]const u8{ "compile", "test", "lint", "package" };

// What a made target is built from.
pub const MadeTarget = struct {
    // Which of the names above it goes by.
    which: u2,

    // How many paths it watches, and how many platforms it names.
    paths: u2,
    platforms: u2,
};

const watched = [_][]const u8{ "src", "lib", "docs", "package.json" };
const platforms = [_][]const u8{ "linux", "darwin", "win32", "freebsd" };

pub fn targetFrom(state: *MadeTarget, allocator: std.mem.Allocator) config.TargetConfig {
    const its_paths = allocator.alloc([]const u8, @min(state.paths, watched.len)) catch return .{
        .name = target_names[state.which],
        .paths = &.{},
        .platforms = &.{},
    };
    for (its_paths, 0..) |*slot, at| {
        slot.* = watched[at];
    }

    const its_platforms = allocator.alloc([]const u8, @min(state.platforms, platforms.len)) catch return .{
        .name = target_names[state.which],
        .paths = its_paths,
        .platforms = &.{},
    };
    for (its_platforms, 0..) |*slot, at| {
        slot.* = platforms[at];
    }

    return .{ .name = target_names[state.which], .paths = its_paths, .platforms = its_platforms };
}

// Looking for a config by the names it may go by: one that is there, and one that is not.
//
// The run calls `findConfig` itself with strings it made up, which never name a file that exists, so
// the branch that finds one is only reached by putting a file where it looks.
pub fn runFindConfigScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(self.io, self.log);
    defer temporary.destroy();

    // Nothing there yet, so every name is tried and none is found.
    var missing = failure.Failure.init(allocator, self.log);
    _ = config.findConfig(self.io, allocator, temporary.path, &missing) catch {};

    // One under each name it accepts, so the search stops at the first and, with that one gone, at
    // each of the others in turn.
    for (config.DEFAULT_CONFIG_NAMES) |name| {
        try temporary.write(name, "targets:\n  - name: compile\n    paths:\n      - src\n");
        var found = failure.Failure.init(allocator, self.log);
        _ = config.findConfig(self.io, allocator, temporary.path, &found) catch {};
        try files.removeFile(self.io, try temporary.join(allocator, name));
    }
}
