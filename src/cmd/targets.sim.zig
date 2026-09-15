const sim = @import("sim");
const wc = @import("what-changed");
const harness = @import("test/harness.zig");
const shared = @import("harness.sim.zig");
const commander = wc.commander;
const annotate_mod = @import("log");

const Subject = sim.Subject(annotate_mod.Log);

const targets_cmd = @import("targets.zig");


// Every command line this command answers to, run through the parser that reaches its actions.
//
// An action is reached through a function pointer the parser holds, so nothing that builds a value
// from a signature can call one: the command line is the only way in.
pub fn runTargetsCmdScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    const command_lines = [_][]const []const u8{
        &.{"targets"},
        &.{ "targets", "--output", "json" },
        &.{ "targets", "list" },
        &.{ "targets", "list", "--output", "yaml" },
    };

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
        program.addCommand(targets_cmd.buildTargetsCommand(held));

        var runner = commander.Program{ .out = &scenario.captured.writer, .log = self.log };
        commander.parse(&runner, program, argv) catch {};
    }
}
