const std = @import("std");
const annotate_mod = @import("log");

//
// The branch markers a fault run reads back. `an` is a compile-time flag: the binary people run is
// built with it off, so every `if (an) annotate(...)` below compiles to nothing there.
//
const Log = annotate_mod.Log;
const an = annotate_mod.an;
const annotate = annotate_mod.annotate;

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
// Public only so the tests in commander.test.zig can reach it. Nothing else calls it.
//
//
pub const HELP_TOTAL_WIDTH = 80;

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
    // Where this option's own branch markers go.
    //
    log: Log = .{},

    //
    // The name an action looks it up by: the flags with the leading dashes and the placeholder
    // taken off, so "--config <path>" is read as "config".
    //
    pub fn name(self: Option) []const u8 {
        var text = self.flags;
        if (std.mem.indexOfScalar(u8, text, ' ')) |space| {
            if (an) annotate(self.log, "name-has-a-placeholder", "", .{});
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
    // Where this invocation's own branch markers go.
    //
    log: Log = .{},

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
    // Where this command's own branch markers go. Carried here rather than passed to each builder
    // method, because a definition is one chain of calls onto the command itself.
    //
    log: Log = .{},

    //
    // Makes a command.
    //
    // Panics if there is no memory, rather than returning an error, which is what every builder
    // method below does too. The command tree is built once at startup out of string literals: if
    // that cannot be allocated then nothing else in the run was going to work either, and returning
    // an error here would only mean a `try` on every call and no chaining, which is the whole point
    // of writing it this way.
    //
    pub fn init(allocator: std.mem.Allocator, command_name: []const u8, log: Log) *Command {
        const created = allocator.create(Command) catch @panic("out of memory building the command line");
        created.* = .{ .allocator = allocator, .command_name = command_name, .log = log };
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
        const sub = Command.init(self.allocator, sub_name, self.log);
        self.addCommand(sub);
        return sub;
    }

    //
    // True when a word names this command.
    //
    pub fn matches(self: *const Command, word: []const u8) bool {
        if (std.mem.eql(u8, self.command_name, word)) {
            if (an) annotate(self.log, "matches-its-own-name", "", .{});
            return true;
        }
        for (self.aliases.items) |alias_name| {
            if (an) annotate(self.log, "matches-aliases-iteration", "", .{});
            if (std.mem.eql(u8, alias_name, word)) {
                if (an) annotate(self.log, "matches-an-alias", "", .{});
                return true;
            }
        }
        return false;
    }

    //
    // The subcommand a word names, or null.
    //
    pub fn findSubcommand(self: *const Command, word: []const u8) ?*Command {
        for (self.subcommands.items) |sub| {
            if (an) annotate(self.log, "findSubcommand-subcommands-iteration", "", .{});
            if (sub.matches(word)) {
                if (an) annotate(self.log, "findSubcommand-found", "", .{});
                return sub;
            }
        }
        return null;
    }

    //
    // The option a flag names, or null.
    //
    pub fn findOption(self: *const Command, flag: []const u8) ?Option {
        for (self.options.items) |candidate| {
            if (an) annotate(self.log, "findOption-options-iteration", "", .{});
            var flags = std.mem.splitSequence(u8, candidate.flags, ", ");
            while (flags.next()) |spelling| {
                if (an) annotate(self.log, "findOption-spellings-iteration", "", .{});
                var spelled = spelling;
                if (std.mem.indexOfScalar(u8, spelled, ' ')) |space| {
                    if (an) annotate(self.log, "findOption-has-a-placeholder", "", .{});
                    spelled = spelled[0..space];
                }
                if (std.mem.eql(u8, spelled, flag)) {
                    if (an) annotate(self.log, "findOption-found", "", .{});
                    return candidate;
                }
            }
        }
        return null;
    }

    //
    // True when a flag is one of the spellings of this command's help option.
    //
    pub fn isHelpFlag(self: *const Command, flag: []const u8) bool {
        return namedBy(self.help_flags, flag, self.log);
    }

    //
    // True when a flag is one of the spellings of this command's version option.
    //
    pub fn isVersionFlag(self: *const Command, flag: []const u8) bool {
        if (self.version_text == null) {
            if (an) annotate(self.log, "isVersionFlag-no-version", "", .{});
            return false;
        }
        return namedBy(self.version_flags, flag, self.log);
    }
};

//
// A fresh root command, the way commander exports a ready-made `program`.
//
// Commander's is a module-level singleton. This one is made per call, because it needs an allocator
// and because a singleton would make two programs in one test share state.
//
pub fn program(allocator: std.mem.Allocator, log: Log) *Command {
    return Command.init(allocator, "", log);
}

//
// True when a flag appears in a comma-separated spelling list such as "-v, --version".
//
pub fn namedBy(flags: []const u8, flag: []const u8, log: Log) bool {
    var spellings = std.mem.splitSequence(u8, flags, ", ");
    while (spellings.next()) |spelling| {
        if (an) annotate(log, "namedBy-spellings-iteration", "", .{});
        var spelled = spelling;
        if (std.mem.indexOfScalar(u8, spelled, ' ')) |space| {
            if (an) annotate(log, "namedBy-has-a-placeholder", "", .{});
            spelled = spelled[0..space];
        }
        if (std.mem.eql(u8, spelled, flag)) {
            if (an) annotate(log, "namedBy-found", "", .{});
            return true;
        }
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
    // Where this program's own branch markers go.
    //
    log: Log = .{},

    //
    // Records why the command line was refused, in commander's wording.
    //
    fn refuse(self: *Program, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error {
        self.message = std.fmt.allocPrint(allocator, fmt, args) catch {
            if (an) annotate(self.log, "refuse-no-room", "", .{});
            return error.OutOfMemory;
        };
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
        if (an) annotate(runner.log, "parse-words-iteration", "", .{});
        const word = argv[at];

        if (!options_ended and std.mem.eql(u8, word, "--")) {
            if (an) annotate(runner.log, "parse-end-of-options", "", .{});
            options_ended = true;
            continue;
        }

        if (!options_ended and isOption(word)) {
            if (an) annotate(runner.log, "parse-an-option", "", .{});
            if (current.isHelpFlag(word)) {
                if (an) annotate(runner.log, "parse-help-asked-for", "", .{});
                try writeHelp(runner.out, current, allocator);
                return error.Displayed;
            }
            if (current.isVersionFlag(word)) {
                if (an) annotate(runner.log, "parse-version-asked-for", "", .{});
                runner.out.print("{s}\n", .{current.version_text.?}) catch {
                    if (an) annotate(runner.log, "parse-nowhere-to-print-the-version", "", .{});
                };
                return error.Displayed;
            }

            const found = current.findOption(word) orelse {
                if (an) annotate(runner.log, "parse-unknown-option", "", .{});
                return runner.refuse(allocator, "error: unknown option '{s}'", .{word});
            };

            //
            // Every option this tool has takes a value, so a flag at the end of the line is a
            // missing value rather than a flag on its own.
            //
            at += 1;
            if (at >= argv.len) {
                if (an) annotate(runner.log, "parse-option-value-missing", "", .{});
                return runner.refuse(allocator, "error: option '{s}' argument missing", .{found.flags});
            }
            try values.put(allocator, found.name(), argv[at]);
            continue;
        }

        //
        // Not an option. It either names a subcommand or is a positional argument.
        //
        if (positionals.items.len == 0) {
            if (an) annotate(runner.log, "parse-nothing-positional-yet", "", .{});
            if (current.findSubcommand(word)) |sub| {
                if (an) annotate(runner.log, "parse-a-subcommand", "", .{});
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
            if (an) annotate(runner.log, "parse-takes-no-argument", "", .{});
            //
            // A word where nothing is expected. When the command has subcommands, commander calls
            // it an unknown command; otherwise it is one argument too many.
            //
            if (current.subcommands.items.len > 0) {
                if (an) annotate(runner.log, "parse-unknown-command", "", .{});
                return runner.refuse(allocator, "error: unknown command '{s}'", .{word});
            }
            return runner.refuse(allocator, "error: too many arguments. Expected 0 arguments but got {d}.", .{argv.len - at});
        }

        if (positionals.items.len > 0 and !isVariadic(current.argument_spec.?.spec)) {
            if (an) annotate(runner.log, "parse-one-argument-too-many", "", .{});
            return runner.refuse(allocator, "error: too many arguments. Expected 1 argument but got {d}.", .{positionals.items.len + 1});
        }

        try positionals.append(allocator, word);
    }

    //
    // Any option with a default that was not given takes that default, which is how `--output`
    // arrives as "text" without the command line saying so.
    //
    for (current.options.items) |candidate| {
        if (an) annotate(runner.log, "parse-defaults-iteration", "", .{});
        if (candidate.default_value) |default_value| {
            if (an) annotate(runner.log, "parse-has-a-default", "", .{});
            if (!values.contains(candidate.name())) {
                if (an) annotate(runner.log, "parse-default-used", "", .{});
                try values.put(allocator, candidate.name(), default_value);
            }
        }
    }

    //
    // A command with subcommands and no action of its own prints its help, which is what commander
    // does for a bare `what-changed baseline`.
    //
    const run = current.action_fn orelse {
        if (an) annotate(runner.log, "parse-no-action", "", .{});
        try writeHelp(runner.out, current, allocator);
        return error.Displayed;
    };

    var invocation = Invocation{
        .context = current.action_context.?,
        .args = positionals.items,
        .values = values,
        .log = runner.log,
    };

    run(&invocation) catch |err| switch (err) {
        error.OutOfMemory => {
            if (an) annotate(runner.log, "parse-no-room", "", .{});
            return error.OutOfMemory;
        },
        else => {
            if (an) annotate(runner.log, "parse-the-action-failed", "", .{});
            //
            // An action that failed has already put its message where the CLI will find it.
            // What reaches here is only the fact that it failed.
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
    out.print("{s}", .{rendered}) catch {
        if (an) annotate(command.log, "writeHelp-nowhere-to-print", "", .{});
    };
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
        if (an) annotate(command.log, "renderHelp-takes-options", "", .{});
        try out.appendSlice(allocator, " [options]");
    }
    if (command.argument_spec) |spec| {
        if (an) annotate(command.log, "renderHelp-takes-an-argument", "", .{});
        try out.print(allocator, " {s}", .{spec.spec});
    }
    if (command.subcommands.items.len > 0) {
        if (an) annotate(command.log, "renderHelp-has-subcommands", "", .{});
        try out.appendSlice(allocator, " [command]");
    }
    try out.appendSlice(allocator, "\n");

    if (command.description_text.len > 0) {
        if (an) annotate(command.log, "renderHelp-has-a-description", "", .{});
        try out.appendSlice(allocator, "\n");
        try writeWrapped(&out, allocator, command.description_text, 0, command.log);
    }

    //
    // Options, the version first when there is one, and help last, which is commander's order.
    //
    try out.appendSlice(allocator, "\nOptions:\n");
    if (command.version_text != null) {
        if (an) annotate(command.log, "renderHelp-has-a-version", "", .{});
        try writeTwoColumn(&out, allocator, command.version_flags, command.version_description, command.log);
    }
    for (command.options.items) |candidate| {
        if (an) annotate(command.log, "renderHelp-options-iteration", "", .{});
        if (candidate.default_value) |default_value| {
            if (an) annotate(command.log, "renderHelp-option-has-a-default", "", .{});
            const text = try std.fmt.allocPrint(allocator, "{s} (default: \"{s}\")", .{ candidate.description, default_value });
            try writeTwoColumn(&out, allocator, candidate.flags, text, command.log);
        } else {
            if (an) annotate(command.log, "renderHelp-option-has-no-default", "", .{});
            try writeTwoColumn(&out, allocator, candidate.flags, candidate.description, command.log);
        }
    }
    try writeTwoColumn(&out, allocator, command.help_flags, command.help_description, command.log);

    if (command.subcommands.items.len > 0) {
        if (an) annotate(command.log, "renderHelp-lists-subcommands", "", .{});
        try out.appendSlice(allocator, "\nCommands:\n");
        for (command.subcommands.items) |sub| {
            if (an) annotate(command.log, "renderHelp-subcommands-iteration", "", .{});
            try writeTwoColumn(&out, allocator, try subcommandTerm(allocator, sub), sub.description_text, command.log);
        }
        try writeTwoColumn(&out, allocator, "help [command]", "display help for command", command.log);
    }

    if (command.help_text_after.len > 0) {
        if (an) annotate(command.log, "renderHelp-has-text-after", "", .{});
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
        if (an) annotate(sub.log, "subcommandTerm-aliases-iteration", "", .{});
        try term.print(allocator, "|{s}", .{alias_name});
    }
    if (sub.options.items.len > 0) {
        if (an) annotate(sub.log, "subcommandTerm-takes-options", "", .{});
        try term.appendSlice(allocator, " [options]");
    }
    if (sub.argument_spec) |spec| {
        if (an) annotate(sub.log, "subcommandTerm-takes-an-argument", "", .{});
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
fn writeTwoColumn(out: *std.ArrayList(u8), allocator: std.mem.Allocator, term: []const u8, text: []const u8, log: Log) std.mem.Allocator.Error!void {
    try out.print(allocator, "  {s}", .{term});

    if (text.len == 0) {
        if (an) annotate(log, "writeTwoColumn-nothing-to-describe", "", .{});
        try out.appendSlice(allocator, "\n");
        return;
    }

    //
    // A term too wide for its column pushes the description onto the next line, which is what
    // commander does rather than letting the columns run into each other.
    //
    if (term.len > HELP_TERM_WIDTH - 2) {
        if (an) annotate(log, "writeTwoColumn-term-too-wide", "", .{});
        try out.appendSlice(allocator, "\n");
        try out.appendNTimes(allocator, ' ', HELP_TERM_WIDTH + 2);
    } else {
        if (an) annotate(log, "writeTwoColumn-term-fits", "", .{});
        try out.appendNTimes(allocator, ' ', HELP_TERM_WIDTH - term.len);
    }

    try writeWrapped(out, allocator, text, HELP_TERM_WIDTH + 2, log);
}

//
// Writes text, wrapping it at the help's width and indenting every line after the first.
//
fn writeWrapped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, indent: usize, log: Log) std.mem.Allocator.Error!void {
    const width = HELP_TOTAL_WIDTH - indent;

    var column: usize = 0;
    var words = std.mem.splitScalar(u8, text, ' ');
    while (words.next()) |word| {
        if (an) annotate(log, "writeWrapped-words-iteration", "", .{});
        if (word.len == 0) {
            if (an) annotate(log, "writeWrapped-an-empty-word", "", .{});
            continue;
        }

        if (column > 0 and column + 1 + word.len > width) {
            if (an) annotate(log, "writeWrapped-wrapped", "", .{});
            try out.appendSlice(allocator, "\n");
            try out.appendNTimes(allocator, ' ', indent);
            column = 0;
        } else if (column > 0) {
            if (an) annotate(log, "writeWrapped-a-space-before-it", "", .{});
            try out.appendSlice(allocator, " ");
            column += 1;
        }

        try out.appendSlice(allocator, word);
        column += word.len;
    }

    try out.appendSlice(allocator, "\n");
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("commander.test.zig");
}
