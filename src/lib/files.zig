const std = @import("std");

//
// The filesystem operations the rest of the tool is built out of.
//
// Zig 0.16 made every filesystem call take an `Io`: the interface that decides how blocking work is
// actually performed. Every function here that touches a disk or a clock takes one and passes it on,
// so there is no hidden answer to "which implementation is this using". The CLI creates exactly one,
// in main, from what the runtime handed the process, and it reaches everything else by being passed.
//
// A test creates its own with `TestIo`, which is what lets two tests run against different `Io`
// instances without either being able to affect the other.
//

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
pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(MAX_FILE_BYTES));
}

//
// True when a file can be opened for reading.
//
// Used to pick a config file out of the candidate names. Opening rather than stat-ing matches what
// the tool has always done, so a path that exists but cannot be read is skipped rather than chosen
// and then refused.
//
pub fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
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
pub fn makeDirPath(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

//
// Creates the directory a file is going to be written into.
//
pub fn makeParentDir(io: std.Io, path: []const u8) !void {
    try makeDirPath(io, dirName(path));
}

//
// Writes a whole file, replacing whatever was there.
//
pub fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
}

//
// Moves a file, replacing the destination.
//
pub fn renameFile(io: std.Io, from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(from, cwd, to, io);
}

//
// Removes a file, saying so when it could not.
//
// A caller that means "delete this if it is there" writes `catch {}` on the call. That used to be
// built in, which suited the tidy-up callers and hid the one failure that costs something: an update
// lock that will not delete blocks every later writer until the abandonment timeout runs out.
//
pub fn removeFile(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().deleteFile(io, path);
}

//
// Creates a file only if nothing is there already, which is how the update lock is taken.
//
// Returns `error.PathAlreadyExists` when someone else holds it. The filesystem lets exactly one
// caller win, which is what makes the lock safe across processes.
//
pub fn createFileExclusive(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    file.close(io);
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
pub fn statFile(io: std.Io, path: []const u8) !FileStat {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    return .{
        .mtime_ms = @as(f64, @floatFromInt(stat.mtime.nanoseconds)) / std.time.ns_per_ms,
        .size = stat.size,
    };
}

//
// Opens a file for reading. The caller closes it with `closeFile`.
//
pub fn openFile(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

//
// Closes a file opened with `openFile`.
//
pub fn closeFile(io: std.Io, file: std.Io.File) void {
    file.close(io);
}

//
// A reader over an open file, filling the given buffer.
//
pub fn fileReader(io: std.Io, file: std.Io.File, buffer: []u8) std.Io.File.Reader {
    return file.reader(io, buffer);
}

//
// Milliseconds since the epoch, from the wall clock.
//
// Used to decide whether a lock file is old enough to have been abandoned. In 0.16 the clock, like
// everything else that talks to the outside, is reached through the `Io`.
//
pub fn nowMs(io: std.Io) f64 {
    const stamp = std.Io.Clock.Timestamp.now(io, .real);
    return @as(f64, @floatFromInt(stamp.raw.nanoseconds)) / std.time.ns_per_ms;
}

//
// Waits for the given number of milliseconds.
//
pub fn sleepMs(io: std.Io, milliseconds: u64) void {
    io.sleep(.fromNanoseconds(@intCast(milliseconds * std.time.ns_per_ms)), .real) catch {};
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
    // The `Io` the directory was made with, used for everything done to it afterwards.
    //
    // Held rather than passed to each method because a directory only ever makes sense against the
    // implementation that created it, and a test that had to repeat the same argument on every line
    // would say nothing extra by doing so.
    //
    io: std.Io,

    //
    // Where the path is allocated from. The page allocator rather than a caller's, so a test needs
    // no allocator to make a directory, and nothing here can be mistaken for a leak in the code
    // under test.
    //
    const path_allocator = std.heap.page_allocator;

    //
    // Makes a fresh empty directory under the system temporary directory.
    //
    pub fn create(io: std.Io) !TemporaryDir {
        var random_bytes: [12]u8 = undefined;
        io.random(&random_bytes);
        const suffix = std.fmt.bytesToHex(random_bytes, .lower);

        const path = try std.fmt.allocPrint(path_allocator, "/tmp/what-changed-test-{s}", .{suffix});
        errdefer path_allocator.free(path);

        try makeDirPath(io, path);
        return .{ .path = path, .io = io };
    }

    //
    // Removes the directory and everything in it.
    //
    pub fn destroy(self: *TemporaryDir) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
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
        try makeParentDir(self.io, full_path);
        try writeFile(self.io, full_path, contents);
    }

    //
    // Reads a file from inside the directory.
    //
    pub fn read(self: *const TemporaryDir, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
        var buffer: [512]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.path, sub_path });
        return readFile(self.io, allocator, full_path);
    }

    //
    // True when something inside the directory exists.
    //
    pub fn has(self: *const TemporaryDir, sub_path: []const u8) bool {
        var buffer: [512]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.path, sub_path }) catch return false;
        return fileExists(self.io, full_path);
    }
};

//
// An `Io` for one test, torn down with it.
//
// Every test that touches a disk makes its own rather than sharing one, so nothing a test does to
// its `Io` can reach another test. Held by the caller, because the `Io` handed out points back at
// the `Threaded` inside it and a copy would leave that pointer aimed at the wrong place.
//
pub const TestIo = struct {
    threaded: std.Io.Threaded,

    //
    // The page allocator rather than the testing allocator: this belongs to the test itself, not to
    // the code under test, so it must not show up in that code's leak checking.
    //
    pub fn init() TestIo {
        return .{ .threaded = .init(std.heap.page_allocator, .{}) };
    }

    pub fn io(self: *TestIo) std.Io {
        return self.threaded.io();
    }

    pub fn deinit(self: *TestIo) void {
        self.threaded.deinit();
    }
};

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("files.test.zig");
}
