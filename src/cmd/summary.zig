//
// The `summary` command: the changed files grouped under the targets they fall under.
//

const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;

//
// Prints each target with the changed files under it, then any changed file no target watches.
//
pub fn summaryCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.compareFileTree(context, .{ .options = options, .mode = .summary });
}

//
// Builds the `summary` command.
//
pub fn buildSummaryCommand(context: *const Context) *Command {
    return Command.init(context.allocator, "summary")
        .description("Show the changed files grouped under the targets they fall under.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, action);
}

//
// The action, which reads its options and hands them on.
//
// A Zig function pointer captures nothing, so the context arrives through the invocation instead.
//
fn action(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try summaryCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("summary.test.zig");
}
