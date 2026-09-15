// The deterministic simulation for `output.zig`: printing somewhere with no room in it.
//
// `line` takes its format string at compile time, so nothing that builds a call from a signature can
// make one. This is the only way the branch that records a write giving up is reached.

const std = @import("std");
const sim = @import("sim");
const output_module = @import("output.zig");
const annotate_mod = @import("log");

const Subject = sim.Subject(annotate_mod.Log);

pub fn runOutputScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var nothing: [0]u8 = undefined;
    var no_room = std.Io.Writer.fixed(&nothing);
    var out = output_module.Output{ .writer = &no_room, .log = self.log };
    out.line("a line that will not fit", .{});
    out.blank();
}
