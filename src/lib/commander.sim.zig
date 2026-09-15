// What a run cannot put together for itself in `commander.zig`.
//
// A `Command` holds lists and a `Command` tree; an `Invocation` holds an erased pointer to whatever
// its action was registered with. Neither survives being built field by field from its type.

const std = @import("std");
const commander = @import("commander.zig");
const annotate_mod = @import("log");

const Log = annotate_mod.Log;

// What a made command is built from: how much of a definition it carries.
pub const MadeCommand = struct {
    // The word that names it.
    command_name: []const u8,

    // What the help says about it.
    description_text: []const u8,

    // How many options it takes, how many other words mean it, and how many subcommands it has, so
    // every loop over one of those reaches its zero, one and many sides.
    options: u2,
    aliases: u2,
    subcommands: u2,

    // Whether it takes a positional argument, and whether that argument may be repeated.
    takes_argument: bool,
    variadic: bool,

    // Whether it carries a version, which is what decides whether `-V` is one of its flags.
    has_version: bool,

    // Whether it prints anything after its help.
    has_help_text_after: bool,
};

// The option spellings a made command takes. Written here rather than drawn: an option is looked up
// by the name inside its flags, and four draws of the same string are one option four times over.
const flags = [_][]const u8{ "-c, --config, --cfg <path>", "--output <format>", "--force", "--quiet <level>" };
const sub_names = [_][]const u8{ "capture", "reset", "show", "list" };
const alias_names = [_][]const u8{ "update", "set", "refresh", "print" };

pub fn commandFrom(state: *MadeCommand, allocator: std.mem.Allocator, log: Log) *commander.Command {
    const made = commander.Command.init(allocator, state.command_name, log);
    _ = made.description(state.description_text);

    var at: usize = 0;
    while (at < state.options and at < flags.len) : (at += 1) {
        // Every second option carries a default, so the two sides of "was this given or defaulted"
        // are both reachable.
        _ = made.option(flags[at], "What this one does.", if (at % 2 == 0) "text" else null);
    }

    at = 0;
    while (at < state.aliases and at < alias_names.len) : (at += 1) {
        _ = made.alias(alias_names[at]);
    }

    if (state.takes_argument) {
        _ = made.argument(if (state.variadic) "[names...]" else "[name]", "What it takes.");
    }

    if (state.has_version) {
        _ = made.version("1.2.3", "-v, --version", "Print the version.");
    }

    if (state.has_help_text_after) {
        _ = made.addHelpText("after", "\nExamples:\n  what-changed summary\n");
    }

    at = 0;
    while (at < state.subcommands and at < sub_names.len) : (at += 1) {
        const sub = made.command(sub_names[at]);
        _ = sub.description("What this one does.");
        _ = sub.option("--config <path>", "The config file to read.", null);
    }

    return made;
}

// What a made invocation is built from: the options it was given and the arguments beside them.
pub const MadeInvocation = struct {
    // How many options were given, so a lookup finds one and misses one.
    given: u2,

    // What the given options were set to.
    text: []const u8,

    // How many positional arguments came with it.
    args: u2,
};

const option_names = [_][]const u8{ "config", "output", "force", "quiet" };

pub fn invocationFrom(state: *MadeInvocation, allocator: std.mem.Allocator, log: Log) *commander.Invocation {
    var values: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var at: usize = 0;
    while (at < state.given and at < option_names.len) : (at += 1) {
        values.put(allocator, option_names[at], state.text) catch break;
    }

    var args: std.ArrayList([]const u8) = .empty;
    at = 0;
    while (at < state.args and at < sub_names.len) : (at += 1) {
        args.append(allocator, sub_names[at]) catch break;
    }

    const made = allocator.create(commander.Invocation) catch @panic("out of memory building a simulated invocation");
    made.* = .{
        // Nothing a run drives reads this: an action casts it back to the context it was registered
        // with, and no action is reached from here. It points at the invocation itself so it is a
        // real address rather than a drawn one.
        .context = made,
        .args = args.items,
        .values = values,
        .log = log,
    };
    return made;
}

const sim = @import("sim");
const Subject = sim.Subject(Log);


// One command tree, and every command line the parser has a branch for.
//
// A command line drawn from a corpus of strings names no command and no option, so almost every
// branch below it is out of reach. These are real ones.
fn buildTree(allocator: std.mem.Allocator, log: Log) *commander.Command {
    const program = commander.program(allocator, log)
        .name("what-changed")
        .description("Reports which files have changed since the recorded baseline.")
        .helpOption("--help", "Print this text.")
        .version("1.2.3", "-v, --version", "Print the version.")
        .addHelpText("after", "\nExamples:\n  what-changed summary\n")
        .enablePositionalOptions();

    _ = program.command("summary")
        .description("Show the changed files grouped under the targets they fall under, which is a description long enough to be wrapped onto a second line by the help.")
        .option("--config <path>", "The config file to read.", null)
        .option("--output <format>", "How to render the result.", "text")
        .action(program, doNothing);

    const baseline = program.command("baseline");
    _ = baseline.description("Manage the recorded baseline.");
    _ = baseline.command("capture")
        .alias("update")
        .alias("set")
        .description("Record what the named targets watch.")
        .argument("[target names...]", "The targets to capture.")
        .action(program, doNothing);
    _ = baseline.command("show")
        .alias("print")
        .description("Show what is recorded.  A description with two spaces in it, so the wrapping meets a word with nothing in it.")
        .option("--a-very-long-option-name-indeed <value>", "One whose term is wider than the column it is written in.", null)
        .option("-c, --config, --cfg <path>", "One written three ways, so a lookup walks more than two spellings.", null)
        .action(program, doNothing);

    _ = program.command("one")
        .description("")
        .argument("[name]", "Exactly one name.")
        .action(program, doNothing);

    _ = program.command("fails").description("An action that fails.").action(program, alwaysFails);
    _ = program.command("no-room").description("An action that runs out of memory.").action(program, runsOutOfMemory);

    return program;
}

// What most of the commands above do, which is nothing: the parse is the subject here, not the
// command.
fn doNothing(invocation: *commander.Invocation) anyerror!void {
    _ = invocation;
}

// An action that fails, so the branch that turns a failed action into a refusal is reached.
fn alwaysFails(invocation: *commander.Invocation) anyerror!void {
    _ = invocation;
    return error.Failed;
}

// An action that runs out of memory, which the parse hands straight back rather than turning into a
// refusal of its own.
fn runsOutOfMemory(invocation: *commander.Invocation) anyerror!void {
    _ = invocation;
    return error.OutOfMemory;
}

// Every command line the parser has a branch for.
const command_lines = [_][]const []const u8{
    // Help and the version, at the top and under a subcommand.
    &.{"--help"},
    &.{"-v"},
    &.{"--version"},
    &.{ "summary", "--help" },

    // A command with an action, with and without its options, and with a default filled in.
    &.{"summary"},
    &.{ "summary", "--output", "json" },
    &.{ "summary", "--config", "other.yaml", "--output", "yaml" },

    // A command whose options come after a subcommand name.
    &.{ "baseline", "capture" },
    &.{ "baseline", "update" },
    &.{ "baseline", "set", "compile" },
    &.{ "baseline", "capture", "compile", "test" },
    &.{ "baseline", "show" },

    // A command with subcommands and no action of its own.
    &.{"baseline"},

    // An argument that may be given once only, given twice.
    &.{ "one", "first" },
    &.{ "one", "first", "second" },

    // Everything the parser refuses.
    &.{"--nonsense"},
    &.{ "summary", "--config" },
    &.{"nonsense"},
    &.{ "summary", "extra" },
    &.{"fails"},
    &.{"no-room"},

    // The end-of-options marker, and a lone dash, which is a value rather than an option.
    &.{ "one", "--", "--looks-like-an-option" },
    &.{ "one", "-" },

    // Nothing at all.
    &.{},
};

// Runs every command line above against the tree.
pub fn runCommandLinesScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var paper: [8192]u8 = undefined;
    for (command_lines) |argv| {
        const program = buildTree(allocator, self.log);
        var writer = std.Io.Writer.fixed(&paper);
        var runner = commander.Program{ .out = &writer, .log = self.log };
        commander.parse(&runner, program, argv) catch {};
    }

    // A writer with no room at all, so the version printing gives up.
    {
        const program = buildTree(allocator, self.log);
        var no_room: [0]u8 = undefined;
        var writer = std.Io.Writer.fixed(&no_room);
        var runner = commander.Program{ .out = &writer, .log = self.log };
        commander.parse(&runner, program, &.{"--version"}) catch {};
    }

    // An allocator that gives out while the refusal is being worded, so the branch that cannot
    // even say why is reached.
    {
        var running_out = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        const program = buildTree(allocator, self.log);
        // Swapped in after the tree is built: building one out of memory panics by design, and what
        // is wanted here is the wording of a refusal running out, which does not.
        program.allocator = running_out.allocator();
        var writer = std.Io.Writer.fixed(&paper);
        var runner = commander.Program{ .out = &writer, .log = self.log };
        commander.parse(&runner, program, &.{"--nonsense"}) catch {};
    }
}


