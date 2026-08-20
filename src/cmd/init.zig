const std = @import("std");
const wc = @import("what-changed");

const commander = wc.commander;

const Command = commander.Command;
const Context = wc.run.Context;
const Failure = wc.failure.Failure;

//
// The `init` command: set a project up in one step.
//
// Setting up by hand is two things that are easy to get half right: write a config, and ignore
// `.what-changed/`. Forgetting the second is the one that costs something, because the tool lists
// untracked files, so an un-ignored `.what-changed/` reports itself as changed on every run and
// every target looks affected forever.
//
// Neither half ever overwrites anything. That is the whole safety of the command: it is run against
// projects that may already be set up, and a config someone has tuned is not recoverable once it has
// been written over.
//

//
// The config written into a project that has none.
//
// Placeholder targets, because nothing here can know what a project builds. The `.gitignore` line is
// the part that has to be right, and it is the part people forget; the targets are a starting point
// the user edits.
//
pub const STARTER_CONFIG =
    \\# what-changed configuration.
    \\#
    \\# Edit the targets below. Each one names a build or test step, and the paths whose
    \\# content decides whether that step has to run again.
    \\
    \\always:
    \\  - package.json
    \\
    \\ignore:
    \\  - .md
    \\  - .txt
    \\  - .log
    \\
    \\targets:
    \\  - name: compile
    \\    paths:
    \\      - src
    \\
    \\  - name: test
    \\    paths:
    \\      - src
    \\
;

//
// The name the starter config is written under.
//
// The first of the names the tool looks for, taken from that list rather than spelled out again, so
// this can never write a file the tool would not then find.
//
pub const STARTER_CONFIG_NAME = wc.config.DEFAULT_CONFIG_NAMES[0];

//
// The file the ignore entry goes in.
//
pub const GITIGNORE_NAME = ".gitignore";

//
// The line added to `.gitignore`: everything this tool writes lives under that directory.
//
pub const GITIGNORE_ENTRY = ".what-changed/";

//
// The same entry without its trailing slash, which git honours identically.
//
// Checked for as well as the spelling above, so a project that already ignores `.what-changed` is
// left alone rather than given a second line saying the same thing.
//
pub const GITIGNORE_ENTRY_NO_SLASH = ".what-changed";

//
// What one half of `init` did.
//
// Reported as a value and not only as printed text, so a test can assert on the outcome without
// reading prose that is free to be reworded.
//
pub const InitStep = enum {
    //
    // The file was written: it was not there, or it was there without the entry.
    //
    created,

    //
    // Nothing was written, because what this step would have added is already there.
    //
    already_present,
};

//
// Writes the starter config, unless the project already has one.
//
// Every name the tool would look for counts as "already has one", not just the name this would
// write. A project with a `what-changed.json` is set up, and adding a `what-changed.yaml` beside it
// would take precedence over the config that project has been using.
//
pub fn writeStarterConfig(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, fail: *Failure) wc.failure.Error!InitStep {
    for (wc.config.DEFAULT_CONFIG_NAMES) |name| {
        const candidate = try wc.files.joinPath(allocator, &.{ cwd, name });
        if (wc.files.fileExists(io, candidate)) {
            return .already_present;
        }
    }

    const config_path = try wc.files.joinPath(allocator, &.{ cwd, STARTER_CONFIG_NAME });
    wc.files.writeFile(io, config_path, STARTER_CONFIG) catch |err| {
        return fail.set("Failed to write the what-changed config at \"{s}\": {s}", .{
            config_path, try wc.files.describeOperation(allocator, err, "write", config_path),
        });
    };

    return .created;
}

//
// Adds `.what-changed/` to the project's `.gitignore`, unless it is already ignored.
//
// This is the only file the tool writes that the user owns, so the append is as small as it can be:
// it never rewrites a line, never reorders anything, and does not touch the file at all when the
// entry is already there.
//
pub fn addGitignoreEntry(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, fail: *Failure) wc.failure.Error!InitStep {
    const gitignore_path = try wc.files.joinPath(allocator, &.{ cwd, GITIGNORE_NAME });

    //
    // A read that fails means there is no `.gitignore` worth appending to, so one is written. The
    // reason is not worth telling apart here: if the file cannot be read, the write below reports
    // whatever is actually wrong with the path.
    //
    const existing = wc.files.readFile(io, allocator, gitignore_path) catch {
        try writeGitignore(io, allocator, gitignore_path, GITIGNORE_ENTRY ++ "\n", fail);
        return .created;
    };

    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |raw_line| {
        //
        // Trimmed before comparing so an indented entry, or one left with the carriage return of a
        // file written on Windows, still counts as already ignored.
        //
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.eql(u8, line, GITIGNORE_ENTRY) or std.mem.eql(u8, line, GITIGNORE_ENTRY_NO_SLASH)) {
            return .already_present;
        }
    }

    //
    // A file that does not end in a newline would otherwise have the entry land on the end of
    // somebody else's line, which changes what that line ignores.
    //
    const separator: []const u8 = if (existing.len == 0 or existing[existing.len - 1] == '\n') "" else "\n";
    const updated = try std.fmt.allocPrint(allocator, "{s}{s}{s}\n", .{ existing, separator, GITIGNORE_ENTRY });

    try writeGitignore(io, allocator, gitignore_path, updated, fail);
    return .created;
}

//
// Writes the `.gitignore`, saying which file could not be written when it fails.
//
// Its own function because both branches above write, and a failure to write the file the user owns
// is worth the same message either way.
//
fn writeGitignore(io: std.Io, allocator: std.mem.Allocator, gitignore_path: []const u8, contents: []const u8, fail: *Failure) wc.failure.Error!void {
    wc.files.writeFile(io, gitignore_path, contents) catch |err| {
        return fail.set("Failed to write \"{s}\": {s}", .{
            gitignore_path, try wc.files.describeOperation(allocator, err, "write", gitignore_path),
        });
    };
}

//
// Sets the project up: a config to edit, and `.what-changed/` ignored.
//
// Returns 0 even when both were already there. Finding the project already set up is a successful
// answer to "set this project up", and a build script that runs `init` before anything else should
// not fail on the second run.
//
pub fn initCommand(context: *const Context) wc.failure.Error!u8 {
    const config_step = try writeStarterConfig(context.io, context.allocator, context.cwd, context.fail);
    switch (config_step) {
        .created => context.out.line("Wrote {s}.", .{STARTER_CONFIG_NAME}),
        .already_present => context.out.line("This project already has a what-changed config, so none was written.", .{}),
    }

    const gitignore_step = try addGitignoreEntry(context.io, context.allocator, context.cwd, context.fail);
    switch (gitignore_step) {
        .created => context.out.line("Added {s} to {s}.", .{ GITIGNORE_ENTRY, GITIGNORE_NAME }),
        .already_present => context.out.line("{s} already ignores {s}, so it was left alone.", .{ GITIGNORE_NAME, GITIGNORE_ENTRY }),
    }

    //
    // Said only when a config was written, because it is about the placeholder targets in that
    // config. A project that already had one has targets of its own and nothing to edit.
    //
    if (config_step == .created) {
        context.out.line("Edit the targets in {s}, then run: what-changed summary", .{STARTER_CONFIG_NAME});
    }

    return 0;
}

//
// Builds the `init` command.
//
// No --config option: everywhere else in the tool that means "read this config", and here it would
// mean "write here", which is the kind of difference nobody reads a help page carefully enough to
// notice. No --output either, for the same reason `baseline capture` has none: this is an action,
// not a question with an answer to render.
//
pub fn buildInitCommand(context: *const Context) *Command {
    return Command.init(context.allocator, "init")
        .description("Write a starter config and add .what-changed/ to .gitignore. Neither is overwritten.")
        .action(context, action);
}

fn action(invocation: *commander.Invocation) anyerror!void {
    const context: *const Context = @ptrCast(@alignCast(invocation.context));
    invocation.exit_code = try initCommand(context);
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("init.test.zig");
}
