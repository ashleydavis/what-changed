// The deterministic simulation for `json.zig`: one text per way a parse can be refused.

const std = @import("std");
const sim = @import("sim");
const json = @import("json.zig");
const failure = @import("failure.zig");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;
const Subject = sim.Subject(Log);

// One text per branch of the refusal. A text drawn from a corpus is almost never JSON at all, which
// reaches one of these and none of the others.
const texts = [_][]const u8{
    "{}",
    "{\"a\": 1}",
    "[1, 2, 3]",
    "\"just a string\"",
    "null",

    // Ends in the middle of a value.
    "{\"a\":",
    "[1,",

    // A token where none can go, which the parser refuses for a reason of its own.
    "{\"a\": }",
    "{\"a\" 1}",
    "[,]",
    "{]",

    // A number JSON cannot represent.
    "{\"a\": 1e999999999}",
    "{\"a\": -1e999999999}",
    "{\"a\": 1.0e+}",
    "{\"a\": 123456789012345678901234567890123456789012345678901234567890}",
    "{\"a\": -123456789012345678901234567890123456789012345678901234567890}",
    "{\"a\": 1e400}",
    "{\"a\": 99999999999999999999999999999}",

    // A character that cannot appear where it does.
    "{'a': 1}",
    "{\"a\": 01}",

    // Nested past what the parser will follow, which is refused for a reason of its own.
    "[" ** 600 ++ "]" ** 600,

    // Not well formed in some other way.
    "{\"a\": 1}}",
    "",
    "not json at all",
};

pub fn runJsonScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (texts) |text| {
        var detail: ?[]const u8 = null;
        _ = json.parseDetailed(allocator, text, &detail, self.log) catch {};
        _ = json.parse(allocator, text, self.log) catch {};

        var fail = failure.Failure.init(allocator, self.log);
        _ = json.parseOrFail(allocator, text, "what-changed config", &fail) catch {};
    }

    // An allocator that gives out part way through, which is the one refusal that is not about the
    // text at all, and the one that reaches the wording with no detail to give.
    var running_out = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var detail: ?[]const u8 = null;
    _ = json.parseDetailed(running_out.allocator(), "[1, 2, 3]", &detail, self.log) catch {};

    var also_running_out = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var fail = failure.Failure.init(allocator, self.log);
    _ = json.parseOrFail(also_running_out.allocator(), "[1, 2, 3]", "what-changed config", &fail) catch {};

    // A writer with no room, so rendering gives up.
    var no_room = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    _ = json.stringify(no_room.allocator(), .{ .integer = 1 }, self.log) catch {};
}
