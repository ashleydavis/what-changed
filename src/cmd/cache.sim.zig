const sim = @import("sim");
const wc = @import("what-changed");
const harness = @import("test/harness.zig");
const shared = @import("harness.sim.zig");
const commander = wc.commander;
const annotate_mod = @import("log");

const Subject = sim.Subject(annotate_mod.Log);

const cache_cmd = @import("cache.zig");


// Every command line this command answers to, run through the parser that reaches its actions.
//
// An action is reached through a function pointer the parser holds, so nothing that builds a value
// from a signature can call one: the command line is the only way in.
pub fn runCacheCmdScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    const command_lines = [_][]const []const u8{
        &.{ "cache", "show" },
        &.{ "cache", "show", "--output", "json" },
        &.{ "cache", "capture" },
        &.{ "cache", "update" },
        &.{ "cache", "reset" },
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
        program.addCommand(cache_cmd.cacheCommand(held));

        var runner = commander.Program{ .out = &scenario.captured.writer, .log = self.log };
        commander.parse(&runner, program, argv) catch {};
    }

    // A cache that cannot be written, because a file is standing where its directory would go.
    const blocked = try harness.Scenario.createOn(self.allocator, self.log, self.io);
    defer blocked.destroy();
    try blocked.project(
        "cacheDir: in-the-way/cache\n" ++ shared.project_config,
        &.{ .{ "src/a.ts", "the contents" }, .{ "in-the-way", "not a directory" } },
    );
    const blocked_context = blocked.context();
    _ = cache_cmd.cacheResetCommand(&blocked_context, .{}) catch {};
}
