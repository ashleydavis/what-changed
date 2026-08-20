const std = @import("std");
const value = @import("value.zig");
const json = @import("json.zig");
const yaml = @import("yaml.zig");
const failure = @import("failure.zig");

const Value = value.Value;
const Failure = failure.Failure;

//
// How a command renders what it found.
//
// "text" is for a person reading a terminal. "json" and "yaml" are for something else consuming the
// output, and both render the same object, so a caller can pick whichever its tooling already reads
// without getting a different answer.
//
pub const OutputFormat = enum {
    text,
    json,
    yaml,
};

//
// Every output format, for validating what was given on the command line, and for naming them all
// when what was given is not one of them.
//
pub const OUTPUT_FORMATS = [_]OutputFormat{ .text, .json, .yaml };

//
// The format used when none is given.
//
pub const DEFAULT_OUTPUT_FORMAT: OutputFormat = .text;

//
// Every format's name, comma separated, as the error message lists them.
//
pub const OUTPUT_FORMAT_NAMES = "text, json, yaml";

//
// Checks a value given to --output and returns it as a format, naming every accepted value when it
// is not one of them. Rejected rather than silently defaulted: a typo that quietly gave text output
// would be found only by whatever downstream parser then choked on it.
//
pub fn parseOutputFormat(given: ?[]const u8, fail: *Failure) failure.Error!OutputFormat {
    const text = given orelse return DEFAULT_OUTPUT_FORMAT;

    for (OUTPUT_FORMATS) |format| {
        if (std.ascii.eqlIgnoreCase(@tagName(format), text)) {
            return format;
        }
    }

    return fail.set("Unknown --output format \"{s}\". Use one of: {s}.", .{ text, OUTPUT_FORMAT_NAMES });
}

//
// Where a command's output goes.
//
// The reporting code prints a great many lines and none of them can usefully fail: if stdout has
// gone away there is nothing to say and nowhere to say it. So printing does not return an error,
// and the reporting functions stay free of handling that would only ever describe a broken pipe.
//
// The failure is recorded rather than dropped, so the CLI can still exit non-zero if the output
// never made it anywhere. A caller that redirects into a full disk gets told.
//
pub const Output = struct {
    //
    // Where the text goes. A buffered file writer in the CLI, and a growing buffer in a test, which
    // is what lets a test assert on whole reports rather than on the pieces they are built from.
    //
    writer: *std.Io.Writer,

    //
    // Whether any write failed.
    //
    failed: bool = false,

    //
    // Prints one line, adding the newline.
    //
    pub fn line(self: *Output, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt ++ "\n", args) catch {
            self.failed = true;
        };
    }

    //
    // Prints an empty line, which the reports use to separate their sections.
    //
    pub fn blank(self: *Output) void {
        self.line("", .{});
    }
};

//
// Renders a value in whichever machine-readable format was asked for, without a trailing newline.
//
// Both formats render the identical object, so switching between them changes only the punctuation.
// Returning the text rather than printing it is what lets a test assert on the whole rendering
// instead of having to capture the process's output.
//
pub fn renderStructured(allocator: std.mem.Allocator, root: Value, format: OutputFormat) std.mem.Allocator.Error![]const u8 {
    return switch (format) {
        .yaml => yaml.stringify(allocator, root),
        //
        // Text is not a machine-readable format and never reaches here through the CLI, but
        // rendering it as JSON rather than crashing keeps this total: a caller that gets the format
        // wrong sees data, not a panic.
        //
        .json, .text => json.stringify(allocator, root),
    };
}

//
// Prints a value in whichever machine-readable format was asked for.
//
pub fn printStructured(allocator: std.mem.Allocator, out: *Output, root: Value, format: OutputFormat) std.mem.Allocator.Error!void {
    out.line("{s}", .{try renderStructured(allocator, root, format)});
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("output.test.zig");
}
