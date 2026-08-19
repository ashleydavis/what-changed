const std = @import("std");
const failure = @import("failure.zig");
const files = @import("files.zig");
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

const testing = std.testing;

test "isIgnoredFile matches on the extension" {
    try testing.expect(isIgnoredFile("README.md", &.{".md"}));
    try testing.expect(isIgnoredFile("docs/guide.txt", &.{ ".md", ".txt" }));
    try testing.expect(!isIgnoredFile("src/a.ts", &.{ ".md", ".txt" }));
    try testing.expect(!isIgnoredFile("src/a.ts", &.{}));
}

test "isIgnoredFile ignores case" {
    try testing.expect(isIgnoredFile("README.MD", &.{".md"}));
    try testing.expect(isIgnoredFile("readme.md", &.{".MD"}));
}

test "isIgnoredFile matches any suffix, not only a file extension" {
    //
    // The rule is "ends with", not "matches the last dot", so a compound suffix works.
    //
    try testing.expect(isIgnoredFile("src/a.test.ts", &.{".test.ts"}));
    try testing.expect(!isIgnoredFile("src/a.ts", &.{".test.ts"}));
}

test "isIgnoredFile does not match a suffix longer than the path" {
    try testing.expect(!isIgnoredFile("a.ts", &.{".very.long.extension"}));
    try testing.expect(!isIgnoredFile("", &.{".md"}));
}

test "filterIgnoredFiles removes the ignored files and keeps the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const kept = try filterIgnoredFiles(allocator, &.{ "src/a.ts", "README.md", "docs/g.txt", "src/b.ts" }, &.{ ".md", ".txt" });
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("src/a.ts", kept[0]);
    try testing.expectEqualStrings("src/b.ts", kept[1]);
}

test "filterIgnoredFiles with nothing to ignore keeps everything, in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const kept = try filterIgnoredFiles(allocator, &.{ "b.ts", "a.ts" }, &.{});
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("b.ts", kept[0]);
    try testing.expectEqualStrings("a.ts", kept[1]);
}

test "filterIgnoredFiles can remove everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try filterIgnoredFiles(allocator, &.{ "a.md", "b.md" }, &.{".md"})).len);
}

test "parseGitFileList splits on NUL and sorts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const paths = try parseGitFileList(allocator, "src/z.ts\x00package.json\x00src/a.ts\x00");
    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expectEqualStrings("package.json", paths[0]);
    try testing.expectEqualStrings("src/a.ts", paths[1]);
    try testing.expectEqualStrings("src/z.ts", paths[2]);
}

test "parseGitFileList drops duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // git lists a path twice when it is both tracked and reported by another of the flags asked for.
    // The tool must hash it once, not twice.
    //
    const paths = try parseGitFileList(allocator, "a.ts\x00a.ts\x00b.ts\x00");
    try testing.expectEqual(@as(usize, 2), paths.len);
}

test "parseGitFileList ignores empty entries and a missing final separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try parseGitFileList(allocator, "")).len);
    try testing.expectEqual(@as(usize, 0), (try parseGitFileList(allocator, "\x00\x00")).len);
    try testing.expectEqual(@as(usize, 1), (try parseGitFileList(allocator, "only.ts")).len);
}

test "parseGitFileList keeps a path holding a space or a newline whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // The reason the tool asks git for NUL-separated output at all. A newline in a filename is legal
    // on every filesystem this runs on, and line-separated output would split such a path in two.
    //
    const paths = try parseGitFileList(allocator, "a file.ts\x00odd\nname.ts\x00");
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings("a file.ts", paths[0]);
    try testing.expectEqualStrings("odd\nname.ts", paths[1]);
}

test "runGitLsFiles fails and names git when the directory is not a repository" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();

    var fail = Failure.init(allocator);
    try testing.expectError(error.Failed, runGitLsFiles(io, &environment, allocator, temporary.path, &fail));
    try testing.expect(std.mem.startsWith(u8, fail.text(), "git ls-files failed in \""));
    try testing.expect(std.mem.indexOf(u8, fail.text(), temporary.path) != null);
}

test "listRepoFiles lists what git reports in a real repository" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    //
    // GIT_DIR and GIT_WORK_TREE are both set, so git uses exactly this directory and does not search
    // upwards for an enclosing repository. Without them a test run from inside a checkout would
    // initialise, or worse touch, the real one.
    //
    // The same map is handed to listRepoFiles below, which is what the environment being a parameter
    // buys: the listing is pinned to this repository rather than to whatever the test runner was
    // started with.
    //
    var environment = std.process.Environ.Map.init(allocator);
    defer environment.deinit();
    const git_dir = try temporary.join(allocator, ".git");
    try environment.put("GIT_DIR", git_dir);
    try environment.put("GIT_WORK_TREE", temporary.path);

    const init_result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "init", "--quiet" },
        .cwd = .{ .path = temporary.path },
        .environ_map = &environment,
    }) catch return error.SkipZigTest;
    switch (init_result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    try temporary.write("src/a.ts", "x");
    try temporary.write("README.md", "x");
    try temporary.write(".gitignore", "ignored/\n");
    try temporary.write("ignored/hidden.ts", "x");

    var fail = Failure.init(allocator);
    const listed = listRepoFiles(io, &environment, allocator, temporary.path, &fail) catch |err| {
        std.debug.print("listRepoFiles failed: {s}\n", .{fail.text()});
        return err;
    };

    //
    // Untracked files are listed, because the tool asks for --others: a repository with no commits
    // still gives it everything. What .gitignore excludes is not listed, which is the whole reason
    // the listing goes through git.
    //
    try testing.expectEqual(@as(usize, 3), listed.len);
    try testing.expectEqualStrings(".gitignore", listed[0]);
    try testing.expectEqualStrings("README.md", listed[1]);
    try testing.expectEqualStrings("src/a.ts", listed[2]);
}
