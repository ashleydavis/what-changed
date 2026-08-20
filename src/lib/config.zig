const std = @import("std");
const value = @import("value.zig");
const json = @import("json.zig");
const yaml = @import("yaml.zig");
const failure = @import("failure.zig");
const files = @import("files.zig");

const Value = value.Value;
const Failure = failure.Failure;

//
// The config file formats the tool understands, chosen by the file's extension.
//
pub const ConfigFormat = enum {
    yaml,
    json,

    //
    // What each format is called in an error message.
    //
    pub fn name(self: ConfigFormat) []const u8 {
        return switch (self) {
            .yaml => "YAML",
            .json => "JSON",
        };
    }
};

//
// The config file names looked for, in order, when none is named on the command line. YAML comes
// first because it is the format the examples lead with.
//
pub const DEFAULT_CONFIG_NAMES = [_][]const u8{
    "what-changed.yaml",
    "what-changed.yml",
    "what-changed.json",
};

//
// The cache directory used when the config does not name one, relative to the config file.
//
// Under .what-changed/ alongside the baseline so a project has one path to gitignore, but in its own
// subdirectory: the cache is disposable and the baseline is not, so "cache reset" must never be able
// to reach the baseline.
//
pub const DEFAULT_CACHE_DIR = ".what-changed/cache";

//
// The baseline file used when the config does not name one, relative to the config file.
//
pub const DEFAULT_BASELINE_PATH = ".what-changed/baseline.json";

//
// One script the tool can ask the runner for, and the paths that decide whether it needs to run.
//
pub const TargetConfig = struct {
    //
    // The script name handed to the runner.
    //
    name: []const u8,

    //
    // Repository-relative files or directories whose content decides whether this target runs.
    //
    paths: [][]const u8,

    //
    // The platform names this target can run on. Empty means every platform.
    //
    platforms: [][]const u8,
};

//
// The whole configuration. Everything project-specific lives here, so the package itself carries
// nothing about any particular project.
//
pub const Config = struct {
    //
    // Where the recorded hashes are kept, relative to the config file's directory.
    //
    cache_dir: []const u8,

    //
    // Where the baseline is recorded, relative to the config file's directory. Kept apart from the
    // cache directory because the cache is disposable and this is not.
    //
    baseline_path: []const u8,

    //
    // Paths watched by every target, for things that change how every suite runs.
    //
    always: [][]const u8,

    //
    // File extensions, each including its leading dot, that are left out of the file list entirely.
    // A file whose extension is listed can never make any target run.
    //
    ignore: [][]const u8,

    //
    // The targets the tool can run.
    //
    targets: []TargetConfig,
};

//
// Decides which format a config file is in from its extension. An unrecognised extension is an error
// rather than a guess: reading a YAML file as JSON would fail with a message about the wrong thing.
//
pub fn formatForPath(allocator: std.mem.Allocator, config_path: []const u8, fail: *Failure) failure.Error!ConfigFormat {
    const extension = try std.ascii.allocLowerString(allocator, std.fs.path.extension(config_path));

    if (std.mem.eql(u8, extension, ".yaml") or std.mem.eql(u8, extension, ".yml")) {
        return .yaml;
    }
    if (std.mem.eql(u8, extension, ".json")) {
        return .json;
    }

    return fail.set(
        "what-changed config \"{s}\" has an unrecognised extension \"{s}\". Use .yaml, .yml or .json.",
        .{ config_path, extension },
    );
}

//
// Parses the raw text of a config in whichever format it is written in, and reports a syntax error
// naming that format.
//
pub fn parseConfigText(allocator: std.mem.Allocator, raw_text: []const u8, format: ConfigFormat, fail: *Failure) failure.Error!Value {
    return switch (format) {
        .yaml => yaml.parseOrFail(allocator, raw_text, "what-changed config", fail),
        .json => json.parseOrFail(allocator, raw_text, "what-changed config", fail),
    };
}

//
// Parses and validates a configuration, failing with a message naming the offending field and value
// for anything malformed. A wrong config must fail loudly: silently falling back to a default would
// mean a suite quietly stops running.
//
pub fn parseConfig(allocator: std.mem.Allocator, raw_text: []const u8, format: ConfigFormat, fail: *Failure) failure.Error!Config {
    const parsed = try parseConfigText(allocator, raw_text, format, fail);

    if (!value.isPlainObject(parsed)) {
        return fail.set("what-changed config must be a {s} object, got {s}", .{
            format.name(), try value.describe(allocator, parsed),
        });
    }

    const cache_dir = try readPathField(allocator, parsed, "cacheDir", DEFAULT_CACHE_DIR, fail);
    const baseline_path = try readPathField(allocator, parsed, "baselinePath", DEFAULT_BASELINE_PATH, fail);

    const always = try readStringArrayField(allocator, parsed, "always", fail);
    for (always) |watched_path| {
        try validateWatchedPath(watched_path, "always", fail);
    }

    const ignore = try readStringArrayField(allocator, parsed, "ignore", fail);
    for (ignore) |extension| {
        try validateIgnoreExtension(extension, fail);
    }

    const raw_targets = value.get(parsed, "targets");
    const targets_array = switch (raw_targets orelse Value.null) {
        .array => |array| array,
        else => return fail.set("what-changed config field \"targets\" must be a non-empty array, got {s}", .{
            try value.describe(allocator, raw_targets),
        }),
    };
    if (targets_array.items.len == 0) {
        return fail.set("what-changed config field \"targets\" must be a non-empty array, got {s}", .{
            try value.describe(allocator, raw_targets),
        });
    }

    //
    // Names are collected as the targets are parsed, so a duplicate is caught by the target that
    // repeats it rather than by a second pass that would have to say which of the two is at fault.
    //
    var seen_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    var targets: std.ArrayList(TargetConfig) = .empty;
    for (targets_array.items) |raw_target| {
        try targets.append(allocator, try parseTarget(allocator, raw_target, &seen_names, fail));
    }

    return .{
        .cache_dir = cache_dir,
        .baseline_path = baseline_path,
        .always = always,
        .ignore = ignore,
        .targets = try targets.toOwnedSlice(allocator),
    };
}

//
// Reads a field that must be a non-empty string, or is absent and takes a default.
//
fn readPathField(allocator: std.mem.Allocator, parsed: Value, field: []const u8, default: []const u8, fail: *Failure) failure.Error![]const u8 {
    const raw = value.get(parsed, field) orelse return default;
    switch (raw) {
        .string => |text| if (text.len > 0) return text,
        else => {},
    }
    return fail.set("what-changed config field \"{s}\" must be a non-empty string, got {s}", .{
        field, try value.describe(allocator, raw),
    });
}

//
// Reads a field that must be an array, or is absent and defaults to an empty one.
//
// The entries are not checked here. What makes an entry valid differs between the fields, and each
// caller says so itself with a message naming that field.
//
fn readStringArrayField(allocator: std.mem.Allocator, parsed: Value, field: []const u8, fail: *Failure) failure.Error![][]const u8 {
    const raw = value.get(parsed, field) orelse return &.{};

    const array = switch (raw) {
        .array => |array| array,
        else => return fail.set("what-changed config field \"{s}\" must be an array, got {s}", .{
            field, try value.describe(allocator, raw),
        }),
    };

    //
    // Anything that is not a string is left as an empty entry, which every caller then rejects with
    // its own message. Checking here instead would mean one message for two different fields.
    //
    var entries: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        try entries.append(allocator, switch (item) {
            .string => |text| text,
            else => try nonStringPlaceholder(allocator, item),
        });
    }
    return entries.toOwnedSlice(allocator);
}

//
// Renders a non-string array entry so the message about it can quote what was actually written.
//
// Prefixed with a NUL, which no real path or extension can hold, so the checks downstream can tell
// a placeholder from a genuine value and report the original rather than the rendering.
//
fn nonStringPlaceholder(allocator: std.mem.Allocator, item: Value) std.mem.Allocator.Error![]const u8 {
    return std.mem.concat(allocator, u8, &.{ "\x00", try value.describe(allocator, item) });
}

//
// The rendering of a value that was not a string, or null when the entry really is a string.
//
fn placeholderText(entry: []const u8) ?[]const u8 {
    if (entry.len > 0 and entry[0] == 0) return entry[1..];
    return null;
}

//
// Parses and validates one target, recording its name so a duplicate can be rejected.
//
pub fn parseTarget(allocator: std.mem.Allocator, raw_target: Value, seen_names: *std.StringArrayHashMapUnmanaged(void), fail: *Failure) failure.Error!TargetConfig {
    if (!value.isPlainObject(raw_target)) {
        return fail.set("what-changed config target must be an object, got {s}", .{
            try value.describe(allocator, raw_target),
        });
    }

    const raw_name = value.get(raw_target, "name");
    const name = switch (raw_name orelse Value.null) {
        .string => |text| text,
        else => "",
    };
    if (name.len == 0) {
        return fail.set("what-changed config target field \"name\" must be a non-empty string, got {s}", .{
            try value.describe(allocator, raw_name),
        });
    }
    if (seen_names.contains(name)) {
        return fail.set("what-changed config has a duplicate target name \"{s}\"", .{name});
    }
    try seen_names.put(allocator, name, {});

    const raw_paths = value.get(raw_target, "paths");
    const is_array = switch (raw_paths orelse Value.null) {
        .array => |array| array.items.len > 0,
        else => false,
    };
    if (!is_array) {
        return fail.set("what-changed config target \"{s}\" field \"paths\" must be a non-empty array, got {s}", .{
            name, try value.describe(allocator, raw_paths),
        });
    }

    const paths = try readStringArrayField(allocator, raw_target, "paths", fail);
    const field_description = try std.fmt.allocPrint(allocator, "target \"{s}\" paths", .{name});
    for (paths) |watched_path| {
        try validateWatchedPath(watched_path, field_description, fail);
    }

    //
    // A platform list is optional, and an absent one means every platform, which is what a config
    // that says nothing about platforms has always meant.
    //
    if (value.get(raw_target, "platforms")) |raw_platforms| {
        switch (raw_platforms) {
            .array => {},
            else => return fail.set("what-changed config target \"{s}\" field \"platforms\" must be an array, got {s}", .{
                name, try value.describe(allocator, raw_platforms),
            }),
        }
    }
    const platforms = try readStringArrayField(allocator, raw_target, "platforms", fail);
    for (platforms) |platform| {
        if (placeholderText(platform)) |written| {
            return fail.set("what-changed config target \"{s}\" field \"platforms\" must hold non-empty strings, got {s}", .{ name, written });
        }
        if (platform.len == 0) {
            return fail.set("what-changed config target \"{s}\" field \"platforms\" must hold non-empty strings, got \"\"", .{name});
        }
    }

    return .{
        .name = name,
        .paths = paths,
        .platforms = platforms,
    };
}

//
// Rejects anything that is not a relative path inside the project. An absolute path or one that
// climbs out with ".." would let the tool watch, and later report on, files outside the repository.
//
pub fn validateWatchedPath(watched_path: []const u8, field_description: []const u8, fail: *Failure) failure.Error!void {
    if (placeholderText(watched_path)) |written| {
        return fail.set("what-changed config field \"{s}\" must hold non-empty strings, got {s}", .{ field_description, written });
    }
    if (watched_path.len == 0) {
        return fail.set("what-changed config field \"{s}\" must hold non-empty strings, got \"\"", .{field_description});
    }
    if (files.isAbsolutePath(watched_path)) {
        return fail.set("what-changed config field \"{s}\" must hold relative paths, got \"{s}\"", .{ field_description, watched_path });
    }

    var segments = std.mem.splitScalar(u8, watched_path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) {
            return fail.set("what-changed config field \"{s}\" must not contain a \"..\" segment, got \"{s}\"", .{ field_description, watched_path });
        }
    }
}

//
// Rejects anything that is not a file extension with a leading dot. The dot is required rather than
// added silently, because "ts" could plausibly mean an extension or a directory and guessing wrong
// would quietly stop a suite from running.
//
pub fn validateIgnoreExtension(extension: []const u8, fail: *Failure) failure.Error!void {
    if (placeholderText(extension)) |written| {
        return fail.set("what-changed config field \"ignore\" must hold non-empty strings, got {s}", .{written});
    }
    if (extension.len == 0) {
        return fail.set("what-changed config field \"ignore\" must hold non-empty strings, got \"\"", .{});
    }
    if (extension[0] != '.') {
        return fail.set("what-changed config field \"ignore\" entries must start with a dot, got \"{s}\"", .{extension});
    }
    if (extension.len == 1) {
        return fail.set("what-changed config field \"ignore\" entries must have something after the dot, got \"{s}\"", .{extension});
    }
    if (std.mem.indexOfScalar(u8, extension, '/') != null) {
        return fail.set("what-changed config field \"ignore\" holds extensions, not paths, got \"{s}\"", .{extension});
    }
}

//
// Reads a configuration from disk and parses it, naming the path when the file cannot be read.
//
pub fn loadConfig(io: std.Io, allocator: std.mem.Allocator, config_path: []const u8, fail: *Failure) failure.Error!Config {
    const format = try formatForPath(allocator, config_path, fail);

    const raw_text = files.readFile(io, allocator, config_path) catch |err| {
        return fail.set("Failed to read the what-changed config at \"{s}\": {s}", .{
            config_path, try files.describeOperation(allocator, err, "open", config_path),
        });
    };

    return parseConfig(allocator, raw_text, format, fail);
}

//
// Resolves the config file to read: the one named on the command line, or the first known name
// found in the working directory.
//
pub fn resolveConfigPath(io: std.Io, allocator: std.mem.Allocator, named_config: ?[]const u8, cwd: []const u8, fail: *Failure) failure.Error![]const u8 {
    if (named_config) |named| {
        return files.resolvePath(allocator, cwd, named);
    }
    return findConfig(io, allocator, cwd, fail);
}

//
// Looks for a config under each of the known names in turn.
//
// Naming every name it looked for matters: "no config found" without the list leaves the user
// guessing which spellings and formats are allowed.
//
pub fn findConfig(io: std.Io, allocator: std.mem.Allocator, root_dir: []const u8, fail: *Failure) failure.Error![]const u8 {
    for (DEFAULT_CONFIG_NAMES) |name| {
        const candidate = try std.fs.path.join(allocator, &.{ root_dir, name });
        if (files.fileExists(io, candidate)) {
            return candidate;
        }
    }

    return fail.set("No what-changed config found in \"{s}\". Looked for: {s}, {s}, {s}.", .{
        root_dir, DEFAULT_CONFIG_NAMES[0], DEFAULT_CONFIG_NAMES[1], DEFAULT_CONFIG_NAMES[2],
    });
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("config.test.zig");
}
