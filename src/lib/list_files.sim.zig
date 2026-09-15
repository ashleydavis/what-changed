// The deterministic simulation for `list_files.zig`: a real repository to list, and the two ways
// asking git for one goes wrong.

const std = @import("std");
const sim = @import("sim");
const list_files = @import("list_files.zig");
const files = @import("files.zig");
const failure = @import("failure.zig");
const annotate_mod = @import("log");

const Subject = sim.Subject(annotate_mod.Log);

pub fn runGitScenario(self: *Subject, injector: *sim.Injector, checklist: *sim.Checklist) anyerror!void {
    // The run reads what the code annotated, so a scenario never says what it covered.
    _ = checklist;
    _ = injector;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // EXEMPTION: the only scenario that reaches the real disk rather than the run's in-memory
    // filesystem, because everything below it starts a real `git`. A child process is given the
    // kernel's own view of the filesystem, so a repository held in this process's memory is not
    // there when `git` looks, and the fake `git` written further down could not be executed at all.
    // Nothing on our side can simulate a process, so this one pays for real files.
    var test_io = files.TestIo.init(self.log);
    defer test_io.deinit();
    const io = test_io.io();

    var temporary = try files.TemporaryDir.create(io, self.log);
    defer temporary.destroy();
    try temporary.write("src/a.ts", "the contents\n");

    var environ = std.process.Environ.Map.init(allocator);

    // A directory with no repository in it, which git refuses with an exit code.
    var refused = failure.Failure.init(allocator, self.log);
    _ = list_files.runGitLsFiles(io, &environ, allocator, temporary.path, &refused) catch {};
    _ = list_files.listRepoFiles(io, &environ, allocator, temporary.path, &refused) catch {};

    // A directory that is not there at all, which git cannot even be started in.
    const nowhere = try temporary.join(allocator, "nowhere");
    var cannot_start = failure.Failure.init(allocator, self.log);
    _ = list_files.runGitLsFiles(io, &environ, allocator, nowhere, &cannot_start) catch {};

    // A real repository, which git lists.
    const made = std.process.run(allocator, io, .{
        .argv = &.{ "git", "init", "--quiet" },
        .cwd = .{ .path = temporary.path },
        .environ_map = &environ,
    }) catch null;
    if (made != null) {
        var listed = failure.Failure.init(allocator, self.log);
        _ = list_files.runGitLsFiles(io, &environ, allocator, temporary.path, &listed) catch {};
        _ = list_files.listRepoFiles(io, &environ, allocator, temporary.path, &listed) catch {};
    }

    // A git that is killed before it finishes, which is the third way the spawn ends. A run cannot
    // kill the real git part way through a listing, so it starts one of its own that ends itself.
    //
    // Which `git` is started is decided by the PATH the `Io` read when it was made, not by the
    // environment the call is handed, so the one this stands up is told where to look.
    {
        const fake_dir = try temporary.join(allocator, "fake-tools");
        try files.makeDirPath(io, fake_dir);
        const fake_git = try std.fmt.allocPrintSentinel(allocator, "{s}/git", .{fake_dir}, 0);
        try files.writeFile(io, fake_git, "#!/bin/sh\nkill -9 $$\n");
        _ = std.os.linux.chmod(fake_git.ptr, 0o755);

        var ends_itself = files.TestIo.init(self.log);
        defer ends_itself.deinit();
        ends_itself.threaded.environ.string.PATH = try allocator.dupeZ(u8, fake_dir);

        var killed = failure.Failure.init(allocator, self.log);
        _ = list_files.runGitLsFiles(ends_itself.io(), &environ, allocator, temporary.path, &killed) catch {};
    }

    // The parsing on its own, over output with nothing in it, one path, and several, including the
    // empty pieces a trailing separator leaves behind.
    for ([_][]const u8{ "", "one\x00", "one\x00two\x00three\x00", "\x00\x00" }) |stdout| {
        _ = try list_files.parseGitFileList(allocator, stdout, self.log);
    }

    // The ignore rules, over a list with nothing ignored and one with something.
    const paths = [_][]const u8{ "src/a.ts", "README.md", "notes.MD" };
    _ = try list_files.filterIgnoredFiles(allocator, &paths, &.{}, self.log);
    _ = try list_files.filterIgnoredFiles(allocator, &paths, &.{".md"}, self.log);
    for (paths) |path| {
        _ = list_files.isIgnoredFile(path, &.{}, self.log);
        _ = list_files.isIgnoredFile(path, &.{ ".md", ".averylongextension" }, self.log);
    }
}
