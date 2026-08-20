const std = @import("std");
const value = @import("value.zig");
const output = @import("output.zig");
const failure = @import("failure.zig");
const Failure = failure.Failure;
const testing = std.testing;

test "parseOutputFormat defaults to text when nothing is given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    try testing.expectEqual(output.OutputFormat.text, try output.parseOutputFormat(null, &fail));
}

test "parseOutputFormat accepts every format it lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    try testing.expectEqual(output.OutputFormat.text, try output.parseOutputFormat("text", &fail));
    try testing.expectEqual(output.OutputFormat.json, try output.parseOutputFormat("json", &fail));
    try testing.expectEqual(output.OutputFormat.yaml, try output.parseOutputFormat("yaml", &fail));
}

test "parseOutputFormat ignores case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    try testing.expectEqual(output.OutputFormat.json, try output.parseOutputFormat("JSON", &fail));
    try testing.expectEqual(output.OutputFormat.yaml, try output.parseOutputFormat("Yaml", &fail));
}

test "parseOutputFormat refuses an unknown format and names the accepted ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    try testing.expectError(error.Failed, output.parseOutputFormat("xml", &fail));
    try testing.expectEqualStrings("Unknown --output format \"xml\". Use one of: text, json, yaml.", fail.text());
}

test "parseOutputFormat refuses an empty format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fail = Failure.init(arena.allocator());
    try testing.expectError(error.Failed, output.parseOutputFormat("", &fail));
}

test "renderStructured renders json and yaml from the same object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var names = value.newArray(allocator);
    try names.append(value.str("unit"));

    var root: value.Object = .empty;
    try root.put(allocator, "targets", .{ .array = names });

    try testing.expectEqualStrings(
        \\{
        \\  "targets": [
        \\    "unit"
        \\  ]
        \\}
    , try output.renderStructured(allocator, .{ .object = root }, .json));

    try testing.expectEqualStrings(
        \\targets:
        \\  - unit
    , try output.renderStructured(allocator, .{ .object = root }, .yaml));
}

test "printStructured writes the rendering and one newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root: value.Object = .empty;
    try root.put(allocator, "targets", .{ .array = value.newArray(allocator) });

    var captured = std.Io.Writer.Allocating.init(allocator);
    var out = output.Output{ .writer = &captured.writer };
    try output.printStructured(allocator, &out, .{ .object = root }, .yaml);

    try testing.expectEqualStrings("targets: []\n", captured.written());
    try testing.expect(!out.failed);
}

test "Output writes lines and blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var captured = std.Io.Writer.Allocating.init(allocator);
    var out = output.Output{ .writer = &captured.writer };

    out.line("first {d}", .{1});
    out.blank();
    out.line("last", .{});

    try testing.expectEqualStrings("first 1\n\nlast\n", captured.written());
    try testing.expect(!out.failed);
}
