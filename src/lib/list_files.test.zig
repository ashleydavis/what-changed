const std = @import("std");
const files = @import("files.zig");
const list_files = @import("list_files.zig");
const failure = @import("failure.zig");
const Failure = failure.Failure;
const testing = std.testing;

test "isIgnoredFile matches on the extension" {
    try testing.expect(list_files.isIgnoredFile("README.md", &.{".md"}));
    try testing.expect(list_files.isIgnoredFile("docs/guide.txt", &.{ ".md", ".txt" }));
    try testing.expect(!list_files.isIgnoredFile("src/a.ts", &.{ ".md", ".txt" }));
    try testing.expect(!list_files.isIgnoredFile("src/a.ts", &.{}));
}

test "isIgnoredFile ignores case" {
    try testing.expect(list_files.isIgnoredFile("README.MD", &.{".md"}));
    try testing.expect(list_files.isIgnoredFile("readme.md", &.{".MD"}));
}

test "isIgnoredFile matches any suffix, not only a file extension" {
    //
    // The rule is "ends with", not "matches the last dot", so a compound suffix works.
    //
    try testing.expect(list_files.isIgnoredFile("src/a.test.ts", &.{".test.ts"}));
    try testing.expect(!list_files.isIgnoredFile("src/a.ts", &.{".test.ts"}));
}

test "isIgnoredFile does not match a suffix longer than the path" {
    try testing.expect(!list_files.isIgnoredFile("a.ts", &.{".very.long.extension"}));
    try testing.expect(!list_files.isIgnoredFile("", &.{".md"}));
}

test "filterIgnoredFiles removes the ignored files and keeps the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const kept = try list_files.filterIgnoredFiles(allocator, &.{ "src/a.ts", "README.md", "docs/g.txt", "src/b.ts" }, &.{ ".md", ".txt" });
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("src/a.ts", kept[0]);
    try testing.expectEqualStrings("src/b.ts", kept[1]);
}

test "filterIgnoredFiles with nothing to ignore keeps everything, in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const kept = try list_files.filterIgnoredFiles(allocator, &.{ "b.ts", "a.ts" }, &.{});
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("b.ts", kept[0]);
    try testing.expectEqualStrings("a.ts", kept[1]);
}

test "filterIgnoredFiles can remove everything" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try list_files.filterIgnoredFiles(allocator, &.{ "a.md", "b.md" }, &.{".md"})).len);
}

test "parseGitFileList splits on NUL and sorts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const paths = try list_files.parseGitFileList(allocator, "src/z.ts\x00package.json\x00src/a.ts\x00");
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
    const paths = try list_files.parseGitFileList(allocator, "a.ts\x00a.ts\x00b.ts\x00");
    try testing.expectEqual(@as(usize, 2), paths.len);
}

test "parseGitFileList ignores empty entries and a missing final separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqual(@as(usize, 0), (try list_files.parseGitFileList(allocator, "")).len);
    try testing.expectEqual(@as(usize, 0), (try list_files.parseGitFileList(allocator, "\x00\x00")).len);
    try testing.expectEqual(@as(usize, 1), (try list_files.parseGitFileList(allocator, "only.ts")).len);
}

test "parseGitFileList keeps a path holding a space or a newline whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //
    // The reason the tool asks git for NUL-separated output at all. A newline in a filename is legal
    // on every filesystem this runs on, and line-separated output would split such a path in two.
    //
    const paths = try list_files.parseGitFileList(allocator, "a file.ts\x00odd\nname.ts\x00");
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
    try testing.expectError(error.Failed, list_files.runGitLsFiles(io, &environment, allocator, temporary.path, &fail));
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
    const listed = list_files.listRepoFiles(io, &environment, allocator, temporary.path, &fail) catch |err| {
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
