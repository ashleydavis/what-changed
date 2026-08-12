//
// The reusable half of the project, gathered under one name.
//
// What belongs here is anything not specific to what-changed: the file hashing, the config format,
// the comparison, the output formats, the command line library. What does not is the application
// itself, which is src/main.zig and src/cmd.
//
// The CLI and the benchmarks at perf-tests/run.zig both reach it through this one module, which is
// what lets the benchmarks measure the real code rather than a copy of it.
//
// Most of what is here takes everything it needs as arguments and touches no global state: no argv,
// no working directory, no stdout. That is what makes it reachable from a unit test, and it is a
// property worth preserving module by module. It is not universal, though. `commander` is a command
// line library, so it is about argv by definition, and `files` owns the one piece of global state in
// the project, the `Io` every filesystem call goes through.
//

//
// Carrying the message that goes with a failure, in place of an exception.
//
pub const failure = @import("failure.zig");

//
// The value used wherever the structure is not known at compile time.
//
pub const value = @import("value.zig");

//
// Reading and writing JSON.
//
pub const json = @import("json.zig");

//
// Reading and writing YAML, in place of the `yaml` package.
//
pub const yaml = @import("yaml.zig");

//
// The filesystem operations everything else is built out of.
//
pub const files = @import("files.zig");

//
// A map of repository-relative path to content hash.
//
pub const file_hashes = @import("file_hashes.zig");

//
// The configuration file: its structure, and every check that refuses a malformed one.
//
pub const config = @import("config.zig");

//
// Hashing a file's content, and the cache that means an unchanged file is never read twice.
//
pub const file_hash = @import("file_hash.zig");

//
// Enumerating the project's files, by asking git.
//
pub const list_files = @import("list_files.zig");

//
// Comparing the tree against the baseline.
//
pub const changed_files = @import("changed_files.zig");

//
// The hash tree, which answers "did anything under this directory change" in one lookup.
//
pub const merkle = @import("merkle.zig");

//
// The file hash cache, and the locking that makes concurrent writes safe.
//
pub const cache_store = @import("cache_store.zig");

//
// The baseline: what each target saw the last time it passed.
//
pub const baseline_store = @import("baseline_store.zig");

//
// Sorting the changed files into the targets that watch them.
//
pub const categorize = @import("categorize.zig");

//
// How a result is rendered: as text for a person, or as JSON or YAML for a script.
//
pub const output = @import("output.zig");

//
// The command line library: a port of the parts of `commander` this tool uses.
//
// Here rather than beside main.zig because nothing in it is about what-changed. It knows about
// commands, options and help text, and would work unchanged in any other CLI.
//
pub const commander = @import("commander.zig");

//
// The flows the commands are made of.
//
pub const run = @import("run.zig");

//
// Which build this is.
//
pub const version = @import("version.zig");

test {
    //
    // Pulls in every module's own tests, so `zig build test` runs the lot rather than only the
    // handful reachable from whatever happened to be referenced.
    //
    @import("std").testing.refAllDecls(@This());
}
