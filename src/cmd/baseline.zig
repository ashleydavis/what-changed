const std = @import("std");
const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;
const Failure = wc.failure.Failure;

//
// The `baseline` command and its subcommands.
//
// The baseline is the reference point every report is measured against. It is deliberately not part
// of the file hash cache: losing the cache costs a slow run, losing this changes the answer.
//

//
// Resolves the baseline file the config points at.
//
pub fn resolveBaselinePath(context: *const Context, options: ReportOptions) wc.failure.Error![]const u8 {
    const config_path = try wc.config.resolveConfigPath(context.io, context.allocator, options.config, context.cwd, context.fail);
    const root_dir = wc.files.dirName(config_path);
    const config = try wc.config.loadConfig(context.io, context.allocator, config_path, context.fail);
    return wc.files.resolvePath(context.allocator, root_dir, config.baseline_path);
}

//
// Records what the named targets currently watch as their baseline. With no names, every target.
//
pub fn baselineSetCommand(context: *const Context, options: ReportOptions, target_names: []const []const u8) wc.failure.Error!u8 {
    return wc.run.runBaseline(context, options, target_names);
}

//
// Forgets the baseline, so the next report treats every file as new.
//
pub fn baselineResetCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    const baseline_path = try resolveBaselinePath(context, options);

    wc.baseline_store.baselineReset(context.io, context.allocator, baseline_path) catch |err| {
        return context.fail.set("Failed to reset the baseline at \"{s}\": {s}", .{ baseline_path, wc.files.describeError(err) });
    };

    context.out.line("Baseline reset. The next report will treat every file as new.", .{});
    return 0;
}

//
// Says where the baseline is kept and how much is in it.
//
pub fn baselineShowCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    const allocator = context.allocator;

    const baseline_path = try resolveBaselinePath(context, options);
    const loaded = try wc.baseline_store.loadBaseline(context.io, allocator, baseline_path);
    var baseline = loaded.baseline;
    const format = try wc.output.parseOutputFormat(options.output, context.fail);

    const target_names = try allocator.dupe([]const u8, baseline.targets.keys());
    std.mem.sort([]const u8, target_names, {}, wc.file_hashes.lessThanPath);

    if (format != .text) {
        var targets = wc.value.newArray(allocator);
        for (target_names) |name| {
            var entry = wc.value.newObject(allocator);
            try entry.put(allocator, "name", wc.value.str(name));
            try entry.put(allocator, "fileCount", wc.value.int(@intCast(baseline.targets.get(name).?.count())));
            try targets.append(.{ .object = entry });
        }

        var object = wc.value.newObject(allocator);
        try object.put(allocator, "baselinePath", wc.value.str(baseline_path));
        try object.put(allocator, "status", wc.value.str(loaded.source.statusText()));
        try object.put(allocator, "targets", .{ .array = targets });
        try wc.output.printStructured(allocator, context.out, .{ .object = object }, format);
        return 0;
    }

    context.out.line("Baseline file: {s}", .{baseline_path});

    //
    // Said before anything about targets, because it explains why there are none to report. Without
    // it a file that is sitting right there and cannot be used reads exactly like one that was never
    // written, which is the one thing this command exists to tell apart.
    //
    if (describeUnusable(loaded.source)) |problem| {
        context.out.line("{s} Everything counts as changed until it is fixed or reset.", .{problem});
        return 0;
    }

    if (target_names.len == 0) {
        context.out.line("No target has been captured yet, so everything counts as changed.", .{});
        return 0;
    }

    //
    // One line per target rather than one per file. The file lists are per target and overlap
    // heavily, so printing them all would be thousands of lines saying the same thing repeatedly.
    //
    context.out.line("{d} target(s) captured:", .{target_names.len});
    for (target_names) |name| {
        context.out.line("  {s}: {d} file(s)", .{ name, baseline.targets.get(name).?.count() });
    }
    return 0;
}

//
// Says what is wrong with a baseline file that is there and cannot be used, or null when there is
// nothing wrong with it.
//
// A file that is absent is not a problem: it is a project that has not captured anything yet, which
// the caller has its own sentence for.
//
fn describeUnusable(source: wc.cache_store.JsonObjectFile) ?[]const u8 {
    return switch (source) {
        .object, .absent => null,
        .unreadable => "The file is there and could not be read.",
        .not_json => "The file is there and is not valid JSON.",
        .not_an_object => "The file is there and does not hold a JSON object.",
    };
}

//
// Builds the `baseline` command.
//
pub fn baselineCommand(context: *const Context) *Command {
    const cmd = Command.init(context.allocator, "baseline")
        .description("Manage the recorded baseline that changes are measured against.");

    _ = cmd.command("capture")
        .alias("update")
        .alias("set")
        .description("Record what the named targets watch as their baseline. With no names, every target.")
        .argument("[target names...]", "The targets to capture. With none, every target in the config is captured.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .addHelpText("after",
        \\
        \\Capture one target only after that target has actually passed. Capturing a target says "this suite
        \\passed against these files", so capturing one that did not run marks it as up to date when it is not.
    )
        .action(context, captureAction);

    _ = cmd.command("reset")
        .description("Forget the baseline, so the next report treats every file as new.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .action(context, resetAction);

    _ = cmd.command("show")
        .description("Show where the baseline is kept and what is recorded in it.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, showAction);

    return cmd;
}

fn captureAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try baselineSetCommand(context, .{ .config = invocation.option("config") }, invocation.args);
}

fn resetAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try baselineResetCommand(context, .{ .config = invocation.option("config") });
}

fn showAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try baselineShowCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("baseline.test.zig");
}
