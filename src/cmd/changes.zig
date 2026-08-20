//
// The `changes` command: the changed files as a flat list, without sorting them into targets.
//

const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;

//
// Prints every file that differs from the baseline.
//
pub fn changesCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.compareFileTree(context, .{ .options = options, .mode = .files });
}

//
// Builds the `changes` command.
//
pub fn buildChangesCommand(context: *const Context) *Command {
    return Command.init(context.allocator, "changes")
        .description("List the files that have changed since the baseline, as a flat list.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, action);
}

fn action(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try changesCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("changes.test.zig");
}
