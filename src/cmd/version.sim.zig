const sim = @import("sim");
const wc = @import("what-changed");
const harness = @import("test/harness.zig");
const shared = @import("harness.sim.zig");
const commander = wc.commander;
const annotate_mod = @import("log");

const Subject = sim.Subject(annotate_mod.Log);

const version_cmd = @import("version.zig");


// Every command line this command answers to, run through the parser that reaches its actions.
//
// An action is reached through a function pointer the parser holds, so nothing that builds a value
// from a signature can call one: the command line is the only way in.
pub fn runVersionCmdScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    const command_lines = [_][]const []const u8{
        &.{"version"},
        &.{ "version", "--output", "json" },
        &.{ "version", "--output", "yaml" },
    };

    // Every build the metadata can describe, which is what decides what this prints. Only one of
    // them is the build this was compiled into, so the rest are out of reach without asking.
    const builds = [_]wc.version.BuildMetadata{
        .{ .commit_hash = "dev", .build_date = "development", .is_pre_release = false },
        .{ .commit_hash = "abcdef1234567890", .build_date = "development", .is_pre_release = false },
        .{ .commit_hash = "abcdef1234567890", .build_date = "2026-09-14", .is_pre_release = false },
        .{ .commit_hash = "abcdef1234567890", .build_date = "2026-09-14", .is_pre_release = true },
    };
    for (builds) |metadata| {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();
        try scenario.project(shared.project_config, &.{.{ "src/a.ts", "the contents" }});
        const context = scenario.context();
        for (shared.formats) |format| {
            _ = version_cmd.versionCommand(&context, format, metadata) catch {};
        }
    }

    for (command_lines) |argv| {
        const scenario = try harness.Scenario.createOn(self.allocator, self.log, self.io);
        defer scenario.destroy();
        try scenario.project(shared.project_config, &.{
            .{ "src/a.ts", "the contents" },
            .{ "package.json", "{}" },
        });

        const context = scenario.context();
        const held = try scenario.allocator().create(wc.run.Context);
        held.* = context;

        const program = commander.program(scenario.allocator(), self.log);
        program.addCommand(version_cmd.buildVersionCommand(held));

        var runner = commander.Program{ .out = &scenario.captured.writer, .log = self.log };
        commander.parse(&runner, program, argv) catch {};
    }
}
