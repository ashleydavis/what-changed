const std = @import("std");
const annotate_mod = @import("log");

//
// The branch markers a fault run reads back. `an` is a compile-time flag: the binary people run is
// built with it off, so every `if (an) annotate(...)` below compiles to nothing there.
//
const Log = annotate_mod.Log;
const an = annotate_mod.an;
const annotate = annotate_mod.annotate;
const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;

//
// The `version` command: which build this is.
//

//
// Says which build this is, and where it came from when CI built it.
//
// The metadata is a parameter rather than read from the library here, so what this prints can be
// asked of any build rather than only the one it was compiled into. The command below passes the
// one the binary carries.
//
// A released build has its commit hash and build date written into lib/version.zig by the workflow.
// A build from source reports "dev" for all of it, which is the answer that is actually true: there
// is no tag or commit that produced it.
//
pub fn versionCommand(context: *const Context, output: ?[]const u8, metadata: wc.version.BuildMetadata) wc.failure.Error!u8 {
    const log = context.fail.log;
    const allocator = context.allocator;

    const format = try wc.output.parseOutputFormat(output, context.fail);
    const is_built = !std.mem.eql(u8, metadata.commit_hash, "dev");

    if (format != .text) {
        if (an) annotate(log, "versionCommand-machine-readable", "", .{});
        var object: wc.value.Object = .empty;
        try object.put(allocator, "version", wc.value.str(wc.version.version));
        try object.put(allocator, "commitHash", wc.value.str(metadata.commit_hash));
        try object.put(allocator, "buildDate", wc.value.str(metadata.build_date));
        try object.put(allocator, "isPreRelease", wc.value.boolean(metadata.is_pre_release));
        try wc.output.printStructured(allocator, context.out, .{ .object = object }, format);
        return 0;
    }

    context.out.line("what-changed {s}", .{wc.version.version});

    if (is_built) {
        if (an) annotate(log, "versionCommand-a-release-build", "", .{});
        const commit = metadata.commit_hash;
        context.out.line("Commit: {s}", .{commit[0..@min(8, commit.len)]});
        if (!std.mem.eql(u8, metadata.build_date, "development")) {
            if (an) annotate(log, "versionCommand-has-a-build-date", "", .{});
            context.out.line("Built: {s}", .{metadata.build_date});
        }
        if (metadata.is_pre_release) {
            if (an) annotate(log, "versionCommand-a-pre-release", "", .{});
            context.out.line("Type: pre-release build", .{});
        }
    } else {
        if (an) annotate(log, "versionCommand-built-from-source", "", .{});
        context.out.line("Built from source, not from a release.", .{});
    }

    return 0;
}

//
// Builds the `version` command.
//
pub fn buildVersionCommand(context: *const Context) *Command {
    return Command.init(context.allocator, "version", context.fail.log)
        .description("Print the version and which build this is.")
        .option("--output <format>", "How to render the result: text, json or yaml.", "text")
        .action(context, action);
}

fn action(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try versionCommand(context, invocation.option("output"), wc.version.build_metadata);
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("version.test.zig");
}
