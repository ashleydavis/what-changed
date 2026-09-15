const sim = @import("sim");
const wc = @import("what-changed");
const harness = @import("test/harness.zig");
const shared = @import("harness.sim.zig");
const annotate_mod = @import("log");

const Subject = sim.Subject(annotate_mod.Log);
const project_config = shared.project_config;
const formats = shared.formats;
const baseline_cmd = @import("baseline.zig");
const cache_cmd = @import("cache.zig");
const changes_cmd = @import("changes.zig");
const init_cmd = @import("init.zig");
const summary_cmd = @import("summary.zig");
const targets_cmd = @import("targets.zig");
const version_cmd = @import("version.zig");

// Every reporting command, in every view and every format, before and after a capture.
pub fn runCommandsScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
    defer scenario.destroy();

    try scenario.project(project_config, &.{
        .{ "src/a.ts", "the first contents" },
        .{ "src/b.ts", "another file" },
        .{ "package.json", "{}" },
    });
    const context = scenario.context();

    for (formats) |format| {
        _ = summary_cmd.summaryCommand(&context, .{ .output = format }) catch {};
        _ = changes_cmd.changesCommand(&context, .{ .output = format }) catch {};
        _ = targets_cmd.targetsCommand(&context, .{ .output = format }) catch {};
        _ = targets_cmd.targetsListCommand(&context, .{ .output = format }) catch {};
        _ = version_cmd.versionCommand(&context, format, wc.version.build_metadata) catch {};
        _ = baseline_cmd.baselineShowCommand(&context, .{ .output = format }) catch {};
        _ = cache_cmd.cacheShowCommand(&context, .{ .output = format }) catch {};
        scenario.clear();
    }

    // Nothing captured yet, then one target, then everything.
    _ = baseline_cmd.baselineShowCommand(&context, .{}) catch {};
    _ = baseline_cmd.baselineSetCommand(&context, .{}, &.{"compile"}) catch {};
    _ = baseline_cmd.baselineShowCommand(&context, .{}) catch {};
    _ = baseline_cmd.baselineSetCommand(&context, .{}, &.{}) catch {};
    _ = baseline_cmd.baselineShowCommand(&context, .{}) catch {};

    _ = baseline_cmd.resolveBaselinePath(&context, .{}) catch {};

    // The cache on its own, then emptied, then the baseline forgotten.
    _ = cache_cmd.resolveCacheDir(&context, .{}) catch {};
    _ = cache_cmd.cacheCaptureCommand(&context, .{}) catch {};
    _ = cache_cmd.cacheShowCommand(&context, .{}) catch {};
    _ = cache_cmd.cacheResetCommand(&context, .{}) catch {};
    _ = baseline_cmd.baselineResetCommand(&context, .{}) catch {};
    _ = baseline_cmd.baselineShowCommand(&context, .{}) catch {};

    // A config that is not there, which every one of them refuses.
    _ = summary_cmd.summaryCommand(&context, .{ .config = "nowhere.yaml" }) catch {};
    _ = baseline_cmd.baselineShowCommand(&context, .{ .config = "nowhere.yaml" }) catch {};
    _ = baseline_cmd.baselineResetCommand(&context, .{ .config = "nowhere.yaml" }) catch {};
    _ = cache_cmd.cacheResetCommand(&context, .{ .config = "nowhere.yaml" }) catch {};
    _ = cache_cmd.cacheShowCommand(&context, .{ .config = "nowhere.yaml" }) catch {};

    // Its own command lines, which is the only way its actions are reached: an action is held as a
    // function pointer, so nothing built from a signature can call one.
    for ([_][]const []const u8{
        &.{ "baseline", "show" },
        &.{ "baseline", "show", "--output", "json" },
        &.{ "baseline", "capture" },
        &.{ "baseline", "capture", "compile" },
        &.{ "baseline", "update" },
        &.{ "baseline", "set" },
        &.{ "baseline", "reset" },
    }) |argv| {
        const held = try scenario.allocator().create(wc.run.Context);
        held.* = context;
        const program = wc.commander.program(scenario.allocator(), self.log);
        program.addCommand(baseline_cmd.baselineCommand(held));
        var runner = wc.commander.Program{ .out = &scenario.captured.writer, .log = self.log };
        wc.commander.parse(&runner, program, argv) catch {};
    }

    // One target captured, then two, each shown in the format that lists them.
    _ = baseline_cmd.baselineSetCommand(&context, .{}, &.{"compile"}) catch {};
    _ = baseline_cmd.baselineShowCommand(&context, .{ .output = "json" }) catch {};
    _ = baseline_cmd.baselineShowCommand(&context, .{}) catch {};
    _ = baseline_cmd.baselineSetCommand(&context, .{}, &.{}) catch {};
    _ = baseline_cmd.baselineShowCommand(&context, .{ .output = "json" }) catch {};
    _ = baseline_cmd.baselineShowCommand(&context, .{}) catch {};

    // The whole command tree built, which is what every command definition here is for.
    _ = baseline_cmd.baselineCommand(&context);
    _ = cache_cmd.cacheCommand(&context);
    _ = changes_cmd.buildChangesCommand(&context);
    _ = init_cmd.buildInitCommand(&context);
    _ = summary_cmd.buildSummaryCommand(&context);
    _ = targets_cmd.buildTargetsCommand(&context);
    _ = version_cmd.buildVersionCommand(&context);
}

// A baseline file that is there and cannot be used, in each of the three ways.
pub fn runUnusableBaselineScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    const damaged = [_][]const u8{ "{ not json", "[1, 2, 3]" };
    for (damaged) |contents| {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();

        try scenario.project(project_config, &.{.{ "src/a.ts", "the contents" }});
        try scenario.write(".what-changed/baseline.json", contents);

        const context = scenario.context();
        _ = baseline_cmd.baselineShowCommand(&context, .{}) catch {};
    }

    // One that is there and cannot be read, which is a directory standing where the file goes.
    {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();

        try scenario.project(project_config, &.{.{ "src/a.ts", "the contents" }});
        const baseline_path = try scenario.temporary.join(scenario.allocator(), ".what-changed/baseline.json");
        try wc.files.makeDirPath(scenario.io(), baseline_path);

        const context = scenario.context();
        _ = baseline_cmd.baselineShowCommand(&context, .{}) catch {};
    }

    // A baseline and a cache that cannot be written, because a file is standing where the
    // directory they go in would be.
    {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();

        try scenario.project(
            "cacheDir: in-the-way/cache\nbaselinePath: in-the-way/baseline.json\n" ++ project_config,
            &.{ .{ "src/a.ts", "the contents" }, .{ "in-the-way", "not a directory" } },
        );

        const context = scenario.context();
        _ = baseline_cmd.baselineResetCommand(&context, .{}) catch {};
        _ = cache_cmd.cacheResetCommand(&context, .{}) catch {};
    }
}

// A baseline holding more than one target, which is what makes the two lists this command prints
// run more than once.
//
// The shared project cannot do it: its second target is named for `win32` only, so on the platform
// a run reports as its own just one target ever applies and both lists print a single line.
const two_targets_here =
    \\targets:
    \\  - name: compile
    \\    paths:
    \\      - src
    \\  - name: test
    \\    paths:
    \\      - src
;

pub fn runBaselineWithSeveralTargetsScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
    defer scenario.destroy();

    try scenario.project(two_targets_here, &.{
        .{ "src/a.ts", "the first contents" },
        .{ "src/b.ts", "another file" },
    });
    const context = scenario.context();

    _ = baseline_cmd.baselineSetCommand(&context, .{}, &.{}) catch {};
    for (formats) |format| {
        _ = baseline_cmd.baselineShowCommand(&context, .{ .output = format }) catch {};
        scenario.clear();
    }
}
