const std = @import("std");

//
// The parts of `commander` this tool uses, in Zig.
//
// A command line is built by chaining calls onto a `Command`: a name, a description, some options,
// sometimes an argument, and an action. That is what the definitions in src/cmd are written
// against.
//
// It is an implementation of what is used, not of commander. Missing on purpose: short option flags, boolean
// flags, option value parsers, `.requiredOption`, `.hook`, `.opts()` inheritance, variadic options,
// and negatable `--no-` forms. None of them appear in this tool's command line, and each one would
// be behaviour with no test to hold it honest.
//
// What IS reproduced exactly is the wording of the errors and the layout of the help, because a
// shell script driving this cannot be allowed to tell the difference. `scripts/smoke-tests.sh`
// asserts on both.
//
// The one thing commander does that cannot be copied is the closure: its actions capture whatever
// the surrounding function had, and a Zig function pointer captures nothing. So an action takes a
// context pointer that was handed to `.action` alongside it, which is the same information arriving
// by a different route.
//

//
// How wide the left column of the help is before a description starts.
//
// The help is laid out in two columns with the right one wrapped. The number is what commander's
// own output measures, which is what the smoke tests assert against.
//
const HELP_TERM_WIDTH = 19;

//
// How wide the help is allowed to get before a description wraps.
//
const HELP_TOTAL_WIDTH = 80;

//
// What went wrong on the command line.
//
// These are commander's own failure modes, kept apart because the CLI turns them into different exit
// codes: asking for help is a success, and getting the command line wrong is not.
//
pub const Error = error{
    //
    // Help or the version was printed. Commander calls these `commander.helpDisplayed` and
    // `commander.version`, and the CLI exits 0 for both.
    //
    Displayed,

    //
    // The command line was wrong: an unknown option or command, a missing option value, or an
    // argument too many. Commander's `commander.unknownOption` and friends, all of which exit 1.
    //
    Refused,
} || std.mem.Allocator.Error;

//
// One `--name <value>` an action can read.
//
pub const Option = struct {
    //
    // Exactly as written in the definition, such as "--config <path>". Kept whole because the error
    // message for a missing value quotes it back.
    //
    flags: []const u8,

    //
    // What the help says about it.
    //
    description: []const u8,

    //
    // The value used when the option is not given, or null when there is none.
    //
    default_value: ?[]const u8,

    //
    // The name an action looks it up by: the flags with the leading dashes and the placeholder
    // taken off, so "--config <path>" is read as "config".
    //
    pub fn name(self: Option) []const u8 {
        var text = self.flags;
        if (std.mem.indexOfScalar(u8, text, ' ')) |space| {
            text = text[0..space];
        }
        return std.mem.trimStart(u8, text, "-");
    }
};

//
// The positional argument a command takes, if it takes one.
//
pub const Argument = struct {
    //
    // As written, such as "[target names...]".
    //
    spec: []const u8,

    //
    // What the help says about it.
    //
    description: []const u8,
};

//
// The values an action reads: the options it was given, and the positional arguments.
//
// This is what an action is handed: the positional arguments it was called with, and every option
// that was given or has a default.
//
pub const Invocation = struct {
    //
    // Whatever `.action` was given alongside the function, cast back by the action itself.
    //
    context: *const anyopaque,

    //
    // The positional arguments, in order.
    //
    args: []const []const u8,

    //
    // The options that were given, plus any that have a default.
    //
    values: std.StringArrayHashMapUnmanaged([]const u8),

    //
    // What the process should exit with. An action sets it, and `parse` hands it back to `main`.
    //
    exit_code: u8 = 0,

    //
    // The value of an option, or null when it was not given and has no default.
    //
    pub fn option(self: *const Invocation, name: []const u8) ?[]const u8 {
        return self.values.get(name);
    }
};

//
// What an action is: a function, and the context it was registered with.
//
pub const ActionFn = *const fn (invocation: *Invocation) anyerror!void;

//
// One command, and everything it was defined with.
//
// Every builder method returns the command, so a whole definition is one chain of calls.
//
pub const Command = struct {
    allocator: std.mem.Allocator,

    //
    // The word that names it on the command line.
    //
    command_name: []const u8,

    //
    // Other words that mean the same command. `baseline update` is `baseline capture`.
    //
    aliases: std.ArrayList([]const u8) = .empty,

    //
    // What the help says about it.
    //
    description_text: []const u8 = "",

    //
    // The options it takes.
    //
    options: std.ArrayList(Option) = .empty,

    //
    // Its positional argument, if it takes one.
    //
    argument_spec: ?Argument = null,

    //
    // Its subcommands.
    //
    subcommands: std.ArrayList(*Command) = .empty,

    //
    // What to run when it is chosen.
    //
    action_fn: ?ActionFn = null,

    //
    // The context handed to the action.
    //
    action_context: ?*const anyopaque = null,

    //
    // Extra text printed after the help, such as the examples under the program's own usage.
    //
    help_text_after: []const u8 = "",

    //
    // The version string, and how the option that prints it is spelled. Only the program has these.
    //
    version_text: ?[]const u8 = null,
    version_flags: []const u8 = "-V, --version",
    version_description: []const u8 = "output the version number",

    //
    // How the help option is spelled and described. Commander's default is "-h, --help"; the
    // program overrides it to "--help".
    //
    help_flags: []const u8 = "-h, --help",
    help_description: []const u8 = "display help for command",

    //
    // Whether an option after a subcommand's name belongs to that subcommand.
    //
    // Off by default, exactly as in commander. Without it `--config` after a subcommand resolves to
    // the parent's copy, where nothing reads it, and the flag is accepted, silently ignored, and
    // the default used.
    //
    positional_options: bool = false,

    //
    // Makes a command.
    //
    // Panics if there is no memory, rather than returning an error, which is what every builder
    // method below does too. The command tree is built once at startup out of string literals: if
    // that cannot be allocated then nothing else in the run was going to work either, and returning
    // an error here would only mean a `try` on every call and no chaining, which is the whole point
    // of writing it this way.
    //
    pub fn init(allocator: std.mem.Allocator, command_name: []const u8) *Command {
        const created = allocator.create(Command) catch @panic("out of memory building the command line");
        created.* = .{ .allocator = allocator, .command_name = command_name };
        return created;
    }

    //
    // Sets the word that names this command.
    //
    // Commander's `program` arrives already made and is named by chaining, which is why this exists
    // as well as the name `init` takes.
    //
    pub fn name(self: *Command, text: []const u8) *Command {
        self.command_name = text;
        return self;
    }

    //
    // Sets what the help says about this command.
    //
    pub fn description(self: *Command, text: []const u8) *Command {
        self.description_text = text;
        return self;
    }

    //
    // Adds an option. A null `default_value` means the option has no default, so reading it when it
    // was not given answers null.
    //
    pub fn option(self: *Command, flags: []const u8, text: []const u8, default_value: ?[]const u8) *Command {
        self.options.append(self.allocator, .{
            .flags = flags,
            .description = text,
            .default_value = default_value,
        }) catch @panic("out of memory building the command line");
        return self;
    }

    //
    // Declares the positional argument this command takes.
    //
    pub fn argument(self: *Command, spec: []const u8, text: []const u8) *Command {
        self.argument_spec = .{ .spec = spec, .description = text };
        return self;
    }

    //
    // Adds another word that means this command.
    //
    pub fn alias(self: *Command, text: []const u8) *Command {
        self.aliases.append(self.allocator, text) catch @panic("out of memory building the command line");
        return self;
    }

    //
    // Sets what runs when this command is chosen, and the context it runs with.
    //
    pub fn action(self: *Command, context: *const anyopaque, run: ActionFn) *Command {
        self.action_context = context;
        self.action_fn = run;
        return self;
    }

    //
    // Adds text printed around this command's help.
    //
    // Commander takes a position first; only "after" is used here, and anything else is refused at
    // compile time rather than quietly printed in the wrong place.
    //
    pub fn addHelpText(self: *Command, comptime position: []const u8, text: []const u8) *Command {
        if (comptime !std.mem.eql(u8, position, "after")) {
            @compileError("addHelpText supports \"after\" only");
        }
        self.help_text_after = text;
        return self;
    }

    //
    // Sets the version, and how the option that prints it is spelled.
    //
    pub fn version(self: *Command, text: []const u8, flags: []const u8, text_description: []const u8) *Command {
        self.version_text = text;
        self.version_flags = flags;
        self.version_description = text_description;
        return self;
    }

    //
    // Changes how the help option is spelled and described.
    //
    pub fn helpOption(self: *Command, flags: []const u8, text: []const u8) *Command {
        self.help_flags = flags;
        self.help_description = text;
        return self;
    }

    //
    // Makes an option after a subcommand's name belong to that subcommand.
    //
    pub fn enablePositionalOptions(self: *Command) *Command {
        self.positional_options = true;
        return self;
    }

    //
    // Adds a subcommand that was built elsewhere. `program.addCommand(buildSummaryCommand())`.
    //
    // Returns nothing, unlike every other builder method here. Commander returns the parent so the
    // call can be chained, but nothing ever chains off it: a program adds its subcommands as a list
    // of statements. Returning the parent would only mean a `_ =` on every one of those lines.
    //
    pub fn addCommand(self: *Command, sub: *Command) void {
        self.subcommands.append(self.allocator, sub) catch @panic("out of memory building the command line");
    }

    //
    // Makes a subcommand and adds it, returning the new one so it can be chained onto. This is
    // commander's `cmd.command("capture")`, and it returns the child rather than the parent, which
    // is the one place chaining changes what it is chaining on.
    //
    pub fn command(self: *Command, sub_name: []const u8) *Command {
        const sub = Command.init(self.allocator, sub_name);
        self.addCommand(sub);
        return sub;
    }

    //
    // True when a word names this command.
    //
    pub fn matches(self: *const Command, word: []const u8) bool {
        if (std.mem.eql(u8, self.command_name, word)) return true;
        for (self.aliases.items) |alias_name| {
            if (std.mem.eql(u8, alias_name, word)) return true;
        }
        return false;
    }

    //
    // The subcommand a word names, or null.
    //
    pub fn findSubcommand(self: *const Command, word: []const u8) ?*Command {
        for (self.subcommands.items) |sub| {
            if (sub.matches(word)) return sub;
        }
        return null;
    }

    //
    // The option a flag names, or null.
    //
    pub fn findOption(self: *const Command, flag: []const u8) ?Option {
        for (self.options.items) |candidate| {
            var flags = std.mem.splitSequence(u8, candidate.flags, ", ");
            while (flags.next()) |spelling| {
                var spelled = spelling;
                if (std.mem.indexOfScalar(u8, spelled, ' ')) |space| {
                    spelled = spelled[0..space];
                }
                if (std.mem.eql(u8, spelled, flag)) return candidate;
            }
        }
        return null;
    }

    //
    // True when a flag is one of the spellings of this command's help option.
    //
    pub fn isHelpFlag(self: *const Command, flag: []const u8) bool {
        return namedBy(self.help_flags, flag);
    }

    //
    // True when a flag is one of the spellings of this command's version option.
    //
    pub fn isVersionFlag(self: *const Command, flag: []const u8) bool {
        if (self.version_text == null) return false;
        return namedBy(self.version_flags, flag);
    }
};

//
// A fresh root command, the way commander exports a ready-made `program`.
//
// Commander's is a module-level singleton. This one is made per call, because it needs an allocator
// and because a singleton would make two programs in one test share state.
//
pub fn program(allocator: std.mem.Allocator) *Command {
    return Command.init(allocator, "");
}

//
// True when a flag appears in a comma-separated spelling list such as "-v, --version".
//
pub fn namedBy(flags: []const u8, flag: []const u8) bool {
    var spellings = std.mem.splitSequence(u8, flags, ", ");
    while (spellings.next()) |spelling| {
        var spelled = spelling;
        if (std.mem.indexOfScalar(u8, spelled, ' ')) |space| {
            spelled = spelled[0..space];
        }
        if (std.mem.eql(u8, spelled, flag)) return true;
    }
    return false;
}

//
// True when an argument is written as an option rather than a value.
//
// A single "-" is a value: it means standard input by convention, and a lone dash is a legal file
// name besides.
//
pub fn isOption(argument_text: []const u8) bool {
    return argument_text.len > 1 and argument_text[0] == '-';
}

//
// Whether a command's declared argument may be given more than once.
//
pub fn isVariadic(spec: []const u8) bool {
    return std.mem.indexOf(u8, spec, "...") != null;
}

//
// Where a parse writes its output and its failure message.
//
// Commander prints straight to the console. This takes a writer instead, so the whole of a parse can
// be exercised by a test that reads what it produced rather than capturing the process's handles.
//
pub const Program = struct {
    //
    // Where help and version output goes.
    //
    out: *std.Io.Writer,

    //
    // Where the message goes when the command line is refused. Filled in by the parse; the CLI
    // prints it.
    //
    message: ?[]const u8 = null,

    //
    // What the chosen action set as the exit code.
    //
    exit_code: u8 = 0,

    //
    // Records why the command line was refused, in commander's wording.
    //
    fn refuse(self: *Program, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error {
        self.message = std.fmt.allocPrint(allocator, fmt, args) catch return error.OutOfMemory;
        return error.Refused;
    }
};

//
// Runs a command line against a command tree, the way `program.parseAsync(process.argv)` does.
//
// `argv` is the arguments after the program's own name, which is what commander is handed once it
// has stripped the node executable and the script.
//
pub fn parse(runner: *Program, root: *Command, argv: []const []const u8) Error!void {
    const allocator = root.allocator;

    var current = root;
    var at: usize = 0;

    //
    // Walk into subcommands for as long as the words name them. Options are collected per command,
    // so which command an option belongs to is decided by where it appears.
    //
    var values: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var positionals: std.ArrayList([]const u8) = .empty;
    var options_ended = false;

    while (at < argv.len) : (at += 1) {
        const word = argv[at];

        if (!options_ended and std.mem.eql(u8, word, "--")) {
            options_ended = true;
            continue;
        }

        if (!options_ended and isOption(word)) {
            if (current.isHelpFlag(word)) {
                try writeHelp(runner.out, current, allocator);
                return error.Displayed;
            }
            if (current.isVersionFlag(word)) {
                runner.out.print("{s}\n", .{current.version_text.?}) catch {};
                return error.Displayed;
            }

            const found = current.findOption(word) orelse {
                return runner.refuse(allocator, "error: unknown option '{s}'", .{word});
            };

            //
            // Every option this tool has takes a value, so a flag at the end of the line is a
            // missing value rather than a flag on its own.
            //
            at += 1;
            if (at >= argv.len) {
                return runner.refuse(allocator, "error: option '{s}' argument missing", .{found.flags});
            }
            try values.put(allocator, found.name(), argv[at]);
            continue;
        }

        //
        // Not an option. It either names a subcommand or is a positional argument.
        //
        if (positionals.items.len == 0) {
            if (current.findSubcommand(word)) |sub| {
                //
                // Descending into a subcommand. Options gathered so far stay with the parent, which
                // is what commander does, and the child starts with its own empty set.
                //
                current = sub;
                values = .empty;
                positionals = .empty;
                continue;
            }
        }

        if (current.argument_spec == null) {
            //
            // A word where nothing is expected. When the command has subcommands, commander calls
            // it an unknown command; otherwise it is one argument too many.
            //
            if (current.subcommands.items.len > 0) {
                return runner.refuse(allocator, "error: unknown command '{s}'", .{word});
            }
            return runner.refuse(allocator, "error: too many arguments. Expected 0 arguments but got {d}.", .{argv.len - at});
        }

        if (positionals.items.len > 0 and !isVariadic(current.argument_spec.?.spec)) {
            return runner.refuse(allocator, "error: too many arguments. Expected 1 argument but got {d}.", .{positionals.items.len + 1});
        }

        try positionals.append(allocator, word);
    }

    //
    // Any option with a default that was not given takes that default, which is how `--output`
    // arrives as "text" without the command line saying so.
    //
    for (current.options.items) |candidate| {
        if (candidate.default_value) |default_value| {
            if (!values.contains(candidate.name())) {
                try values.put(allocator, candidate.name(), default_value);
            }
        }
    }

    //
    // A command with subcommands and no action of its own prints its help, which is what commander
    // does for a bare `what-changed baseline`.
    //
    const run = current.action_fn orelse {
        try writeHelp(runner.out, current, allocator);
        return error.Displayed;
    };

    var invocation = Invocation{
        .context = current.action_context.?,
        .args = positionals.items,
        .values = values,
    };

    run(&invocation) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            //
            // An action that failed has already put its message where the CLI will find it. What
            // reaches here is only the fact that it failed.
            //
            runner.exit_code = 1;
            return error.Refused;
        },
    };

    runner.exit_code = invocation.exit_code;
}

//
// Writes a command's help, in commander's layout.
//
pub fn writeHelp(out: *std.Io.Writer, command: *const Command, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    const rendered = try renderHelp(allocator, command);
    out.print("{s}", .{rendered}) catch {};
}

//
// Renders a command's help as text.
//
// Returned rather than printed so a test can read the whole thing, and so the CLI's `outputHelp`
// and a `--help` on the command line produce the identical bytes.
//
pub fn renderHelp(allocator: std.mem.Allocator, command: *const Command) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    //
    // The usage line names what the command actually accepts, so a command with no options does not
    // claim to take any.
    //
    try out.print(allocator, "Usage: {s}", .{command.command_name});
    if (command.options.items.len > 0 or command.version_text != null) {
        try out.appendSlice(allocator, " [options]");
    }
    if (command.argument_spec) |spec| {
        try out.print(allocator, " {s}", .{spec.spec});
    }
    if (command.subcommands.items.len > 0) {
        try out.appendSlice(allocator, " [command]");
    }
    try out.appendSlice(allocator, "\n");

    if (command.description_text.len > 0) {
        try out.appendSlice(allocator, "\n");
        try writeWrapped(&out, allocator, command.description_text, 0);
    }

    //
    // Options, the version first when there is one, and help last, which is commander's order.
    //
    try out.appendSlice(allocator, "\nOptions:\n");
    if (command.version_text != null) {
        try writeTwoColumn(&out, allocator, command.version_flags, command.version_description);
    }
    for (command.options.items) |candidate| {
        if (candidate.default_value) |default_value| {
            const text = try std.fmt.allocPrint(allocator, "{s} (default: \"{s}\")", .{ candidate.description, default_value });
            try writeTwoColumn(&out, allocator, candidate.flags, text);
        } else {
            try writeTwoColumn(&out, allocator, candidate.flags, candidate.description);
        }
    }
    try writeTwoColumn(&out, allocator, command.help_flags, command.help_description);

    if (command.subcommands.items.len > 0) {
        try out.appendSlice(allocator, "\nCommands:\n");
        for (command.subcommands.items) |sub| {
            try writeTwoColumn(&out, allocator, try subcommandTerm(allocator, sub), sub.description_text);
        }
        try writeTwoColumn(&out, allocator, "help [command]", "display help for command");
    }

    if (command.help_text_after.len > 0) {
        try out.appendSlice(allocator, command.help_text_after);
        try out.appendSlice(allocator, "\n");
    }

    return out.toOwnedSlice(allocator);
}

//
// How a subcommand is named in its parent's help: its name, its aliases, and what it accepts.
//
pub fn subcommandTerm(allocator: std.mem.Allocator, sub: *const Command) std.mem.Allocator.Error![]const u8 {
    var term: std.ArrayList(u8) = .empty;

    try term.appendSlice(allocator, sub.command_name);
    for (sub.aliases.items) |alias_name| {
        try term.print(allocator, "|{s}", .{alias_name});
    }
    if (sub.options.items.len > 0) {
        try term.appendSlice(allocator, " [options]");
    }
    if (sub.argument_spec) |spec| {
        try term.print(allocator, " {s}", .{spec.spec});
    }

    //
    // Deliberately not " [command]". A subcommand that has subcommands of its own is still listed
    // by name alone in its parent's help, which is what commander prints, and the two have to match.
    //
    return term.toOwnedSlice(allocator);
}

//
// Writes one help row: a term on the left, its description wrapped on the right.
//
fn writeTwoColumn(out: *std.ArrayList(u8), allocator: std.mem.Allocator, term: []const u8, text: []const u8) std.mem.Allocator.Error!void {
    try out.print(allocator, "  {s}", .{term});

    if (text.len == 0) {
        try out.appendSlice(allocator, "\n");
        return;
    }

    //
    // A term too wide for its column pushes the description onto the next line, which is what
    // commander does rather than letting the columns run into each other.
    //
    if (term.len > HELP_TERM_WIDTH - 2) {
        try out.appendSlice(allocator, "\n");
        try out.appendNTimes(allocator, ' ', HELP_TERM_WIDTH + 2);
    } else {
        try out.appendNTimes(allocator, ' ', HELP_TERM_WIDTH - term.len);
    }

    try writeWrapped(out, allocator, text, HELP_TERM_WIDTH + 2);
}

//
// Writes text, wrapping it at the help's width and indenting every line after the first.
//
fn writeWrapped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, indent: usize) std.mem.Allocator.Error!void {
    const width = HELP_TOTAL_WIDTH - indent;

    var column: usize = 0;
    var words = std.mem.splitScalar(u8, text, ' ');
    while (words.next()) |word| {
        if (word.len == 0) continue;

        if (column > 0 and column + 1 + word.len > width) {
            try out.appendSlice(allocator, "\n");
            try out.appendNTimes(allocator, ' ', indent);
            column = 0;
        } else if (column > 0) {
            try out.appendSlice(allocator, " ");
            column += 1;
        }

        try out.appendSlice(allocator, word);
        column += word.len;
    }

    try out.appendSlice(allocator, "\n");
}

const testing = std.testing;

//
// What the test actions record, so a test can see what reached them.
//
const Recorder = struct {
    ran: bool = false,
    args: []const []const u8 = &.{},
    config: ?[]const u8 = null,
    output: ?[]const u8 = null,
    fail: bool = false,
};

//
// A test action: records what it was given, the way a real one reads its options.
//
fn recordAction(invocation: *Invocation) anyerror!void {
    const recorder: *Recorder = @constCast(@ptrCast(@alignCast(invocation.context)));
    recorder.ran = true;
    recorder.args = invocation.args;
    recorder.config = invocation.option("config");
    recorder.output = invocation.option("output");
    if (recorder.fail) return error.ActionFailed;
    invocation.exit_code = 0;
}

//
// Builds a program shaped like the tool's own, for the tests below.
//
fn buildTestProgram(allocator: std.mem.Allocator, recorder: *Recorder) !*Command {
    const root = Command.init(allocator, "what-changed");
    _ = root.description("Reports which files have changed.")
        .helpOption("--help", "Print this text.")
        .version("dev", "-v, --version", "Print the version.")
        .enablePositionalOptions();

    const summary = Command.init(allocator, "summary");
    _ = summary.description("Show the changed files grouped under the targets they fall under.")
        .option("--config <path>", "The config file to read.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(recorder, recordAction);
    root.addCommand(summary);

    const baseline = Command.init(allocator, "baseline");
    _ = baseline.description("Manage the recorded baseline.");
    _ = baseline.command("capture")
        .alias("update")
        .alias("set")
        .description("Record what the named targets watch as their baseline.")
        .argument("[target names...]", "The targets to capture.")
        .option("--config <path>", "The config file to read.", null)
        .action(recorder, recordAction);
    root.addCommand(baseline);

    const targets = Command.init(allocator, "targets");
    _ = targets.description("Print the affected target names.")
        .option("--output <format>", "How to render the result.", "text")
        .action(recorder, recordAction);
    _ = targets.enablePositionalOptions();
    _ = targets.command("list")
        .description("Print every target that can run on this platform.")
        .option("--output <format>", "How to render the result.", "text")
        .action(recorder, recordAction);
    root.addCommand(targets);

    return root;
}

//
// Runs a command line against that program and hands back what happened.
//
fn runLine(allocator: std.mem.Allocator, recorder: *Recorder, argv: []const []const u8, captured: *std.Io.Writer.Allocating) !Program {
    const root = try buildTestProgram(allocator, recorder);
    var runner = Program{ .out = &captured.writer };
    parse(&runner, root, argv) catch |err| switch (err) {
        error.Displayed, error.Refused => {},
        else => return err,
    };
    return runner;
}

test "Option.name strips the dashes and the placeholder" {
    try testing.expectEqualStrings("config", (Option{ .flags = "--config <path>", .description = "", .default_value = null }).name());
    try testing.expectEqualStrings("output", (Option{ .flags = "--output <format>", .description = "", .default_value = null }).name());
    try testing.expectEqualStrings("force", (Option{ .flags = "--force", .description = "", .default_value = null }).name());
}

test "isOption tells an option from a value" {
    try testing.expect(isOption("--config"));
    try testing.expect(isOption("-v"));
    try testing.expect(!isOption("-"));
    try testing.expect(!isOption("summary"));
    try testing.expect(!isOption(""));
}

test "isVariadic reads the ellipsis in an argument spec" {
    try testing.expect(isVariadic("[target names...]"));
    try testing.expect(!isVariadic("[name]"));
    try testing.expect(!isVariadic("<name>"));
}

test "namedBy matches any spelling in a flag list" {
    try testing.expect(namedBy("-v, --version", "-v"));
    try testing.expect(namedBy("-v, --version", "--version"));
    try testing.expect(namedBy("--help", "--help"));
    try testing.expect(!namedBy("--help", "-h"));
}

test "matches accepts a command's name and every alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const command = Command.init(arena.allocator(), "capture");
    _ = command.alias("update").alias("set");

    try testing.expect(command.matches("capture"));
    try testing.expect(command.matches("update"));
    try testing.expect(command.matches("set"));
    try testing.expect(!command.matches("reset"));
}

test "findOption finds an option by any of its spellings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const command = Command.init(arena.allocator(), "summary");
    _ = command.option("--config <path>", "The config file.", null);

    try testing.expect(command.findOption("--config") != null);
    try testing.expect(command.findOption("--nope") == null);
}

test "command adds a subcommand and returns the child to chain onto" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parent = Command.init(arena.allocator(), "baseline");
    const child = parent.command("capture");

    try testing.expectEqual(@as(usize, 1), parent.subcommands.items.len);
    try testing.expectEqualStrings("capture", child.command_name);
    try testing.expect(parent.findSubcommand("capture") != null);
}

test "an action runs and reads the options it was given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{ "summary", "--config", "custom.yaml" }, &captured);

    try testing.expect(recorder.ran);
    try testing.expectEqualStrings("custom.yaml", recorder.config.?);
    try testing.expectEqual(@as(u8, 0), runner.exit_code);
}

test "an option with a default arrives even when the command line is silent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{"summary"}, &captured);

    try testing.expectEqualStrings("text", recorder.output.?);
    try testing.expect(recorder.config == null);
}

test "an option reaches the subcommand it follows, not the parent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // The regression the whole positional-options rule exists for. Without it "--output" after
    // "list" resolves to the parent's copy, where the subcommand never sees it, and the request for
    // json quietly returns text.
    //
    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "targets", "list", "--output", "json" }, &captured);

    try testing.expect(recorder.ran);
    try testing.expectEqualStrings("json", recorder.output.?);
}

test "a subcommand alias reaches the same action" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for ([_][]const u8{ "capture", "update", "set" }) |word| {
        var recorder = Recorder{};
        var captured = std.Io.Writer.Allocating.init(allocator);
        _ = try runLine(allocator, &recorder, &.{ "baseline", word, "unit" }, &captured);

        try testing.expect(recorder.ran);
        try testing.expectEqualStrings("unit", recorder.args[0]);
    }
}

test "a variadic argument collects every name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "baseline", "capture", "unit", "documentation" }, &captured);

    try testing.expectEqual(@as(usize, 2), recorder.args.len);
    try testing.expectEqualStrings("documentation", recorder.args[1]);
}

test "arguments and options can be given together" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "baseline", "capture", "unit", "--config", "c.yaml" }, &captured);

    try testing.expectEqualStrings("unit", recorder.args[0]);
    try testing.expectEqualStrings("c.yaml", recorder.config.?);
}

test "-- lets an argument that starts with a dash through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "baseline", "capture", "--", "--odd-name" }, &captured);

    try testing.expectEqualStrings("--odd-name", recorder.args[0]);
}

test "an unknown option is refused in commander's words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{"--nosuchoption"}, &captured);

    try testing.expectEqualStrings("error: unknown option '--nosuchoption'", runner.message.?);
    try testing.expect(!recorder.ran);
}

test "an option with no value is refused, quoting the flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{ "summary", "--config" }, &captured);

    try testing.expectEqualStrings("error: option '--config <path>' argument missing", runner.message.?);
}

test "an unknown command is refused and named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{"badcommand"}, &captured);

    try testing.expectEqualStrings("error: unknown command 'badcommand'", runner.message.?);
}

test "an argument a command does not take is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{ "summary", "extra" }, &captured);

    try testing.expect(std.mem.startsWith(u8, runner.message.?, "error: too many arguments"));
}

test "an option a subcommand does not declare is refused rather than ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{ "baseline", "capture", "--output", "json" }, &captured);

    try testing.expectEqualStrings("error: unknown option '--output'", runner.message.?);
}

test "--help prints the help and does not run anything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{"--help"}, &captured);

    try testing.expect(std.mem.startsWith(u8, captured.written(), "Usage: what-changed"));
    try testing.expect(!recorder.ran);
}

test "--help after a command explains that command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{ "summary", "--help" }, &captured);

    try testing.expect(std.mem.startsWith(u8, captured.written(), "Usage: summary"));
    try testing.expect(!recorder.ran);
}

test "the program's help option can be respelled, and the default one then stops working" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // The program declares "--help" only, so "-h" is not a flag it knows.
    //
    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{"-h"}, &captured);

    try testing.expectEqualStrings("error: unknown option '-h'", runner.message.?);
}

test "--version and -v print the version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for ([_][]const u8{ "--version", "-v" }) |flag| {
        var recorder = Recorder{};
        var captured = std.Io.Writer.Allocating.init(allocator);
        _ = try runLine(allocator, &recorder, &.{flag}, &captured);

        try testing.expectEqualStrings("dev\n", captured.written());
        try testing.expect(!recorder.ran);
    }
}

test "a command with subcommands and no action of its own prints its help" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    var captured = std.Io.Writer.Allocating.init(allocator);
    _ = try runLine(allocator, &recorder, &.{"baseline"}, &captured);

    try testing.expect(std.mem.startsWith(u8, captured.written(), "Usage: baseline"));
    try testing.expect(!recorder.ran);
}

test "an action that fails makes the parse a refusal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{ .fail = true };
    var captured = std.Io.Writer.Allocating.init(allocator);
    const runner = try runLine(allocator, &recorder, &.{"summary"}, &captured);

    try testing.expect(recorder.ran);
    try testing.expectEqual(@as(u8, 1), runner.exit_code);
}

test "renderHelp lays the program out in commander's shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var recorder = Recorder{};
    const root = try buildTestProgram(allocator, &recorder);
    const help = try renderHelp(allocator, root);

    try testing.expect(std.mem.startsWith(u8, help, "Usage: what-changed [options] [command]\n"));
    try testing.expect(std.mem.indexOf(u8, help, "\nOptions:\n") != null);
    try testing.expect(std.mem.indexOf(u8, help, "  -v, --version      Print the version.") != null);
    try testing.expect(std.mem.indexOf(u8, help, "  --help             Print this text.") != null);
    try testing.expect(std.mem.indexOf(u8, help, "\nCommands:\n") != null);
    try testing.expect(std.mem.indexOf(u8, help, "  summary [options]") != null);
    try testing.expect(std.mem.indexOf(u8, help, "  help [command]     display help for command") != null);
}

test "renderHelp names a subcommand's aliases and what it accepts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const baseline = Command.init(allocator, "baseline");
    _ = baseline.command("capture")
        .alias("update")
        .alias("set")
        .description("Record the baseline.")
        .argument("[target names...]", "The targets.")
        .option("--config <path>", "The config file.", null);

    const help = try renderHelp(allocator, baseline);
    try testing.expect(std.mem.indexOf(u8, help, "capture|update|set [options] [target names...]") != null);
}

test "renderHelp shows an option's default the way commander does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // A short description, so the default is not pushed onto the next line by the wrapping. That
    // the long form wraps is checked separately; this is about the default being shown at all.
    //
    const command = Command.init(allocator, "summary");
    _ = command.option("--output <format>", "How to render.", "text");

    const help = try renderHelp(allocator, command);
    try testing.expect(std.mem.indexOf(u8, help, "How to render. (default: \"text\")") != null);
}

test "renderHelp puts the extra text after everything else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const command = Command.init(allocator, "capture");
    _ = command.description("Record the baseline.").addHelpText("after", "\nCapture one target only after it has passed.");

    const help = try renderHelp(allocator, command);
    try testing.expect(std.mem.endsWith(u8, help, "Capture one target only after it has passed.\n"));
}

test "renderHelp wraps a long description rather than running past the width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const command = Command.init(allocator, "targets");
    _ = command.description("Print the names of the targets affected by the current changes, one per line. Targets that cannot run on this platform are never named.");

    const help = try renderHelp(allocator, command);
    var lines = std.mem.splitScalar(u8, help, '\n');
    while (lines.next()) |line| {
        try testing.expect(line.len <= HELP_TOTAL_WIDTH);
    }
}

test "a usage line only claims what the command actually takes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bare = Command.init(allocator, "bare");
    try testing.expect(std.mem.startsWith(u8, try renderHelp(allocator, bare), "Usage: bare\n"));

    const with_options = Command.init(allocator, "opts");
    _ = with_options.option("--config <path>", "The config file.", null);
    try testing.expect(std.mem.startsWith(u8, try renderHelp(allocator, with_options), "Usage: opts [options]\n"));
}
