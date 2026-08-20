//
// The `targets` command: the names of the targets affected by the current changes, and `targets
// list`, the names of every target that could run here at all.
//

const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;

//
// Prints one affected target name per line, and nothing else, so a script can read the list without
// picking it out of prose.
//
pub fn targetsCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.compareFileTree(context, .{ .options = options, .mode = .targets });
}

//
// Prints every target the config declares that can run on this platform, whatever has changed.
//
// This is the list a script wants when it is running everything rather than only what changed.
// Taking it from here rather than keeping its own copy is what stops that path from asking for a
// target the machine has no toolchain for.
//
pub fn targetsListCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.listTargets(context, options);
}

//
// Builds the `targets` command and its `list` subcommand.
//
pub fn buildTargetsCommand(context: *const Context) *Command {
    const cmd = Command.init(context.allocator, "targets")
        .description("Print the names of the targets affected by the current changes, one per line. Targets that cannot run on this platform are never named.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, action);

    //
    // This command has both its own options and a subcommand declaring the same option names.
    // Without positional options "--output" after "list" resolves to this command's copy, where the
    // subcommand never sees it: the flag is accepted, silently ignored, and the default used
    // instead. The same mistake as the --config one smoke scenario 3b guards against.
    //
    _ = cmd.enablePositionalOptions();

    _ = cmd.command("list")
        .description("Print every target that can run on this platform, one per line, regardless of what changed.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, listAction);

    return cmd;
}

fn action(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try targetsCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

fn listAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try targetsListCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("targets.test.zig");
}
