const std = @import("std");
const failure = @import("failure.zig");
const file_hashes = @import("file_hashes.zig");

const Failure = failure.Failure;

//
// The most output `git ls-files` may produce before this gives up.
//
// A path averages well under 100 bytes, so this clears a repository of several hundred thousand
// files. A ceiling is needed at all because a runaway output has to stop somewhere rather than
// being read into memory without limit.
//
const MAX_GIT_OUTPUT_BYTES = 64 * 1024 * 1024;

//
// Enumerates the files a run considers.
//
// `compareFileTree` takes one of these rather than calling listRepoFiles itself, for the same reason
// it takes cwd and platform rather than reading the process: the flow can then be driven against a
// directory whose contents the caller chose. listRepoFiles below is the one the CLI supplies, and it
// is the only implementation that ships.
//
pub const FileLister = *const fn (io: std.Io, environ: *const std.process.Environ.Map, allocator: std.mem.Allocator, root_dir: []const u8, fail: *Failure) failure.Error![][]const u8;

//
// Lists every file in the working tree that git would consider part of the project: tracked files
// plus untracked files that no ignore rule matches. Going through git is what gives the tool exact
// .gitignore semantics without hand-writing an ignore matcher, at the cost of requiring the project
// to be a git repository.
//
pub fn listRepoFiles(io: std.Io, environ: *const std.process.Environ.Map, allocator: std.mem.Allocator, root_dir: []const u8, fail: *Failure) failure.Error![][]const u8 {
    return parseGitFileList(allocator, try runGitLsFiles(io, environ, allocator, root_dir, fail));
}

//
// True when a path's extension is one the config says to leave out. Compared case-insensitively, so
// a README.MD is treated the same as a readme.md.
//
pub fn isIgnoredFile(relative_path: []const u8, ignore: []const []const u8) bool {
    for (ignore) |extension| {
        if (relative_path.len < extension.len) continue;
        const tail = relative_path[relative_path.len - extension.len ..];
        if (std.ascii.eqlIgnoreCase(tail, extension)) {
            return true;
        }
    }
    return false;
}

//
// Removes every file whose extension the config says to leave out. Applied to the file list before
// anything is hashed, so an ignored file is invisible to the hash tree, to every target's decision,
// and to the changed-file listing alike.
//
pub fn filterIgnoredFiles(allocator: std.mem.Allocator, relative_paths: []const []const u8, ignore: []const []const u8) std.mem.Allocator.Error![][]const u8 {
    if (ignore.len == 0) {
        return allocator.dupe([]const u8, relative_paths);
    }

    var kept: std.ArrayList([]const u8) = .empty;
    for (relative_paths) |relative_path| {
        if (!isIgnoredFile(relative_path, ignore)) {
            try kept.append(allocator, relative_path);
        }
    }
    return kept.toOwnedSlice(allocator);
}

//
// Splits the NUL-separated output of `git ls-files -z` into a sorted, de-duplicated path list.
//
// Kept apart from the process spawn so the parsing can be tested directly against canned byte
// streams, including paths that are awkward or impossible to create on every filesystem, without
// spawning a real git process.
//
pub fn parseGitFileList(allocator: std.mem.Allocator, stdout: []const u8) std.mem.Allocator.Error![][]const u8 {
    var unique: std.StringArrayHashMapUnmanaged(void) = .empty;

    var entries = std.mem.splitScalar(u8, stdout, 0);
    while (entries.next()) |entry| {
        if (entry.len > 0) {
            try unique.put(allocator, entry, {});
        }
    }

    const paths = try allocator.dupe([]const u8, unique.keys());
    std.mem.sort([]const u8, paths, {}, file_hashes.lessThanPath);
    return paths;
}

//
// Runs `git ls-files` in the given directory and hands back its raw NUL-separated output.
//
// Kept apart from listRepoFiles so the spawn (its output, a non-zero exit, and a missing git binary)
// can be exercised on its own.
//
// The environment is a parameter rather than inherited from the process. `GIT_DIR`, `GIT_WORK_TREE`
// and `GIT_CONFIG_GLOBAL` all change which files git reports, so a run whose environment came from
// nowhere in particular can report on a different tree than the one it was pointed at, with nothing
// in the signature saying it could. `std.process.run` inherits the parent's environment when this is
// left unset, which is the behaviour being removed.
//
pub fn runGitLsFiles(io: std.Io, environ: *const std.process.Environ.Map, allocator: std.mem.Allocator, root_dir: []const u8, fail: *Failure) failure.Error![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
        .cwd = .{ .path = root_dir },
        .environ_map = environ,
    }) catch |err| {
        //
        // git could not be started at all, which usually means it is not installed. Named as such
        // rather than reported as an exit code, because there was no exit.
        //
        return fail.set("git ls-files failed in \"{s}\": {s}", .{ root_dir, @errorName(err) });
    };

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                return fail.set("git ls-files failed in \"{s}\" with exit code {d}: {s}", .{
                    root_dir, code, std.mem.trim(u8, result.stderr, " \t\r\n"),
                });
            }
        },
        else => return fail.set("git ls-files failed in \"{s}\": it was killed before it finished", .{root_dir}),
    }

    return result.stdout;
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("list_files.test.zig");
}
