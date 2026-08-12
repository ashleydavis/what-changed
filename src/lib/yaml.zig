const std = @import("std");
const value = @import("value.zig");
const failure = @import("failure.zig");

const Value = value.Value;
const Failure = failure.Failure;

//
// Reading and writing the subset of YAML this tool's config files are written in.
//
// Zig's standard library has no YAML, and the alternative to writing this was taking a package
// dependency, so this is a deliberate, bounded implementation: block mappings, block sequences,
// flow sequences and mappings on one line,
// comments, quoted and plain scalars. That is everything the documented config format uses and
// everything the examples show.
//
// What it is NOT is a general YAML implementation. Anchors, aliases, tags, multi-line scalars and
// multiple documents in one file are not supported, and a config using them is refused with a
// syntax error rather than silently misread. Refusing is the safe direction: a config this tool
// misunderstands is a suite that quietly stops running, which is the one failure this whole project
// exists to prevent.
//
// Indentation is checked rather than assumed. A line that is deeper than the block it follows but
// does not line up with anything is an error, which is what catches the classic mistake of a
// mapping key under a sequence item being one space out.
//

//
// A syntax error, carrying where it happened so the message can point at the line.
//
pub const SyntaxError = struct {
    //
    // What is wrong, in words.
    //
    message: []const u8,

    //
    // The 1-based line the problem is on.
    //
    line: usize,

    //
    // The 1-based column the problem is at.
    //
    column: usize,
};

//
// One line of the input, once its indentation has been measured and its comment removed.
//
const Line = struct {
    //
    // How many spaces the line is indented by.
    //
    indent: usize,

    //
    // What the line says, with the indentation and any trailing comment taken off.
    //
    content: []const u8,

    //
    // The 1-based line number in the original text, for error messages.
    //
    number: usize,
};

//
// The parser's state: the lines to read and how far through them it is.
//
const Parser = struct {
    allocator: std.mem.Allocator,

    //
    // Mutable, because a sequence item that carries its value on the dash's own line is handled by
    // rewriting that line: the dash is dropped and the line is re-measured as if the value had been
    // written on a line of its own, at the column it actually starts in. Every block parser below
    // then works on lines whose indentation means what it says, with no special case threaded
    // through it for "except when the first line came after a dash".
    //
    lines: []Line,
    index: usize = 0,
    err: ?SyntaxError = null,

    const Error = error{ Syntax, OutOfMemory };

    //
    // Records a syntax error and returns the error to return.
    //
    fn syntax(self: *Parser, line: usize, column: usize, message: []const u8) Error {
        if (self.err == null) {
            self.err = .{ .message = message, .line = line, .column = column };
        }
        return error.Syntax;
    }

    //
    // The line the parser is looking at, or null at the end of the input.
    //
    fn peek(self: *const Parser) ?Line {
        if (self.index >= self.lines.len) return null;
        return self.lines[self.index];
    }

    //
    // Parses whatever block starts at the current line, at the given indentation.
    //
    // A block is a sequence when its first line begins with a dash, and a mapping otherwise. That
    // is the whole of YAML's block-level structure, and it is decided per block rather than once
    // for the document, which is what lets a mapping hold sequences and vice versa.
    //
    fn parseBlock(self: *Parser, indent: usize) Error!Value {
        const line = self.peek() orelse return .null;
        if (isSequenceEntry(line.content)) {
            return self.parseSequence(indent);
        }
        return self.parseMapping(indent);
    }

    //
    // Parses consecutive `- item` lines at one indentation into an array.
    //
    fn parseSequence(self: *Parser, indent: usize) Error!Value {
        var array = value.newArray(self.allocator);

        while (self.peek()) |line| {
            if (line.indent != indent or !isSequenceEntry(line.content)) break;

            //
            // Everything after the dash and the spaces following it. Its column matters: a mapping
            // written on the same line as the dash starts a block whose indentation is that column,
            // not the dash's, which is how `- name: x` followed by an aligned `paths:` works.
            //
            const after_dash = std.mem.trimStart(u8, line.content[1..], " ");
            const item_column = line.indent + (line.content.len - after_dash.len);

            if (after_dash.len == 0) {
                //
                // A bare dash: the item is whatever block is indented under it.
                //
                self.index += 1;
                try array.append(try self.parseIndentedBlock(line.indent));
            } else if (splitMappingEntry(after_dash) != null or isSequenceEntry(after_dash)) {
                //
                // A block starting on the dash's own line. Rewriting the line as if it had been
                // written at its real column, without the dash, is what lets the block parsers read
                // the following lines: those are indented to line up with this content, not with
                // the dash, so measuring this line by its dash would make every one of them look
                // over-indented.
                //
                self.lines[self.index] = .{ .indent = item_column, .content = after_dash, .number = line.number };
                try array.append(try self.parseBlock(item_column));
            } else {
                //
                // A plain value.
                //
                self.index += 1;
                try array.append(try self.parseScalar(after_dash, line.number, item_column + 1));
            }

            try self.rejectDanglingIndent(indent);
        }

        return .{ .array = array };
    }

    //
    // Parses consecutive `key: value` lines at one indentation into an object.
    //
    fn parseMapping(self: *Parser, indent: usize) Error!Value {
        var object = value.newObject(self.allocator);

        while (self.peek()) |line| {
            if (line.indent != indent or isSequenceEntry(line.content)) break;

            const entry = splitMappingEntry(line.content) orelse
                return self.syntax(line.number, line.indent + 1, "expected a \"key: value\" pair");

            const key = try self.parseKey(entry.key, line.number, line.indent + 1);

            if (entry.rest.len == 0) {
                //
                // Nothing after the colon, so the value is the block underneath.
                //
                self.index += 1;
                try object.put(self.allocator, key, try self.parseIndentedBlock(indent));
            } else {
                self.index += 1;
                const column = line.indent + (line.content.len - entry.rest.len) + 1;
                try object.put(self.allocator, key, try self.parseScalar(entry.rest, line.number, column));
            }

            try self.rejectDanglingIndent(indent);
        }

        return .{ .object = object };
    }

    //
    // Parses the block belonging to a key or a bare dash: the lines underneath it.
    //
    // A sequence is allowed at the owner's own indentation as well as deeper, because YAML lets a
    // sequence sit level with the key it belongs to. Anything else has to be indented further, and
    // an owner with nothing under it has the value null.
    //
    fn parseIndentedBlock(self: *Parser, owner_indent: usize) Error!Value {
        const line = self.peek() orelse return .null;

        if (line.indent > owner_indent) {
            return self.parseBlock(line.indent);
        }
        if (line.indent == owner_indent and isSequenceEntry(line.content)) {
            return self.parseSequence(owner_indent);
        }
        return .null;
    }

    //
    // Refuses a line that is indented deeper than the block just finished without belonging to
    // anything in it.
    //
    // This is the check that catches a misaligned key. Without it the line would simply end the
    // block and then fail somewhere far away, or worse, be swallowed by an outer block and change
    // what the config means.
    //
    fn rejectDanglingIndent(self: *Parser, indent: usize) Error!void {
        const line = self.peek() orelse return;
        if (line.indent > indent) {
            return self.syntax(line.number, line.indent + 1, "this line is indented further than the block it follows, so nothing owns it");
        }
    }

    //
    // Reads a mapping key, which is a scalar but must come out as a string.
    //
    fn parseKey(self: *Parser, text: []const u8, line: usize, column: usize) Error![]const u8 {
        const parsed = try self.parseScalar(text, line, column);
        return switch (parsed) {
            .string => |string| string,
            else => self.syntax(line, column, "a mapping key must be a plain or quoted string"),
        };
    }

    //
    // Parses one scalar or one-line flow collection.
    //
    fn parseScalar(self: *Parser, text: []const u8, line: usize, column: usize) Error!Value {
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return .null;

        switch (trimmed[0]) {
            '[', '{' => {
                var flow = Flow{ .parser = self, .text = trimmed, .line = line, .column = column };
                const parsed = try flow.parseValue();
                flow.skipSpaces();
                if (flow.at < flow.text.len) {
                    return self.syntax(line, column + flow.at, "unexpected text after the end of the value");
                }
                return parsed;
            },
            '"', '\'' => {
                var flow = Flow{ .parser = self, .text = trimmed, .line = line, .column = column };
                const parsed = try flow.parseQuoted();
                flow.skipSpaces();
                if (flow.at < flow.text.len) {
                    return self.syntax(line, column + flow.at, "unexpected text after the end of the quoted value");
                }
                return parsed;
            },
            '&', '*', '!', '|', '>', '%', '@', '`' => {
                return self.syntax(line, column, "this YAML feature is not supported by what-changed");
            },
            else => return try self.plainScalar(trimmed),
        }
    }

    //
    // Turns an unquoted scalar into a value, recognising the handful of words and number formats
    // YAML gives a meaning to and treating everything else as a string.
    //
    fn plainScalar(self: *Parser, text: []const u8) Error!Value {
        if (isNull(text)) return .null;
        if (isTrue(text)) return value.boolean(true);
        if (isFalse(text)) return value.boolean(false);

        if (std.fmt.parseInt(i64, text, 10)) |whole| {
            return value.int(whole);
        } else |_| {}

        if (looksLikeFloat(text)) {
            if (std.fmt.parseFloat(f64, text)) |number| {
                return .{ .float = number };
            } else |_| {}
        }

        return value.str(try self.allocator.dupe(u8, text));
    }
};

//
// Parses a flow collection or quoted scalar: the bracketed, comma-separated form that fits on one
// line, such as `[]`, `[a, b]` or `{ name: alpha }`.
//
const Flow = struct {
    parser: *Parser,
    text: []const u8,
    line: usize,
    column: usize,
    at: usize = 0,

    fn skipSpaces(self: *Flow) void {
        while (self.at < self.text.len and (self.text[self.at] == ' ' or self.text[self.at] == '\t')) {
            self.at += 1;
        }
    }

    fn fail(self: *Flow, message: []const u8) Parser.Error {
        return self.parser.syntax(self.line, self.column + self.at, message);
    }

    //
    // Parses any value inside a flow collection.
    //
    fn parseValue(self: *Flow) Parser.Error!Value {
        self.skipSpaces();
        if (self.at >= self.text.len) return self.fail("expected a value");

        return switch (self.text[self.at]) {
            '[' => self.parseSequence(),
            '{' => self.parseMapping(),
            '"', '\'' => self.parseQuoted(),
            else => self.parsePlain(),
        };
    }

    //
    // Parses `[a, b, c]`.
    //
    fn parseSequence(self: *Flow) Parser.Error!Value {
        self.at += 1; // The opening bracket.
        var array = value.newArray(self.parser.allocator);

        self.skipSpaces();
        if (self.at < self.text.len and self.text[self.at] == ']') {
            self.at += 1;
            return .{ .array = array };
        }

        while (true) {
            try array.append(try self.parseValue());
            self.skipSpaces();
            if (self.at >= self.text.len) return self.fail("this list is missing its closing \"]\"");
            switch (self.text[self.at]) {
                ',' => self.at += 1,
                ']' => {
                    self.at += 1;
                    return .{ .array = array };
                },
                else => return self.fail("expected a \",\" or a \"]\" in this list"),
            }
        }
    }

    //
    // Parses `{ key: value, other: value }`.
    //
    fn parseMapping(self: *Flow) Parser.Error!Value {
        self.at += 1; // The opening brace.
        var object = value.newObject(self.parser.allocator);

        self.skipSpaces();
        if (self.at < self.text.len and self.text[self.at] == '}') {
            self.at += 1;
            return .{ .object = object };
        }

        while (true) {
            self.skipSpaces();
            const key = try self.parseValue();
            if (key != .string) return self.fail("a mapping key must be a plain or quoted string");

            self.skipSpaces();
            if (self.at >= self.text.len or self.text[self.at] != ':') {
                return self.fail("expected a \":\" after this key");
            }
            self.at += 1;

            try object.put(self.parser.allocator, key.string, try self.parseValue());

            self.skipSpaces();
            if (self.at >= self.text.len) return self.fail("this mapping is missing its closing \"}\"");
            switch (self.text[self.at]) {
                ',' => self.at += 1,
                '}' => {
                    self.at += 1;
                    return .{ .object = object };
                },
                else => return self.fail("expected a \",\" or a \"}\" in this mapping"),
            }
        }
    }

    //
    // Parses a quoted string, single or double.
    //
    // Double quotes take backslash escapes. Single quotes take none, except that two single quotes
    // in a row mean one literal quote, which is how YAML spells it.
    //
    fn parseQuoted(self: *Flow) Parser.Error!Value {
        const quote = self.text[self.at];
        self.at += 1;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.parser.allocator);

        while (self.at < self.text.len) {
            const character = self.text[self.at];

            if (character == quote) {
                if (quote == '\'' and self.at + 1 < self.text.len and self.text[self.at + 1] == '\'') {
                    try out.append(self.parser.allocator, '\'');
                    self.at += 2;
                    continue;
                }
                self.at += 1;
                return value.str(try out.toOwnedSlice(self.parser.allocator));
            }

            if (quote == '"' and character == '\\') {
                self.at += 1;
                if (self.at >= self.text.len) return self.fail("this string ends in a backslash");
                try out.append(self.parser.allocator, switch (self.text[self.at]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    '\\' => '\\',
                    '"' => '"',
                    '/' => '/',
                    else => return self.fail("unsupported escape in this string"),
                });
                self.at += 1;
                continue;
            }

            try out.append(self.parser.allocator, character);
            self.at += 1;
        }

        return self.fail("this string is missing its closing quote");
    }

    //
    // Parses an unquoted value inside a flow collection, which runs until a comma or a closing
    // bracket.
    //
    fn parsePlain(self: *Flow) Parser.Error!Value {
        const start = self.at;
        while (self.at < self.text.len) {
            switch (self.text[self.at]) {
                ',', ']', '}', ':' => break,
                else => self.at += 1,
            }
        }
        const text = std.mem.trim(u8, self.text[start..self.at], " ");
        if (text.len == 0) return self.fail("expected a value");
        return self.parser.plainScalar(text);
    }
};

//
// One `key: value` split apart, before either half has been interpreted.
//
const MappingEntry = struct {
    key: []const u8,
    rest: []const u8,
};

//
// Splits a line into its key and whatever follows the colon, or answers null when the line is not a
// mapping entry at all.
//
// The colon has to be followed by a space or by the end of the line. Without that rule a value like
// `https://example.com` would be read as a key, because it has a colon in it.
//
pub fn splitMappingEntry(content: []const u8) ?MappingEntry {
    var quote: ?u8 = null;
    var at: usize = 0;

    while (at < content.len) : (at += 1) {
        const character = content[at];

        if (quote) |open| {
            if (character == open) quote = null;
            continue;
        }
        if (character == '"' or character == '\'') {
            quote = character;
            continue;
        }
        if (character == ':' and (at + 1 == content.len or content[at + 1] == ' ')) {
            const key = std.mem.trim(u8, content[0..at], " ");
            if (key.len == 0) return null;
            return .{ .key = key, .rest = std.mem.trim(u8, content[at + 1 ..], " ") };
        }
    }

    return null;
}

//
// True when a line starts a sequence item.
//
// The dash has to be alone or followed by a space, so the negative number `-5` is a value rather
// than an empty list item.
//
pub fn isSequenceEntry(content: []const u8) bool {
    if (content.len == 0 or content[0] != '-') return false;
    return content.len == 1 or content[1] == ' ';
}

//
// True for the words YAML reads as null.
//
pub fn isNull(text: []const u8) bool {
    return text.len == 0 or
        std.mem.eql(u8, text, "~") or
        std.ascii.eqlIgnoreCase(text, "null");
}

//
// True for the words YAML reads as true.
//
pub fn isTrue(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "true");
}

//
// True for the words YAML reads as false.
//
pub fn isFalse(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, "false");
}

//
// True when a scalar is written like a decimal number, so it is worth trying to read as one.
//
// Checked before parsing rather than relying on the parse failing, because Zig's float parser
// accepts words this tool must keep as strings, "inf" and "nan" among them.
//
pub fn looksLikeFloat(text: []const u8) bool {
    var at: usize = 0;
    if (at < text.len and (text[at] == '+' or text[at] == '-')) at += 1;

    var digits: usize = 0;
    var dots: usize = 0;
    while (at < text.len) : (at += 1) {
        switch (text[at]) {
            '0'...'9' => digits += 1,
            '.' => dots += 1,
            'e', 'E' => {
                //
                // An exponent has to come after some digits and be a whole number itself.
                //
                if (digits == 0 or at + 1 >= text.len) return false;
                var exponent = at + 1;
                if (text[exponent] == '+' or text[exponent] == '-') exponent += 1;
                if (exponent >= text.len) return false;
                while (exponent < text.len) : (exponent += 1) {
                    if (!std.ascii.isDigit(text[exponent])) return false;
                }
                return dots <= 1;
            },
            else => return false,
        }
    }

    return digits > 0 and dots <= 1;
}

//
// Removes a trailing comment from a line, leaving quoted text alone.
//
// A "#" only starts a comment at the start of a line or after whitespace, which is what keeps a
// value like "a#b" whole.
//
pub fn stripComment(content: []const u8) []const u8 {
    var quote: ?u8 = null;
    var at: usize = 0;

    while (at < content.len) : (at += 1) {
        const character = content[at];

        if (quote) |open| {
            if (character == open) quote = null;
            continue;
        }
        if (character == '"' or character == '\'') {
            quote = character;
            continue;
        }
        if (character == '#' and (at == 0 or content[at - 1] == ' ' or content[at - 1] == '\t')) {
            return std.mem.trimEnd(u8, content[0..at], " \t");
        }
    }

    return std.mem.trimEnd(u8, content, " \t");
}

//
// Splits the text into the lines the parser walks, dropping blanks and comments and measuring each
// remaining line's indentation.
//
fn readLines(allocator: std.mem.Allocator, text: []const u8, err: *?SyntaxError) error{ Syntax, OutOfMemory }![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    var number: usize = 0;
    var walker = std.mem.splitScalar(u8, text, '\n');
    while (walker.next()) |raw_line| {
        number += 1;
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;

        //
        // A tab in the indentation is refused rather than counted. YAML forbids it, and guessing a
        // width for it would mean this tool and every editor disagreeing about what the file says.
        //
        if (indent < line.len and line[indent] == '\t') {
            err.* = .{ .message = "a tab is used for indentation, which YAML does not allow", .line = number, .column = indent + 1 };
            return error.Syntax;
        }

        const content = stripComment(line[indent..]);
        if (content.len == 0) continue;

        //
        // The document markers are accepted and dropped, so a config that starts with "---" reads
        // the same as one that does not. A second document is refused: this tool reads one config,
        // and quietly using the first of several would hide the rest.
        //
        if (std.mem.eql(u8, content, "...")) continue;
        if (std.mem.eql(u8, content, "---")) {
            if (lines.items.len > 0) {
                err.* = .{ .message = "more than one document in the file, which what-changed does not support", .line = number, .column = indent + 1 };
                return error.Syntax;
            }
            continue;
        }

        try lines.append(allocator, .{ .indent = indent, .content = content, .number = number });
    }

    return lines.toOwnedSlice(allocator);
}

//
// Parses YAML text into a dynamic value, reporting where a syntax error is.
//
// An empty document is null, which is what the `yaml` package returns and what the config checks
// then complain about by name.
//
pub fn parse(allocator: std.mem.Allocator, text: []const u8, err: *?SyntaxError) error{ Syntax, OutOfMemory }!Value {
    const lines = try readLines(allocator, text, err);
    if (lines.len == 0) return .null;

    var parser = Parser{ .allocator = allocator, .lines = lines };
    const parsed = parser.parseBlock(lines[0].indent) catch |caught| switch (caught) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => {
            err.* = parser.err;
            return error.Syntax;
        },
    };

    //
    // Anything left over means the document does not hang together: a line the structure above it
    // could not account for. Reported rather than ignored, for the same reason a misaligned key is.
    //
    if (parser.peek()) |line| {
        err.* = .{ .message = "this line does not belong to the document above it", .line = line.number, .column = line.indent + 1 };
        return error.Syntax;
    }

    return parsed;
}

//
// Parses YAML text, failing with a message that names the format and points at the line.
//
pub fn parseOrFail(allocator: std.mem.Allocator, text: []const u8, description: []const u8, fail: *Failure) failure.Error!Value {
    var err: ?SyntaxError = null;
    return parse(allocator, text, &err) catch |caught| switch (caught) {
        error.OutOfMemory => error.OutOfMemory,
        error.Syntax => {
            if (err) |detail| {
                return fail.set("{s} is not valid YAML: {s} at line {d}, column {d}", .{
                    description, detail.message, detail.line, detail.column,
                });
            }
            return fail.set("{s} is not valid YAML", .{description});
        },
    };
}

//
// True when a string has to be quoted to survive a round trip through YAML.
//
// Erring towards quoting is safe: a quoted string always reads back as itself. Erring the other way
// is not, because a plain `true`, `1.5` or empty string reads back as something else entirely.
//
pub fn needsQuoting(text: []const u8) bool {
    if (text.len == 0) return true;
    if (isNull(text) or isTrue(text) or isFalse(text)) return true;
    if (std.fmt.parseInt(i64, text, 10)) |_| return true else |_| {}
    if (looksLikeFloat(text)) return true;

    //
    // Leading or trailing whitespace does not survive plain style, since the reader trims it.
    //
    if (text[0] == ' ' or text[text.len - 1] == ' ') return true;

    //
    // An indicator at the start of a scalar means something to YAML.
    //
    switch (text[0]) {
        '-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => return true,
        else => {},
    }

    //
    // Inside the text, only the sequences that would end the scalar or start a comment matter.
    //
    for (text, 0..) |character, at| {
        switch (character) {
            '\n', '\r', '\t' => return true,
            ':' => if (at + 1 == text.len or text[at + 1] == ' ') return true,
            '#' => if (at > 0 and text[at - 1] == ' ') return true,
            else => {},
        }
    }

    return false;
}

//
// Writes a string as YAML, quoting it only when it would not read back as itself.
//
fn writeString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!void {
    if (!needsQuoting(text)) {
        return out.appendSlice(allocator, text);
    }

    try out.append(allocator, '"');
    for (text) |character| {
        switch (character) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, character),
        }
    }
    try out.append(allocator, '"');
}

//
// Writes a scalar: anything that is not an array or an object.
//
fn writeScalar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node: Value) std.mem.Allocator.Error!void {
    switch (node) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |flag| try out.appendSlice(allocator, if (flag) "true" else "false"),
        .integer => |whole| try out.print(allocator, "{d}", .{whole}),
        .float => |number| try out.print(allocator, "{d}", .{number}),
        .number_string => |text| try out.appendSlice(allocator, text),
        .string => |text| try writeString(out, allocator, text),
        .array, .object => unreachable, // Handled by writeNode.
    }
}

//
// True for a value that is written on the line after its key rather than on the key's own line.
//
fn isBlock(node: Value) bool {
    return switch (node) {
        .array => |array| array.items.len > 0,
        .object => |object| object.count() > 0,
        else => false,
    };
}

//
// Writes any value at the given indentation.
//
// `first_line_written` says the opening of the line is already on the page, which is what a
// sequence item needs: `- ` is printed, and then the item's first key has to land right after it
// rather than on a line of its own.
//
fn writeNode(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node: Value, indent: usize, first_line_written: bool) std.mem.Allocator.Error!void {
    switch (node) {
        .array => |array| {
            if (array.items.len == 0) {
                if (!first_line_written) try writeIndent(out, allocator, indent);
                try out.appendSlice(allocator, "[]");
                return;
            }
            for (array.items, 0..) |item, at| {
                if (at > 0 or !first_line_written) {
                    if (at > 0) try out.append(allocator, '\n');
                    try writeIndent(out, allocator, indent);
                }
                try out.appendSlice(allocator, "- ");
                try writeNode(out, allocator, item, indent + 2, true);
            }
        },
        .object => |object| {
            if (object.count() == 0) {
                if (!first_line_written) try writeIndent(out, allocator, indent);
                try out.appendSlice(allocator, "{}");
                return;
            }
            var at: usize = 0;
            var walker = object.iterator();
            while (walker.next()) |entry| : (at += 1) {
                if (at > 0 or !first_line_written) {
                    if (at > 0) try out.append(allocator, '\n');
                    try writeIndent(out, allocator, indent);
                }
                try writeString(out, allocator, entry.key_ptr.*);
                try out.append(allocator, ':');

                if (isBlock(entry.value_ptr.*)) {
                    try out.append(allocator, '\n');
                    try writeNode(out, allocator, entry.value_ptr.*, indent + 2, false);
                } else {
                    try out.append(allocator, ' ');
                    try writeNode(out, allocator, entry.value_ptr.*, indent, true);
                }
            }
        },
        else => try writeScalar(out, allocator, node),
    }
}

//
// Writes the given number of spaces.
//
fn writeIndent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, indent: usize) std.mem.Allocator.Error!void {
    try out.appendNTimes(allocator, ' ', indent);
}

//
// Renders a value as YAML.
//
// No trailing newline, because the caller prints the result as one line of output and adds its own.
//
pub fn stringify(allocator: std.mem.Allocator, root: Value) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try writeNode(&out, allocator, root, 0, false);
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

//
// Parses text in a test, failing the test with the syntax error's own words if it will not parse.
//
fn parseForTest(allocator: std.mem.Allocator, text: []const u8) !Value {
    var err: ?SyntaxError = null;
    return parse(allocator, text, &err) catch |caught| {
        if (err) |detail| std.debug.print("YAML error: {s} at line {d}\n", .{ detail.message, detail.line });
        return caught;
    };
}

test "isSequenceEntry recognises a dash that starts an item" {
    try testing.expect(isSequenceEntry("- item"));
    try testing.expect(isSequenceEntry("-"));
    try testing.expect(!isSequenceEntry("-5"));
    try testing.expect(!isSequenceEntry("key: value"));
    try testing.expect(!isSequenceEntry(""));
}

test "splitMappingEntry splits on a colon followed by a space or the end of the line" {
    const with_value = splitMappingEntry("name: alpha").?;
    try testing.expectEqualStrings("name", with_value.key);
    try testing.expectEqualStrings("alpha", with_value.rest);

    const without_value = splitMappingEntry("paths:").?;
    try testing.expectEqualStrings("paths", without_value.key);
    try testing.expectEqualStrings("", without_value.rest);

    try testing.expect(splitMappingEntry("just a scalar") == null);
    try testing.expect(splitMappingEntry("https://example.com") == null);
    try testing.expect(splitMappingEntry(": no key") == null);
}

test "splitMappingEntry ignores a colon inside quotes" {
    const entry = splitMappingEntry("\"a: b\": value").?;
    try testing.expectEqualStrings("\"a: b\"", entry.key);
    try testing.expectEqualStrings("value", entry.rest);
}

test "stripComment removes a comment but leaves a hash inside a word" {
    try testing.expectEqualStrings("name: alpha", stripComment("name: alpha # a comment"));
    try testing.expectEqualStrings("", stripComment("# whole line"));
    try testing.expectEqualStrings("name: a#b", stripComment("name: a#b"));
    try testing.expectEqualStrings("name: \"a # b\"", stripComment("name: \"a # b\" # gone"));
    try testing.expectEqualStrings("name: alpha", stripComment("name: alpha   "));
}

test "isNull, isTrue and isFalse read the words YAML gives a meaning to" {
    try testing.expect(isNull(""));
    try testing.expect(isNull("~"));
    try testing.expect(isNull("null"));
    try testing.expect(isNull("NULL"));
    try testing.expect(!isNull("nullish"));

    try testing.expect(isTrue("true"));
    try testing.expect(isTrue("True"));
    try testing.expect(!isTrue("yes"));

    try testing.expect(isFalse("false"));
    try testing.expect(isFalse("FALSE"));
    try testing.expect(!isFalse("no"));
}

test "looksLikeFloat accepts numbers and rejects words" {
    try testing.expect(looksLikeFloat("1.5"));
    try testing.expect(looksLikeFloat("-0.25"));
    try testing.expect(looksLikeFloat("2e10"));
    try testing.expect(looksLikeFloat("2.5E-3"));
    try testing.expect(looksLikeFloat("42"));
    try testing.expect(!looksLikeFloat("inf"));
    try testing.expect(!looksLikeFloat("nan"));
    try testing.expect(!looksLikeFloat("1.2.3"));
    try testing.expect(!looksLikeFloat(""));
    try testing.expect(!looksLikeFloat("1e"));
    try testing.expect(!looksLikeFloat(".md"));
}

test "parse reads the config the project ships with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseForTest(allocator,
        \\always:
        \\  - package.json
        \\  - mise.toml
        \\
        \\ignore:
        \\  - .md
        \\
        \\targets:
        \\  - name: compile
        \\    paths:
        \\      - src
        \\
        \\  - name: perf
        \\    paths:
        \\      - src
        \\      - perf-tests
    );

    const always = value.get(parsed, "always").?.array;
    try testing.expectEqual(@as(usize, 2), always.items.len);
    try testing.expectEqualStrings("package.json", always.items[0].string);

    const ignore = value.get(parsed, "ignore").?.array;
    try testing.expectEqualStrings(".md", ignore.items[0].string);

    const targets = value.get(parsed, "targets").?.array;
    try testing.expectEqual(@as(usize, 2), targets.items.len);
    try testing.expectEqualStrings("compile", value.get(targets.items[0], "name").?.string);
    try testing.expectEqualStrings("src", value.get(targets.items[0], "paths").?.array.items[0].string);
    try testing.expectEqual(@as(usize, 2), value.get(targets.items[1], "paths").?.array.items.len);
}

test "parse reads a sequence written level with its key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(),
        \\targets:
        \\- name: alpha
        \\  paths:
        \\  - src
    );

    const targets = value.get(parsed, "targets").?.array;
    try testing.expectEqualStrings("alpha", value.get(targets.items[0], "name").?.string);
    try testing.expectEqualStrings("src", value.get(targets.items[0], "paths").?.array.items[0].string);
}

test "parse reads flow sequences and mappings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "targets: []\nignore: [.md, .txt]\ntarget: { name: alpha, paths: [src] }");

    try testing.expectEqual(@as(usize, 0), value.get(parsed, "targets").?.array.items.len);
    try testing.expectEqualStrings(".txt", value.get(parsed, "ignore").?.array.items[1].string);

    const target = value.get(parsed, "target").?;
    try testing.expectEqualStrings("alpha", value.get(target, "name").?.string);
    try testing.expectEqualStrings("src", value.get(target, "paths").?.array.items[0].string);
}

test "parse reads scalars as the types YAML gives them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(),
        \\yes: true
        \\no: false
        \\nothing: null
        \\tilde: ~
        \\whole: 42
        \\fraction: 1.5
        \\word: alpha
        \\quoted: "42"
        \\single: 'a b'
        \\empty:
    );

    try testing.expectEqual(true, value.get(parsed, "yes").?.bool);
    try testing.expectEqual(false, value.get(parsed, "no").?.bool);
    try testing.expect(value.get(parsed, "nothing").? == .null);
    try testing.expect(value.get(parsed, "tilde").? == .null);
    try testing.expectEqual(@as(i64, 42), value.get(parsed, "whole").?.integer);
    try testing.expectEqual(@as(f64, 1.5), value.get(parsed, "fraction").?.float);
    try testing.expectEqualStrings("alpha", value.get(parsed, "word").?.string);
    try testing.expectEqualStrings("42", value.get(parsed, "quoted").?.string);
    try testing.expectEqualStrings("a b", value.get(parsed, "single").?.string);
    try testing.expect(value.get(parsed, "empty").? == .null);
}

test "parse reads escapes in a double-quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "text: \"a\\nb\\t\\\"c\\\"\"");
    try testing.expectEqualStrings("a\nb\t\"c\"", value.get(parsed, "text").?.string);
}

test "parse reads a doubled quote inside a single-quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "text: 'it''s here'");
    try testing.expectEqualStrings("it's here", value.get(parsed, "text").?.string);
}

test "parse drops comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(),
        \\# what-changed's own configuration.
        \\
        \\ignore:
        \\  - .md   # markdown never affects a suite
        \\
    );

    try testing.expectEqualStrings(".md", value.get(parsed, "ignore").?.array.items[0].string);
}

test "parse accepts a leading document marker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "---\nname: alpha\n...");
    try testing.expectEqualStrings("alpha", value.get(parsed, "name").?.string);
}

test "parse refuses a misaligned key under a sequence item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?SyntaxError = null;
    try testing.expectError(error.Syntax, parse(arena.allocator(),
        \\targets:
        \\  - name: alpha
        \\   paths: [bad indent]
    , &err));
    try testing.expectEqual(@as(usize, 3), err.?.line);
}

test "parse refuses a tab used for indentation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?SyntaxError = null;
    try testing.expectError(error.Syntax, parse(arena.allocator(), "targets:\n\t- name: alpha", &err));
    try testing.expectEqual(@as(usize, 2), err.?.line);
}

test "parse refuses an unterminated flow sequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?SyntaxError = null;
    try testing.expectError(error.Syntax, parse(arena.allocator(), "ignore: [.md, .txt", &err));
    try testing.expect(err != null);
}

test "parse refuses a second document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?SyntaxError = null;
    try testing.expectError(error.Syntax, parse(arena.allocator(), "name: a\n---\nname: b", &err));
}

test "parse refuses an unsupported YAML feature rather than guessing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?SyntaxError = null;
    try testing.expectError(error.Syntax, parse(arena.allocator(), "base: &anchor\n  name: alpha", &err));
}

test "parse of an empty document is null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var err: ?SyntaxError = null;
    try testing.expect(try parse(arena.allocator(), "", &err) == .null);
    try testing.expect(try parse(arena.allocator(), "\n\n# only a comment\n", &err) == .null);
}

test "parse reads a top-level sequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(), "- one\n- two");
    try testing.expectEqual(@as(usize, 2), parsed.array.items.len);
    try testing.expectEqualStrings("two", parsed.array.items[1].string);
}

test "parse reads a bare dash carrying a nested block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseForTest(arena.allocator(),
        \\targets:
        \\  -
        \\    name: alpha
        \\    paths:
        \\      - src
    );

    const first = value.get(parsed, "targets").?.array.items[0];
    try testing.expectEqualStrings("alpha", value.get(first, "name").?.string);
}

test "parseOrFail names the format and the line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fail = Failure.init(allocator);
    try testing.expectError(error.Failed, parseOrFail(allocator, "targets:\n  - name: alpha\n   paths: [x]\n", "what-changed config", &fail));
    try testing.expect(std.mem.startsWith(u8, fail.text(), "what-changed config is not valid YAML: "));
    try testing.expect(std.mem.indexOf(u8, fail.text(), "line 3") != null);
}

test "needsQuoting quotes only what would read back as something else" {
    try testing.expect(needsQuoting(""));
    try testing.expect(needsQuoting("true"));
    try testing.expect(needsQuoting("null"));
    try testing.expect(needsQuoting("42"));
    try testing.expect(needsQuoting("1.5"));
    try testing.expect(needsQuoting("- leading dash"));
    try testing.expect(needsQuoting("key: value"));
    try testing.expect(needsQuoting("trailing "));
    try testing.expect(needsQuoting("has # comment"));

    try testing.expect(!needsQuoting("alpha"));
    try testing.expect(!needsQuoting(".md"));
    try testing.expect(!needsQuoting("src/a.ts"));
    try testing.expect(!needsQuoting("what-changed.yaml"));
    try testing.expect(!needsQuoting("/tmp/x/.what-changed/baseline.json"));
    try testing.expect(!needsQuoting("5424073a96f9f8a5"));
    try testing.expect(!needsQuoting("a#b"));
}

test "stringify renders a report the way the yaml package does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var change = value.newObject(allocator);
    try change.put(allocator, "path", value.str("src/a.ts"));
    try change.put(allocator, "kind", value.str("added"));
    try change.put(allocator, "previousHash", value.str(""));

    var changed = value.newArray(allocator);
    try changed.append(.{ .object = change });

    var root = value.newObject(allocator);
    try root.put(allocator, "hasBaseline", value.boolean(false));
    try root.put(allocator, "fileCount", value.int(4));
    try root.put(allocator, "changed", .{ .array = changed });

    try testing.expectEqualStrings(
        \\hasBaseline: false
        \\fileCount: 4
        \\changed:
        \\  - path: src/a.ts
        \\    kind: added
        \\    previousHash: ""
    , try stringify(allocator, .{ .object = root }));
}

test "stringify renders a nested sequence inside a sequence item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var watched = value.newArray(allocator);
    try watched.append(value.str("src"));
    try watched.append(value.str("scripts"));

    var target = value.newObject(allocator);
    try target.put(allocator, "name", value.str("unit"));
    try target.put(allocator, "watchedPaths", .{ .array = watched });
    try target.put(allocator, "changed", .{ .array = value.newArray(allocator) });

    var targets = value.newArray(allocator);
    try targets.append(.{ .object = target });

    var root = value.newObject(allocator);
    try root.put(allocator, "targets", .{ .array = targets });

    try testing.expectEqualStrings(
        \\targets:
        \\  - name: unit
        \\    watchedPaths:
        \\      - src
        \\      - scripts
        \\    changed: []
    , try stringify(allocator, .{ .object = root }));
}

test "stringify renders empty collections on one line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = value.newObject(allocator);
    try root.put(allocator, "targets", .{ .array = value.newArray(allocator) });
    try root.put(allocator, "files", .{ .object = value.newObject(allocator) });

    try testing.expectEqualStrings("targets: []\nfiles: {}", try stringify(allocator, .{ .object = root }));
}

test "stringify renders a scalar on its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try testing.expectEqualStrings("alpha", try stringify(allocator, value.str("alpha")));
    try testing.expectEqualStrings("null", try stringify(allocator, .null));
    try testing.expectEqualStrings("7", try stringify(allocator, value.int(7)));
}

test "stringify then parse gives back the same document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var target = value.newObject(allocator);
    try target.put(allocator, "name", value.str("unit"));
    try target.put(allocator, "appliesHere", value.boolean(true));
    try target.put(allocator, "previousHash", value.str(""));

    var targets = value.newArray(allocator);
    try targets.append(.{ .object = target });

    var root = value.newObject(allocator);
    try root.put(allocator, "fileCount", value.int(9));
    try root.put(allocator, "targets", .{ .array = targets });

    const round_tripped = try parseForTest(allocator, try stringify(allocator, .{ .object = root }));

    try testing.expectEqual(@as(i64, 9), value.get(round_tripped, "fileCount").?.integer);
    const first = value.get(round_tripped, "targets").?.array.items[0];
    try testing.expectEqualStrings("unit", value.get(first, "name").?.string);
    try testing.expectEqual(true, value.get(first, "appliesHere").?.bool);
    try testing.expectEqualStrings("", value.get(first, "previousHash").?.string);
}
