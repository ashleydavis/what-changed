const std = @import("std");

//
// The filesystem operations the rest of the tool is built out of.
//
// Zig 0.16 made every filesystem call take an `Io`: the interface that decides how blocking work is
// actually performed. That is the right design for a program that wants to choose, but this one does
// not. It is a short-lived command line tool that reads some files, hashes them, and exits, and
// there is exactly one sensible answer for how to do that.
//
// So the `Io` lives here, created once on first use, and the functions below keep the plain
// signatures the rest of the project already calls. The alternative was threading an `Io` parameter
// through roughly two hundred call sites to reach the same result. A caller that wants a different
// one can install it with `setIo` before anything else runs.
//

//
// The I/O implementation everything here goes through.
//
var installed_io: ?std.Io = null;

//
// Backs the default implementation. A pointer to this is handed out inside `std.Io`, so it has to
// outlive every call, which is why it is here rather than on a stack somewhere.
//
var default_threaded: std.Io.Threaded = undefined;
var default_ready = false;

//
// The `Io` every operation in this file uses, creating the default one the first time it is asked
// for.
//
pub fn io() std.Io {
    if (installed_io) |existing| return existing;

    if (!default_ready) {
        default_threaded = .init(std.heap.page_allocator, .{});
        default_ready = true;
    }
    installed_io = default_threaded.io();
    return installed_io.?;
}

//
// Installs the `Io` to use, for a caller that already has one.
//
// The CLI does this with the one the runtime handed it, so the whole process shares a single
// implementation rather than standing a second one up behind its back.
//
pub fn setIo(chosen: std.Io) void {
    installed_io = chosen;
}

//
// Path handling. Separate from the I/O above because none of it touches a disk: it is string
// manipulation, and it is the same in every Zig version.
//
const path_util = std.Io.Dir.path;

//
// The largest config, baseline or cache file that will be read.
//
// Generous: the biggest of these in practice is the file hash cache, at roughly 150 bytes per file,
// so this clears a repository of a million files. A ceiling is needed at all because reading an
// unbounded amount into memory on the word of a filename is how a corrupted path takes a process
// down.
//
pub const MAX_FILE_BYTES = 256 * 1024 * 1024;

//
// Reads a whole file into memory.
//
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, .limited(MAX_FILE_BYTES));
}

//
// True when a file can be opened for reading.
//
// Used to pick a config file out of the candidate names. Opening rather than stat-ing matches what
// the tool has always done, so a path that exists but cannot be read is skipped rather than chosen
// and then refused.
//
pub fn fileExists(path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io(), path, .{}) catch return false;
    file.close(io());
    return true;
}

//
// Describes a filesystem error in the words a person expects to see, so a build log reads the same
// whichever tool produced it.
//
pub fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "illegal operation on a directory",
        error.NotDir => "not a directory",
        error.NameTooLong => "file name too long",
        error.SymLinkLoop => "too many symbolic links encountered",
        error.FileTooBig, error.StreamTooLong => "file too large",
        error.NoSpaceLeft => "no space left on device",
        error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "too many open files",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

//
// The errno name that goes in front of a filesystem error, such as "ENOENT".
//
// These strings end up in build logs that people search, so they are worth getting right rather
// than inventing.
//
pub fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "ENOENT",
        error.AccessDenied, error.PermissionDenied => "EACCES",
        error.IsDir => "EISDIR",
        error.NotDir => "ENOTDIR",
        error.NameTooLong => "ENAMETOOLONG",
        error.SymLinkLoop => "ELOOP",
        error.FileTooBig, error.StreamTooLong => "EFBIG",
        error.NoSpaceLeft => "ENOSPC",
        error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "EMFILE",
        else => @errorName(err),
    };
}

//
// Describes a failed operation on a path, the whole message.
//
pub fn describeOperation(allocator: std.mem.Allocator, err: anyerror, operation: []const u8, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}: {s}, {s} '{s}'", .{ errorCode(err), describeError(err), operation, path });
}

//
// True when a path is absolute.
//
// Both the platform's own rule and a leading slash count. On Windows the platform rule alone would
// let "/etc/passwd" through as relative, and a config is not allowed to name a path outside the
// project whichever machine reads it.
//
pub fn isAbsolutePath(path: []const u8) bool {
    return path_util.isAbsolute(path) or (path.len > 0 and path[0] == '/');
}

//
// Resolves a path against a base directory: an absolute path is returned as it is, and a relative
// one is taken from the base.
//
pub fn resolvePath(allocator: std.mem.Allocator, base: []const u8, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return path_util.resolve(allocator, &.{ base, path });
}

//
// The directory a path is in, or "." when it names something in the working directory.
//
pub fn dirName(path: []const u8) []const u8 {
    return path_util.dirname(path) orelse ".";
}

//
// Joins path segments.
//
pub fn joinPath(allocator: std.mem.Allocator, segments: []const []const u8) std.mem.Allocator.Error![]const u8 {
    return path_util.join(allocator, segments);
}

//
// The extension of a path, including its dot.
//
pub fn extension(path: []const u8) []const u8 {
    return path_util.extension(path);
}

//
// Creates a directory and every directory above it, doing nothing when it is already there.
//
pub fn makeDirPath(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io(), path);
}

//
// Creates the directory a file is going to be written into.
//
pub fn makeParentDir(path: []const u8) !void {
    try makeDirPath(dirName(path));
}

//
// Writes a whole file, replacing whatever was there.
//
pub fn writeFile(path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = contents });
}

//
// Moves a file, replacing the destination.
//
pub fn renameFile(from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(from, cwd, to, io());
}

//
// Removes a file, and does not mind if it was not there.
//
pub fn removeFile(path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io(), path) catch {};
}

//
// Creates a file only if nothing is there already, which is how the update lock is taken.
//
// Returns `error.PathAlreadyExists` when someone else holds it. The filesystem lets exactly one
// caller win, which is what makes the lock safe across processes.
//
pub fn createFileExclusive(path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io(), path, .{ .exclusive = true });
    file.close(io());
}

//
// What the filesystem knows about a file, in the terms this tool uses.
//
pub const FileStat = struct {
    //
    // The file's modification time in milliseconds.
    //
    // Held as a float because the underlying value has nanosecond resolution, and rounding to whole
    // milliseconds would make two writes within the same millisecond look like no write at all.
    //
    mtime_ms: f64,

    //
    // The file's size in bytes.
    //
    size: u64,
};

//
// Reads a file's modification time and size without opening it.
//
pub fn statFile(path: []const u8) !FileStat {
    const stat = try std.Io.Dir.cwd().statFile(io(), path, .{});
    return .{
        .mtime_ms = @as(f64, @floatFromInt(stat.mtime.nanoseconds)) / std.time.ns_per_ms,
        .size = stat.size,
    };
}

//
// Opens a file for reading. The caller closes it with `closeFile`.
//
pub fn openFile(path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io(), path, .{});
}

//
// Closes a file opened with `openFile`.
//
pub fn closeFile(file: std.Io.File) void {
    file.close(io());
}

//
// A reader over an open file, filling the given buffer.
//
pub fn fileReader(file: std.Io.File, buffer: []u8) std.Io.File.Reader {
    return file.reader(io(), buffer);
}

//
// Milliseconds since the epoch, from the wall clock.
//
// Used to decide whether a lock file is old enough to have been abandoned. In 0.16 the clock, like
// everything else that talks to the outside, is reached through the `Io`.
//
pub fn nowMs() f64 {
    const stamp = std.Io.Clock.Timestamp.now(io(), .real);
    return @as(f64, @floatFromInt(stamp.raw.nanoseconds)) / std.time.ns_per_ms;
}

//
// Waits for the given number of milliseconds.
//
pub fn sleepMs(milliseconds: u64) void {
    io().sleep(.fromNanoseconds(@intCast(milliseconds * std.time.ns_per_ms)), .real) catch {};
}

//
// A throwaway directory, for tests that need real files.
//
// Every test that touches disk gets its own, so tests never see each other's files and can run in
// any order. The name carries random bytes rather than a counter for the same reason the cache's
// temporary files do: several test binaries run at once and a shared name is a collision waiting to
// happen.
//
pub const TemporaryDir = struct {
    //
    // Where the directory is, as an absolute path.
    //
    // Allocated rather than held in a buffer inside this struct. A slice pointing into the struct's
    // own storage would dangle the moment the struct was copied, which is exactly what happens when
    // `create` returns one.
    //
    path: []const u8,

    //
    // Where the path is allocated from. The page allocator rather than a caller's, so a test needs
    // no allocator to make a directory, and nothing here can be mistaken for a leak in the code
    // under test.
    //
    const path_allocator = std.heap.page_allocator;

    //
    // Makes a fresh empty directory under the system temporary directory.
    //
    pub fn create() !TemporaryDir {
        var random_bytes: [12]u8 = undefined;
        io().random(&random_bytes);
        const suffix = std.fmt.bytesToHex(random_bytes, .lower);

        const path = try std.fmt.allocPrint(path_allocator, "/tmp/what-changed-test-{s}", .{suffix});
        errdefer path_allocator.free(path);

        try makeDirPath(path);
        return .{ .path = path };
    }

    //
    // Removes the directory and everything in it.
    //
    pub fn destroy(self: *TemporaryDir) void {
        std.Io.Dir.cwd().deleteTree(io(), self.path) catch {};
        path_allocator.free(self.path);
        self.path = &.{};
    }

    //
    // The absolute path of something inside the directory.
    //
    pub fn join(self: *const TemporaryDir, allocator: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
        return joinPath(allocator, &.{ self.path, sub_path });
    }

    //
    // Writes a file inside the directory, creating any directories it needs.
    //
    pub fn write(self: *const TemporaryDir, sub_path: []const u8, contents: []const u8) !void {
        var buffer: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.path, sub_path });
        try makeParentDir(full_path);
        try writeFile(full_path, contents);
    }

    //
    // Reads a file from inside the directory.
    //
    pub fn read(self: *const TemporaryDir, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        var buffer: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.path, sub_path });
        return readFile(allocator, full_path);
    }

    //
    // True when something inside the directory exists.
    //
    pub fn has(self: *const TemporaryDir, sub_path: []const u8) bool {
        var buffer: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.path, sub_path }) catch return false;
        return fileExists(full_path);
    }
};

const testing = std.testing;

test "isAbsolutePath spots both platform-absolute paths and leading slashes" {
    try testing.expect(isAbsolutePath("/etc/passwd"));
    try testing.expect(isAbsolutePath("/"));
    try testing.expect(!isAbsolutePath("src"));
    try testing.expect(!isAbsolutePath("src/a.ts"));
    try testing.expect(!isAbsolutePath("./src"));
    try testing.expect(!isAbsolutePath(""));
}

test "resolvePath resolves relative paths against the base and leaves absolute ones alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings("/work/src", try resolvePath(allocator, "/work", "src"));
    try testing.expectEqualStrings("/other", try resolvePath(allocator, "/work", "/other"));
    try testing.expectEqualStrings("/work", try resolvePath(allocator, "/work", "."));
    try testing.expectEqualStrings("/work/b", try resolvePath(allocator, "/work", "a/../b"));
}

test "dirName gives the directory a path is in" {
    try testing.expectEqualStrings("/work", dirName("/work/what-changed.yaml"));
    try testing.expectEqualStrings("/work/nested", dirName("/work/nested/what-changed.yaml"));
    try testing.expectEqualStrings(".", dirName("what-changed.yaml"));
}

test "joinPath and extension work on the pieces of a path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings("a/b/c.txt", try joinPath(arena.allocator(), &.{ "a", "b", "c.txt" }));
    try testing.expectEqualStrings(".yaml", extension("what-changed.yaml"));
    try testing.expectEqualStrings("", extension("what-changed"));
}

test "describeError words the common failures the way a person expects" {
    try testing.expectEqualStrings("no such file or directory", describeError(error.FileNotFound));
    try testing.expectEqualStrings("permission denied", describeError(error.AccessDenied));
    try testing.expectEqualStrings("illegal operation on a directory", describeError(error.IsDir));
    try testing.expectEqualStrings("Unexpected", describeError(error.Unexpected));
}

test "errorCode names the errno" {
    try testing.expectEqualStrings("ENOENT", errorCode(error.FileNotFound));
    try testing.expectEqualStrings("EACCES", errorCode(error.AccessDenied));
    try testing.expectEqualStrings("EISDIR", errorCode(error.IsDir));
    try testing.expectEqualStrings("ENOSPC", errorCode(error.NoSpaceLeft));
}

test "describeOperation reads as one whole message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqualStrings(
        "ENOENT: no such file or directory, open '/work/missing.yaml'",
        try describeOperation(arena.allocator(), error.FileNotFound, "open", "/work/missing.yaml"),
    );
}

test "io hands back the same implementation every time" {
    const first = io();
    const second = io();
    try testing.expectEqual(first.userdata, second.userdata);
}

test "readFile and writeFile round trip a file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try TemporaryDir.create();
    defer temporary.destroy();

    const path = try temporary.join(allocator, "nested/file.txt");
    try makeParentDir(path);
    try writeFile(path, "contents");
    try testing.expectEqualStrings("contents", try readFile(allocator, path));
}

test "fileExists answers for a file that is there and one that is not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try TemporaryDir.create();
    defer temporary.destroy();

    try temporary.write("here.txt", "x");
    try testing.expect(fileExists(try temporary.join(allocator, "here.txt")));
    try testing.expect(!fileExists(try temporary.join(allocator, "gone.txt")));
}

test "readFile reports a missing file rather than returning nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try TemporaryDir.create();
    defer temporary.destroy();

    try testing.expectError(error.FileNotFound, readFile(allocator, try temporary.join(allocator, "gone.txt")));
}

test "makeDirPath creates every directory in the path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try TemporaryDir.create();
    defer temporary.destroy();

    const deep = try temporary.join(allocator, "a/b/c");
    try makeDirPath(deep);
    try makeDirPath(deep); // Doing it twice is not an error.

    try writeFile(try temporary.join(allocator, "a/b/c/file.txt"), "x");
    try testing.expect(temporary.has("a/b/c/file.txt"));
}

test "renameFile moves a file over whatever was there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try TemporaryDir.create();
    defer temporary.destroy();

    try temporary.write("from.txt", "new");
    try temporary.write("to.txt", "old");
    try renameFile(try temporary.join(allocator, "from.txt"), try temporary.join(allocator, "to.txt"));

    try testing.expectEqualStrings("new", try temporary.read(allocator, "to.txt"));
    try testing.expect(!temporary.has("from.txt"));
}

test "removeFile deletes a file and does not mind a missing one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try TemporaryDir.create();
    defer temporary.destroy();

    try temporary.write("gone.txt", "x");
    removeFile(try temporary.join(allocator, "gone.txt"));
    try testing.expect(!temporary.has("gone.txt"));

    removeFile(try temporary.join(allocator, "never-existed.txt"));
}

test "createFileExclusive lets exactly one caller win" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try TemporaryDir.create();
    defer temporary.destroy();
    const lock_path = try temporary.join(allocator, "thing.lock");

    try createFileExclusive(lock_path);

    //
    // The second caller is refused. This is what makes the update lock safe across processes: the
    // filesystem, not this code, decides who gets it.
    //
    try testing.expectError(error.PathAlreadyExists, createFileExclusive(lock_path));

    removeFile(lock_path);
    try createFileExclusive(lock_path);
}

test "statFile reads the size and a plausible modification time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try TemporaryDir.create();
    defer temporary.destroy();

    try temporary.write("sized.txt", "12345");
    const stat = try statFile(try temporary.join(allocator, "sized.txt"));

    try testing.expectEqual(@as(u64, 5), stat.size);
    //
    // Only that it is a real wall-clock time in milliseconds, not what it is: the file was written
    // by this test, so anything from the last day is right and a fixed value would be wrong.
    //
    try testing.expect(stat.mtime_ms > 1_600_000_000_000.0);
}

test "openFile and fileReader stream a file's bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var temporary = try TemporaryDir.create();
    defer temporary.destroy();
    try temporary.write("streamed.txt", "abcdefghij");

    const file = try openFile(try temporary.join(allocator, "streamed.txt"));
    defer closeFile(file);

    var reader_buffer: [4]u8 = undefined;
    var chunk: [4]u8 = undefined;
    var reader = fileReader(file, &reader_buffer);

    var seen: usize = 0;
    while (true) {
        const read_bytes = reader.interface.readSliceShort(&chunk) catch break;
        if (read_bytes == 0) break;
        seen += read_bytes;
    }
    try testing.expectEqual(@as(usize, 10), seen);
}

test "TemporaryDir gives each caller its own directory" {
    var first = try TemporaryDir.create();
    defer first.destroy();
    var second = try TemporaryDir.create();
    defer second.destroy();

    try testing.expect(!std.mem.eql(u8, first.path, second.path));

    try first.write("only-here.txt", "x");
    try testing.expect(first.has("only-here.txt"));
    try testing.expect(!second.has("only-here.txt"));
}
