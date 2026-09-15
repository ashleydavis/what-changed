const sim = @import("sim");
const wc = @import("what-changed");
const harness = @import("test/harness.zig");
const shared = @import("harness.sim.zig");
const annotate_mod = @import("log");

const Subject = sim.Subject(annotate_mod.Log);
const project_config = shared.project_config;
const init_cmd = @import("init.zig");

// Setting a project up: in an empty directory, then again where it is already set up, and in one
// whose `.gitignore` is there in each of the states the append has a branch for.
pub fn runInitScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    // Nothing there at all: both halves are written.
    {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();
        const context = scenario.context();
        _ = init_cmd.initCommand(&context) catch {};

        // A second run, which finds both halves already there.
        _ = init_cmd.initCommand(&context) catch {};
    }

    // A `.gitignore` that is already there, in each state: ignoring the directory with a slash,
    // without one, ignoring something else and ending in a newline, and ignoring something else
    // without one.
    const existing = [_][]const u8{
        ".what-changed/\n",
        ".what-changed\n",
        "node_modules\n",
        "node_modules",
        "",
        "  .what-changed/  \n",
    };
    for (existing) |contents| {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();
        try scenario.write(".gitignore", contents);
        const context = scenario.context();
        _ = init_cmd.initCommand(&context) catch {};
    }

    // Each of the config names the tool looks for, so the search finds one under each spelling.
    for ([_][]const u8{ "what-changed.yaml", "what-changed.yml", "what-changed.json" }) |name| {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();
        try scenario.write(name, project_config);
        const context = scenario.context();
        _ = init_cmd.initCommand(&context) catch {};
    }

    // The check asked about no names at all, which is what a caller that looks for nothing sees.
    {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();
        _ = init_cmd.writeStarterConfig(scenario.io(), scenario.allocator(), scenario.temporary.path, &.{}, &scenario.fail) catch {};
    }

    // A project whose `.gitignore` is there and cannot be replaced, so the config is written and the
    // half that appends to the ignore file is refused. A read-only directory would stop the config
    // as well, which is a different branch and is already covered above.
    {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();
        try scenario.write(".gitignore", "node_modules\n");
        try sim.filesystem.failWritesOf(try scenario.temporary.join(scenario.allocator(), ".gitignore"));
        const context = scenario.context();
        _ = init_cmd.initCommand(&context) catch {};
    }

    // A project where the config cannot be written, because a directory is standing where it goes.
    {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();
        const in_the_way = try scenario.temporary.join(scenario.allocator(), "what-changed.yaml");
        try wc.files.makeDirPath(scenario.io(), in_the_way);
        const context = scenario.context();
        _ = init_cmd.initCommand(&context) catch {};
    }
}
