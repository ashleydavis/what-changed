const std = @import("std");
const files = @import("files.zig");
const testing = std.testing;

test "isAbsolutePath spots both platform-absolute paths and leading slashes" {
    try testing.expect(files.isAbsolutePath("/etc/passwd"));
    try testing.expect(files.isAbsolutePath("/"));
    try testing.expect(!files.isAbsolutePath("src"));
    try testing.expect(!files.isAbsolutePath("src/a.ts"));
    try testing.expect(!files.isAbsolutePath("./src"));
    try testing.expect(!files.isAbsolutePath(""));
}

test "resolvePath resolves relative paths against the base and leaves absolute ones alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings("/work/src", try files.resolvePath(allocator, "/work", "src"));
    try testing.expectEqualStrings("/other", try files.resolvePath(allocator, "/work", "/other"));
    try testing.expectEqualStrings("/work", try files.resolvePath(allocator, "/work", "."));
    try testing.expectEqualStrings("/work/b", try files.resolvePath(allocator, "/work", "a/../b"));
}

test "dirName gives the directory a path is in" {
    try testing.expectEqualStrings("/work", files.dirName("/work/what-changed.yaml"));
    try testing.expectEqualStrings("/work/nested", files.dirName("/work/nested/what-changed.yaml"));
    try testing.expectEqualStrings(".", files.dirName("what-changed.yaml"));
}

test "joinPath and extension work on the pieces of a path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("a/b/c.txt", try files.joinPath(arena.allocator(), &.{ "a", "b", "c.txt" }));
    try testing.expectEqualStrings(".yaml", files.extension("what-changed.yaml"));
    try testing.expectEqualStrings("", files.extension("what-changed"));
}

test "describeError words the common failures the way a person expects" {
    try testing.expectEqualStrings("no such file or directory", files.describeError(error.FileNotFound));
    try testing.expectEqualStrings("permission denied", files.describeError(error.AccessDenied));
    try testing.expectEqualStrings("illegal operation on a directory", files.describeError(error.IsDir));
    try testing.expectEqualStrings("Unexpected", files.describeError(error.Unexpected));
}

test "errorCode names the errno" {
    try testing.expectEqualStrings("ENOENT", files.errorCode(error.FileNotFound));
    try testing.expectEqualStrings("EACCES", files.errorCode(error.AccessDenied));
    try testing.expectEqualStrings("EISDIR", files.errorCode(error.IsDir));
    try testing.expectEqualStrings("ENOSPC", files.errorCode(error.NoSpaceLeft));
}

test "describeOperation reads as one whole message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "ENOENT: no such file or directory, open '/work/missing.yaml'",
        try files.describeOperation(arena.allocator(), error.FileNotFound, "open", "/work/missing.yaml"),
    );
}

test "each TestIo is its own implementation" {
    //
    // The point of a test making its own: two of them are two separate implementations, so nothing
    // one test does to its `Io` can be seen by another.
    //
    var first = files.TestIo.init();
    defer first.deinit();
    var second = files.TestIo.init();
    defer second.deinit();

    try testing.expect(first.io().userdata != second.io().userdata);
}

test "readFile and writeFile round trip a file" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    const path = try temporary.join(allocator, "nested/file.txt");
    try files.makeParentDir(io, path);
    try files.writeFile(io, path, "contents");
    try testing.expectEqualStrings("contents", try files.readFile(io, allocator, path));
}

test "fileExists answers for a file that is there and one that is not" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    try temporary.write("here.txt", "x");
    try testing.expect(files.fileExists(io, try temporary.join(allocator, "here.txt")));
    try testing.expect(!files.fileExists(io, try temporary.join(allocator, "gone.txt")));
}

test "readFile reports a missing file rather than returning nothing" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    try testing.expectError(error.FileNotFound, files.readFile(io, allocator, try temporary.join(allocator, "gone.txt")));
}

test "makeDirPath creates every directory in the path" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    const deep = try temporary.join(allocator, "a/b/c");
    try files.makeDirPath(io, deep);
    try files.makeDirPath(io, deep); // Doing it twice is not an error.

    try files.writeFile(io, try temporary.join(allocator, "a/b/c/file.txt"), "x");
    try testing.expect(temporary.has("a/b/c/file.txt"));
}

test "renameFile moves a file over whatever was there" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    try temporary.write("from.txt", "new");
    try temporary.write("to.txt", "old");
    try files.renameFile(io, try temporary.join(allocator, "from.txt"), try temporary.join(allocator, "to.txt"));

    try testing.expectEqualStrings("new", try temporary.read(allocator, "to.txt"));
    try testing.expect(!temporary.has("from.txt"));
}

test "removeFile deletes a file and does not mind a missing one" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    try temporary.write("gone.txt", "x");
    files.removeFile(io, try temporary.join(allocator, "gone.txt"));
    try testing.expect(!temporary.has("gone.txt"));

    files.removeFile(io, try temporary.join(allocator, "never-existed.txt"));
}

test "createFileExclusive lets exactly one caller win" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    const lock_path = try temporary.join(allocator, "thing.lock");

    try files.createFileExclusive(io, lock_path);

    //
    // The second caller is refused. This is what makes the update lock safe across processes: the
    // filesystem, not this code, decides who gets it.
    //
    try testing.expectError(error.PathAlreadyExists, files.createFileExclusive(io, lock_path));

    files.removeFile(io, lock_path);
    try files.createFileExclusive(io, lock_path);
}

test "statFile reads the size and a plausible modification time" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();

    try temporary.write("sized.txt", "12345");
    const stat = try files.statFile(io, try temporary.join(allocator, "sized.txt"));

    try testing.expectEqual(@as(u64, 5), stat.size);
    //
    // Only that it is a real wall-clock time in milliseconds, not what it is: the file was written
    // by this test, so anything from the last day is right and a fixed value would be wrong.
    //
    try testing.expect(stat.mtime_ms > 1_600_000_000_000.0);
}

test "openFile and fileReader stream a file's bytes" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try files.TemporaryDir.create(io);
    defer temporary.destroy();
    try temporary.write("streamed.txt", "abcdefghij");

    const file = try files.openFile(io, try temporary.join(allocator, "streamed.txt"));
    defer files.closeFile(io, file);

    var reader_buffer: [4]u8 = undefined;
    var chunk: [4]u8 = undefined;
    var reader = files.fileReader(io, file, &reader_buffer);

    var seen: usize = 0;
    while (true) {
        const read_bytes = reader.interface.readSliceShort(&chunk) catch break;
        if (read_bytes == 0) break;
        seen += read_bytes;
    }
    try testing.expectEqual(@as(usize, 10), seen);
}

test "nowMs reads a real wall-clock time" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();

    try testing.expect(files.nowMs(test_io.io()) > 1_600_000_000_000.0);
}

test "TemporaryDir gives each caller its own directory" {
    var test_io = files.TestIo.init();
    defer test_io.deinit();
    const io = test_io.io();

    var first = try files.TemporaryDir.create(io);
    defer first.destroy();
    var second = try files.TemporaryDir.create(io);
    defer second.destroy();

    try testing.expect(!std.mem.eql(u8, first.path, second.path));

    try first.write("only-here.txt", "x");
    try testing.expect(first.has("only-here.txt"));
    try testing.expect(!second.has("only-here.txt"));
}
