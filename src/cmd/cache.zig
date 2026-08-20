const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const ReportOptions = wc.run.ReportOptions;

//
// The `cache` command and its subcommands.
//
// This is the file hash cache only: the per-file hashes kept so an unchanged file is never read
// twice. Nothing in it affects what the tool reports, so emptying it costs one slow run and nothing
// else. The baseline is a different thing entirely and lives elsewhere, under `what-changed
// baseline`.
//

//
// Resolves the cache directory the config points at.
//
pub fn resolveCacheDir(context: *const Context, options: ReportOptions) wc.failure.Error![]const u8 {
    const config_path = try wc.config.resolveConfigPath(context.io, context.allocator, options.config, context.cwd, context.fail);
    const root_dir = wc.files.dirName(config_path);
    const config = try wc.config.loadConfig(context.io, context.allocator, config_path, context.fail);
    return wc.files.resolvePath(context.allocator, root_dir, config.cache_dir);
}

//
// Empties the file hash cache, so the next report rehashes every file.
//
pub fn cacheResetCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    const cache_dir = try resolveCacheDir(context, options);

    wc.cache_store.cacheReset(context.io, context.allocator, cache_dir) catch |err| {
        return context.fail.set("Failed to reset the cache in \"{s}\": {s}", .{ cache_dir, wc.files.describeError(err) });
    };

    context.out.line("Cache reset. The next report will rehash every file. The baseline is untouched.", .{});
    return 0;
}

//
// Rehashes the current tree and stores the result, so the next report has nothing to read.
//
// This is only ever a speed-up. It records no baseline and changes nothing about what a later report
// will say has changed.
//
pub fn cacheCaptureCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    return wc.run.runCacheCapture(context, options);
}

//
// Says where the cache is kept and how much is in it.
//
pub fn cacheShowCommand(context: *const Context, options: ReportOptions) wc.failure.Error!u8 {
    const allocator = context.allocator;

    const cache_dir = try resolveCacheDir(context, options);
    var cache = try wc.cache_store.loadCache(context.io, allocator, cache_dir);
    const entry_count = cache.file_hashes.count();
    const format = try wc.output.parseOutputFormat(options.output, context.fail);

    if (format != .text) {
        var object = wc.value.newObject(allocator);
        try object.put(allocator, "cacheDir", wc.value.str(cache_dir));
        try object.put(allocator, "entryCount", wc.value.int(@intCast(entry_count)));
        try wc.output.printStructured(allocator, context.out, .{ .object = object }, format);
        return 0;
    }

    context.out.line("Cache directory: {s}", .{cache_dir});
    context.out.line("{d} file hash(es) cached.", .{entry_count});
    context.out.blank();
    context.out.line("This is a file hash cache only. Resetting it changes nothing about what is reported.", .{});
    return 0;
}

//
// Builds the `cache` command.
//
pub fn cacheCommand(context: *const Context) *Command {
    const cmd = Command.init(context.allocator, "cache")
        .description("Manage the file hash cache. Nothing in it affects what is reported.");

    _ = cmd.command("capture")
        .alias("update")
        .description("Refresh the cached hashes for the current tree, so the next report is fast.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .action(context, captureAction);

    _ = cmd.command("reset")
        .description("Empty the cache, so the next report rehashes every file. The baseline is untouched.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .action(context, resetAction);

    _ = cmd.command("show")
        .description("Show where the cache is kept and how much is in it.")
        .option("--config <path>", "The config file to read. Defaults to what-changed.yaml, .yml or .json in the working directory.", null)
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, showAction);

    return cmd;
}

fn captureAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try cacheCaptureCommand(context, .{ .config = invocation.option("config") });
}

fn resetAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try cacheResetCommand(context, .{ .config = invocation.option("config") });
}

fn showAction(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try cacheShowCommand(context, .{
        .config = invocation.option("config"),
        .output = invocation.option("output"),
    });
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("cache.test.zig");
}
