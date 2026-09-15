// The deterministic simulation for `failure.zig`: the second message, and running out of room for
// the first.

const std = @import("std");
const sim = @import("sim");
const failure = @import("failure.zig");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;
const Subject = sim.Subject(Log);

pub fn runFailureScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The first message is kept and the second is dropped, which is what makes the deepest failure
    // the one that gets reported.
    var fail = failure.Failure.init(allocator, self.log);
    _ = fail.set("the first message about {s}", .{"something"}) catch {};
    _ = fail.set("the second message", .{}) catch {};
    _ = fail.text();

    // Nothing recorded at all, which is the stand-in nobody should ever see.
    var nothing = failure.Failure.init(allocator, self.log);
    _ = nothing.text();

    // No room to record the message, which is the one failure this cannot report by recording one.
    var running_out = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var no_room = failure.Failure.init(running_out.allocator(), self.log);
    _ = no_room.set("a message that cannot be kept", .{}) catch {};
}
