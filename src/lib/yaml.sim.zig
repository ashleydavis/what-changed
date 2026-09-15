// The deterministic simulation for `yaml.zig`: the documents a run cannot invent.
//
// Every function here is reached by parsing text, and text drawn from a corpus of strings is almost
// never a document. What the parser does with a real one is the unit tests' subject; what is here is
// one example of each thing the parser has a branch for, so every branch is taken at least once.

const std = @import("std");
const sim = @import("sim");
const yaml = @import("yaml.zig");
const value = @import("value.zig");
const failure = @import("failure.zig");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;
const Subject = sim.Subject(Log);

// One document per thing the parser decides. Whether each parses is beside the point: a refusal is a
// branch like any other, and the ones that refuse are here for the branches that refuse them.
const documents = [_][]const u8{
    // Nothing at all, and nothing but a comment.
    "",
    "# only a comment\n",

    // The document markers, alone and repeated.
    "---\na: 1\n",
    "a: 1\n...\n",
    "---\na: 1\n---\nb: 2\n",

    // A tab where the indentation goes.
    "a:\n\tb: 1\n",

    // Block mappings and block sequences, nested both ways round.
    "a: 1\nb: two\n",
    "a:\n  b: 1\n",
    "targets:\n  - name: alpha\n    paths:\n      - src\n  - name: beta\n    paths:\n      - lib\n",
    "always:\n- package.json\n- tsconfig.json\n",
    "a:\n  -\n    b: 1\n",
    "a:\n  - - 1\n",

    // A key with nothing after it, and one whose value is a scalar on the same line.
    "a:\n",
    "a: value\n",

    // A line indented past the block it follows, and one that belongs to nothing at all.
    "a: 1\n   b: 2\n",
    "a:\n  b: 1\n c: 2\n",

    // A line that is not a pair at all.
    "a: 1\nnot a pair\n",

    // A key that reads as something other than a string.
    "1: one\n",

    // Every plain scalar the parser gives a meaning to, and one it does not.
    "a: null\nb: ~\nc: true\nd: false\ne: 42\nf: 1.5\ng: 1e3\nh: 1e\ni: -2.5e-3\nj: inf\nk: text\nl:\n",

    // Flow sequences: empty, one, several, unclosed, and with something between the items.
    "a: []\n",
    "a: [one]\n",
    "a: [one, two, three]\n",
    "a: [one\n",
    "a: [one two]\n",

    // Flow mappings: the same set.
    "a: {}\n",
    "a: {name: alpha}\n",
    "a: {name: alpha, paths: src}\n",
    "a: {name: alpha\n",
    "a: {name: alpha paths}\n",
    "a: {name alpha}\n",
    "a: {[one]: alpha}\n",
    "a: { }\n",

    // Quoted scalars, and each escape the parser understands.
    "a: \"plain\"\n",
    "a: 'plain'\n",
    "a: 'it''s'\n",
    "a: \"new\\nline\\ttab\\rreturn\\0nul\\\\slash\\\"quote\\/solidus\"\n",
    "a: \"unsupported \\q\"\n",
    "a: \"ends in a backslash \\",
    "a: \"never closed\n",

    // Text after a value that is already finished.
    "a: [one] and more\n",
    "a: \"one\" and more\n",

    // A feature this tool refuses outright.
    "a: &anchor\n",

    // A sequence at the top whose next line belongs to nothing above it.
    "- one\nb: two\n",

    // A key whose block is not indented under it, so nothing is owned.
    "a:\nb: 1\n",

    // Flow values that stop where nothing can follow them, and an empty one.
    "a: [,]\n",
    "a: [one: two]\n",
    "a: {one: two: three}\n",
    "a: [\"one\", 'two']\n",
    "a: [a, b]\n",
    "a: [   one   ]\n",
    "a: [one,\n",
    "a: {one: two,\n",

    // A quoted value that ends the moment it opens, and one that is empty.
    "a: \"\n",
    "a: \"\"\n",

    // A comment after a value, and a hash inside one.
    "a: value # a comment\n",
    "a: \"a#b\"\n",
    "a: 'quoted # hash'\n",
};

// Parses every document above. Each is handed a parser of its own, so a document that refuses says
// nothing about the one after it.
pub fn runYamlDocumentsScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    // Everything a parse allocates is freed together at the end, which is what the tool itself does
    // with a run. The allocator the scenario is handed checks for leaks.
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (documents) |document| {
        var err: ?yaml.SyntaxError = null;
        _ = yaml.parse(allocator, document, &err, self.log) catch {};
    }
}

// The same documents through the wrapper that turns a refusal into a message, which is the only
// caller in the tool. Both sides of "did the refusal say where" are here: every syntax error carries
// a position, and the one that does not is the parser running out of memory part way through.
pub fn runYamlParseOrFailScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (documents) |document| {
        var fail = failure.Failure.init(allocator, self.log);
        _ = yaml.parseOrFail(allocator, document, "what-changed config", &fail) catch {};
    }

    // An allocator that gives out part way through a parse, so the reporting path that has no
    // position to name is reached.
    var running_out = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var fail = failure.Failure.init(running_out.allocator(), self.log);
    _ = yaml.parseOrFail(running_out.allocator(), documents[7], "what-changed config", &fail) catch {};

    var err: ?yaml.SyntaxError = null;
    var also_running_out = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    _ = yaml.parse(also_running_out.allocator(), documents[7], &err, self.log) catch {};
}

// The line-level helpers, called directly with the text each of their branches turns on.
pub fn runYamlLineHelpersScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    const lines = [_][]const u8{
        "",
        "a: 1",
        "a:",
        ": 1",
        "\"a: b\": 1",
        "'a: b': 1",
        "https://example.com",
        "- item",
        "-",
        "-5",
        "a # comment",
        "# whole line",
        "a#b",
        "\"a # b\"",
        "'a # b'",
        "a  ",
    };
    for (lines) |line| {
        _ = yaml.splitMappingEntry(line, self.log);
        _ = yaml.isSequenceEntry(line, self.log);
        _ = yaml.stripComment(line, self.log);
        _ = yaml.needsQuoting(line, self.log);
        _ = yaml.looksLikeFloat(line, self.log);
        _ = yaml.isNull(line);
        _ = yaml.isTrue(line);
        _ = yaml.isFalse(line);
    }
}

// The scalars the two number checks have a branch for: a sign, a dot, an exponent with and without a
// sign of its own, an exponent with nothing after it, and one with something that is not a digit.
pub fn runYamlNumberScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    const numbers = [_][]const u8{
        "0",      "42",     "-42",    "+42",   "1.5",   "-1.5",  "1.2.3",
        "1e3",    "1e+3",   "1e-3",   "1.5e3", "e3",    "1e",    "1e+",
        "1ex",    "1e3x",   "inf",    "nan",   "text",  "",      " 1",
        "1 ",     "true",   "false",  "null",  "~",     "-",     "#",
        "[a]",    "{a}",    "a: b",   "a b",   "a\tb",  "a\nb",  "a\rb",
        "a # b",  "a#b",    ":",      "a:",    "0.0",   "1e999",
    };
    for (numbers) |text| {
        _ = yaml.looksLikeFloat(text, self.log);
        _ = yaml.needsQuoting(text, self.log);
    }
}

// Rendering: one value per thing the writer has a branch for.
pub fn runYamlRenderScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Every scalar arm, including the one that carries a number as text.
    const scalars = [_]value.Value{
        .null,
        .{ .bool = true },
        .{ .bool = false },
        .{ .integer = 42 },
        .{ .float = 1.5 },
        .{ .number_string = "1e999" },
        .{ .string = "plain" },
        .{ .string = "" },
        .{ .string = "needs \"quoting\" and \\ and \n and \t and \r" },
        .{ .string = "true" },
        .{ .string = " padded " },
        .{ .string = "-leading-indicator" },
        .{ .string = "a: b" },
        .{ .string = "a # b" },
        .{ .string = "\n" },
        .{ .string = "\"" },
    };
    for (scalars) |scalar| {
        _ = try yaml.stringify(allocator, scalar, self.log);
    }

    // An empty array and an empty object, both on their own line and both after a key.
    const empty_array = value.Array.init(allocator);
    const empty_object: value.Object = .empty;
    _ = try yaml.stringify(allocator, .{ .array = empty_array }, self.log);
    _ = try yaml.stringify(allocator, .{ .object = empty_object }, self.log);

    // An object whose values are an empty array, an empty object, a scalar, a filled array and a
    // filled object: every side of "is this value written below its key or beside it".
    var filled_array = value.Array.init(allocator);
    try filled_array.append(.{ .string = "one" });
    try filled_array.append(.{ .string = "two" });

    var inner: value.Object = .empty;
    try inner.put(allocator, "name", .{ .string = "alpha" });

    var root: value.Object = .empty;
    try root.put(allocator, "nothing", .{ .array = empty_array });
    try root.put(allocator, "empty", .{ .object = empty_object });
    try root.put(allocator, "scalar", .{ .integer = 1 });
    try root.put(allocator, "list", .{ .array = filled_array });
    try root.put(allocator, "inner", .{ .object = inner });
    _ = try yaml.stringify(allocator, .{ .object = root }, self.log);

    // A sequence whose items are themselves blocks, which is what puts an item's first key on the
    // dash's own line.
    var items = value.Array.init(allocator);
    try items.append(.{ .object = inner });
    try items.append(.{ .array = filled_array });
    try items.append(.{ .array = empty_array });
    try items.append(.{ .object = empty_object });
    _ = try yaml.stringify(allocator, .{ .array = items }, self.log);
}
