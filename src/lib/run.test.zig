const std = @import("std");
const files = @import("files.zig");
const value = @import("value.zig");
const failure = @import("failure.zig");
const cache_store = @import("cache_store.zig");
const baseline_store = @import("baseline_store.zig");
const categorize = @import("categorize.zig");
const run = @import("run.zig");
const changed_files = @import("changed_files.zig");
const output_module = @import("output.zig");
const file_hashes_test = @import("file_hashes.test.zig");
const Failure = failure.Failure;
const Baseline = baseline_store.Baseline;
const ChangedFile = changed_files.ChangedFile;
const Output = output_module.Output;
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
    fn context(self: *Harness, platform: []const u8) run.Context {
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
    try testing.expectEqual(@as(u8, 0), try run.compareFileTree(&context, .{ .options = .{}, .mode = .summary }));

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

    _ = try run.runBaseline(&context, .{}, &.{});
    harness.clear();

    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .summary });
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

    _ = try run.runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");
    harness.clear();

    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .summary });
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

    _ = try run.runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/notes.md", "edited notes");
    harness.clear();

    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .summary });
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

    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "Watched by no target") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "stray/thing.ts") != null);
}

test "report in files mode lists the changes flat, without grouping them" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try run.runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");
    harness.clear();

    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .files });
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

    _ = try run.runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");
    harness.clear();

    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings("unit\n", harness.printed());
}

test "report in targets mode prints nothing when nothing changed" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try run.runBaseline(&context, .{}, &.{});
    harness.clear();

    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings("", harness.printed());
}

test "reporting is not destructive: a second look reports the same change" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try run.runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");

    harness.clear();
    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    const first = try harness.allocator().dupe(u8, harness.printed());

    harness.clear();
    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings(first, harness.printed());
}

test "report renders json and yaml from the same comparison" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try run.runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");

    harness.clear();
    _ = try run.compareFileTree(&context, .{ .options = .{ .output = "json" }, .mode = .files });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"changed\"") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"kind\": \"modified\"") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "Changed since the baseline:") == null);

    harness.clear();
    _ = try run.compareFileTree(&context, .{ .options = .{ .output = "yaml" }, .mode = .files });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "changed:") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "kind: modified") != null);
}

test "report refuses an unknown output format" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    try testing.expectError(error.Failed, run.compareFileTree(&context, .{ .options = .{ .output = "xml" }, .mode = .files }));
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

    _ = try run.runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "edited");

    harness.clear();
    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "elsewhere-only: wrong-platform") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "elsewhere-only: unchanged") == null);
    //
    // The file the wrong-platform target watches is still watched, so it is not called out as
    // watched by nothing.
    //
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "Watched by no target") == null);

    harness.clear();
    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "here-only") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "elsewhere-only") == null);

    harness.clear();
    _ = try run.compareFileTree(&context, .{ .options = .{ .output = "json" }, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"appliesHere\": false") != null);
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "\"appliesHere\": true") != null);
}

test "report reads the config named on the command line" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    try harness.temporary.write("other.yaml", "targets:\n  - name: other\n    paths:\n      - src\n");

    const context = harness.context("linux");
    _ = try run.compareFileTree(&context, .{ .options = .{ .config = "other.yaml" }, .mode = .targets });
    try testing.expectEqualStrings("other\n", harness.printed());
}

test "report fails and names the config that is not there" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    try testing.expectError(error.Failed, run.compareFileTree(&context, .{ .options = .{ .config = "definitely-not-here.yaml" }, .mode = .summary }));
    try testing.expect(std.mem.indexOf(u8, harness.fail.text(), "definitely-not-here.yaml") != null);
}

test "report passes on the file lister's failure" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{});

    var context = harness.context("linux");
    context.list_files = failingLister;

    try testing.expectError(error.Failed, run.compareFileTree(&context, .{ .options = .{}, .mode = .summary }));
    try testing.expect(std.mem.indexOf(u8, harness.fail.text(), "git ls-files failed") != null);
}

test "report does not read a file twice when the cache is warm" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .targets });

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

    try testing.expectEqual(@as(u8, 0), try run.runBaseline(&context, .{}, &.{}));
    try testing.expectEqualStrings("Captured the baseline for 2 target(s): unit, documentation.\n", harness.printed());

    var baseline = (try baseline_store.loadBaseline(harness.io(), harness.allocator(), try harness.temporary.join(harness.allocator(), ".what-changed/baseline.json"))).baseline;
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

    _ = try run.runBaseline(&context, .{}, &.{});
    try harness.temporary.write("src/a.ts", "changed for both");
    try harness.temporary.write("documentation/guide.txt", "changed for both");

    harness.clear();
    _ = try run.runBaseline(&context, .{}, &.{"unit"});
    try testing.expectEqualStrings("Captured the baseline for 1 target(s): unit.\n", harness.printed());

    //
    // The rule the per-target baseline exists for. Capturing "unit" after the unit suite passed must
    // not mark "documentation" as up to date, because that suite never ran.
    //
    harness.clear();
    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings("documentation\n", harness.printed());
}

test "runBaseline refuses an unknown target name and names the known ones" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    try testing.expectError(error.Failed, run.runBaseline(&context, .{}, &.{"nosuchtarget"}));
    try testing.expect(std.mem.indexOf(u8, harness.fail.text(), "\"nosuchtarget\" is not a target in") != null);
    try testing.expect(std.mem.indexOf(u8, harness.fail.text(), "Known targets: unit, documentation") != null);
}

test "runBaseline records nothing at all when one of the names is unknown" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    try testing.expectError(error.Failed, run.runBaseline(&context, .{}, &.{ "unit", "nosuchtarget" }));

    //
    // Refused as a whole rather than partly applied. A capture that recorded "unit" and then failed
    // would leave the caller believing nothing had been recorded when something had.
    //
    var baseline = (try baseline_store.loadBaseline(harness.io(), harness.allocator(), try harness.temporary.join(harness.allocator(), ".what-changed/baseline.json"))).baseline;
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

    _ = try run.runBaseline(&context, .{}, &.{});

    var baseline = (try baseline_store.loadBaseline(harness.io(), harness.allocator(), try harness.temporary.join(harness.allocator(), ".what-changed/baseline.json"))).baseline;
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

    try testing.expectEqual(@as(u8, 0), try run.runCacheCapture(&context, .{}));
    try testing.expectEqualStrings("Cache captured. 2 file hash(es) stored. The baseline is untouched.\n", harness.printed());

    var cache = try cache_store.loadCache(harness.io(), harness.allocator(), try harness.temporary.join(harness.allocator(), ".what-changed/cache"));
    try testing.expectEqual(@as(usize, 2), cache.file_hashes.count());

    //
    // Nothing about what is reported has changed, which is the difference between the cache and the
    // baseline.
    //
    harness.clear();
    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .summary });
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

    _ = try run.runBaseline(&context, .{}, &.{});
    harness.clear();

    //
    // Nothing has changed, so "targets" names none, but "targets list" names them all the same.
    //
    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .targets });
    try testing.expectEqualStrings("", harness.printed());

    harness.clear();
    try testing.expectEqual(@as(u8, 0), try run.listTargets(&context, .{}));
    try testing.expectEqualStrings("unit\nhere-only\n", harness.printed());
}

test "listTargets renders json when asked" {
    var harness = try Harness.create();
    defer harness.destroy();

    try harness.project(TWO_TARGET_CONFIG, &.{.{ "src/a.ts", "source" }});
    const context = harness.context("linux");

    _ = try run.listTargets(&context, .{ .output = "json" });
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
    try testing.expectEqual(@as(u8, 0), try run.listTargets(&context, .{}));
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

    const all = try run.allChangedFiles(allocator, .{ .targets = &targets, .unwatched_files = &stray });
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("src/a.ts", all[0].path);
    try testing.expectEqualStrings("stray/x.ts", all[1].path);
}

test "allChangedFiles of nothing is nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try run.allChangedFiles(allocator, .{ .targets = &.{}, .unwatched_files = &.{} })).len);
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

    const result = run.ReportResult{
        .has_baseline = false,
        .file_count = 3,
        .changes = &changes,
        .categorized = .{ .targets = &targets, .unwatched_files = &.{} },
        .target_names = &names,
    };

    const as_targets = try run.structuredReport(allocator, result, .targets);
    try testing.expectEqual(@as(usize, 1), as_targets.object.count());
    try testing.expectEqualStrings("unit", value.get(as_targets, "targets").?.array.items[0].string);

    const as_files = try run.structuredReport(allocator, result, .files);
    try testing.expectEqual(false, value.get(as_files, "hasBaseline").?.bool);
    try testing.expectEqual(@as(i64, 3), value.get(as_files, "fileCount").?.integer);
    try testing.expectEqual(@as(usize, 1), value.get(as_files, "changed").?.array.items.len);

    const as_summary = try run.structuredReport(allocator, result, .summary);
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

    run.reportTargetNames(&out, &.{ "unit", "documentation" });
    try testing.expectEqualStrings("unit\ndocumentation\n", captured.written());

    captured.clearRetainingCapacity();
    run.reportTargetNames(&out, &.{});
    try testing.expectEqualStrings("", captured.written());
}

test "filterIgnoredBaseline drops the ignored extensions from every record" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var targets: baseline_store.TargetBaselines = .empty;
    try targets.put(allocator, "unit", try file_hashes_test.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "src/notes.md", "2" },
    }));

    const baseline = Baseline{
        .targets = targets,
        .files = try file_hashes_test.fromPairs(allocator, &.{ .{ "src/a.ts", "1" }, .{ "README.md", "3" } }),
    };

    var filtered = try run.filterIgnoredBaseline(allocator, &baseline, &.{".md"});
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
        .files = try file_hashes_test.fromPairs(allocator, &.{.{ "README.md", "1" }}),
    };

    var unchanged = try run.filterIgnoredBaseline(allocator, &baseline, &.{});
    try testing.expectEqual(@as(usize, 1), unchanged.files.count());
}

test "filterIgnoredFileHashes keeps only what is not ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorded = try file_hashes_test.fromPairs(allocator, &.{
        .{ "src/a.ts", "1" },
        .{ "README.md", "2" },
        .{ "notes.txt", "3" },
    });

    var filtered = try run.filterIgnoredFileHashes(allocator, &recorded, &.{ ".md", ".txt" });
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

    _ = try run.runBaseline(&context, .{}, &.{});

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
    _ = try run.compareFileTree(&context, .{ .options = .{}, .mode = .summary });
    try testing.expect(std.mem.indexOf(u8, harness.printed(), "No files have changed") != null);
}

test "reportChangedFiles says how many were checked when nothing changed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var captured = std.Io.Writer.Allocating.init(allocator);
    var out = Output{ .writer = &captured.writer };

    try run.reportChangedFiles(allocator, &out, &.{}, 42);
    try testing.expectEqualStrings("No files have changed since the baseline. 42 file(s) checked.\n", captured.written());
}

test "reportChangedFiles lists each change and counts them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var captured = std.Io.Writer.Allocating.init(allocator);
    var out = Output{ .writer = &captured.writer };

    try run.reportChangedFiles(allocator, &out, &.{
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

    try run.reportCategorizedChanges(allocator, &out, .{ .targets = &targets, .unwatched_files = &stray }, &unit_changes, 9);

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

    try run.renderReport(allocator, &out, .{
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
    try run.renderReport(allocator, &out, .{
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
