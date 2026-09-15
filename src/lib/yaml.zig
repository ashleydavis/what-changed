const std = @import("std");
const annotate_mod = @import("log");

//
// The branch markers a fault run reads back. `an` is a compile-time flag: the binary people run is
// built with it off, so every `if (an) annotate(...)` below compiles to nothing there.
//
const Log = annotate_mod.Log;
const an = annotate_mod.an;
const annotate = annotate_mod.annotate;
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
    // Where this parser's own branch markers go. Carried here rather than passed to each method,
    // because every one of them already has the parser.
    //
    log: Log = .{},

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
        // Every caller hands the error straight back, so nothing parses on after one and there is
        // never a second to drop. Asserted rather than guarded against: a guard here would be a
        // branch nothing can take, and this says the same thing where the language can check it.
        std.debug.assert(self.err == null);
        self.err = .{ .message = message, .line = line, .column = column };
        return error.Syntax;
    }

    //
    // The line the parser is looking at, or null at the end of the input.
    //
    fn peek(self: *const Parser) ?Line {
        if (self.index >= self.lines.len) {
            if (an) annotate(self.log, "peek-end-of-input", "", .{});
            return null;
        }
        return self.lines[self.index];
    }

    //
    // Parses whatever block starts at the current line, at the given indentation.
    //
    // A block is a sequence when its first line begins with a dash, and a mapping otherwise. That
    // is the whole of YAML's block-level structure, and it is decided per block rather than once
    // for the document, which is what lets a mapping hold sequences and vice versa.
    //
    fn parseBlock(self: *Parser, indent: usize, log: Log) Error!Value {
        // Every caller has already read the line this starts at: `parse` checks the document holds
        // one, and both block parsers peek before descending.
        const line = self.peek() orelse unreachable;
        if (isSequenceEntry(line.content, self.log)) {
            if (an) annotate(self.log, "parseBlock-a-sequence", "", .{});
            return self.parseSequence(indent, log);
        }
        return self.parseMapping(indent, log);
    }

    //
    // Parses consecutive `- item` lines at one indentation into an array.
    //
    fn parseSequence(self: *Parser, indent: usize, log: Log) Error!Value {
        var array = value.newArray(self.allocator);

        while (true) {
            if (an) annotate(self.log, "parseSequence-items-iteration", "", .{});
            const line = self.peek() orelse {
                if (an) annotate(self.log, "parseSequence-end-of-input", "", .{});
                break;
            };
            if (line.indent != indent or !isSequenceEntry(line.content, self.log)) {
                if (an) annotate(self.log, "parseSequence-end-of-block", "", .{});
                break;
            }

            //
            // Everything after the dash and the spaces following it. Its column matters: a mapping
            // written on the same line as the dash starts a block whose indentation is that column,
            // not the dash's, which is how `- name: x` followed by an aligned `paths:` works.
            //
            const after_dash = std.mem.trimStart(u8, line.content[1..], " ");
            const item_column = line.indent + (line.content.len - after_dash.len);

            if (after_dash.len == 0) {
                if (an) annotate(self.log, "parseSequence-bare-dash", "", .{});
                //
                // A bare dash: the item is whatever block is indented under it.
                //
                self.index += 1;
                try array.append(try self.parseIndentedBlock(line.indent, log));
            } else if (splitMappingEntry(after_dash, self.log) != null or isSequenceEntry(after_dash, self.log)) {
                if (an) annotate(self.log, "parseSequence-block-on-the-dash", "", .{});
                //
                // A block starting on the dash's own line. Rewriting the line as if it had been
                // written at its real column, without the dash, is what lets the block parsers read
                // the following lines: those are indented to line up with this content, not with
                // the dash, so measuring this line by its dash would make every one of them look
                // over-indented.
                //
                self.lines[self.index] = .{ .indent = item_column, .content = after_dash, .number = line.number };
                try array.append(try self.parseBlock(item_column, log));
            } else {
                if (an) annotate(self.log, "parseSequence-plain-item", "", .{});
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
    fn parseMapping(self: *Parser, indent: usize, log: Log) Error!Value {
        var object: value.Object = .empty;

        while (true) {
            if (an) annotate(self.log, "parseMapping-entries-iteration", "", .{});
            const line = self.peek() orelse {
                if (an) annotate(self.log, "parseMapping-end-of-input", "", .{});
                break;
            };
            if (line.indent != indent or isSequenceEntry(line.content, self.log)) {
                if (an) annotate(self.log, "parseMapping-end-of-block", "", .{});
                break;
            }

            const entry = splitMappingEntry(line.content, self.log) orelse {
                if (an) annotate(self.log, "parseMapping-not-a-pair", "", .{});
                return self.syntax(line.number, line.indent + 1, "expected a \"key: value\" pair");
            };

            const key = try self.parseKey(entry.key, line.number, line.indent + 1);

            if (entry.rest.len == 0) {
                if (an) annotate(self.log, "parseMapping-value-is-below", "", .{});
                //
                // Nothing after the colon, so the value is the block underneath.
                //
                self.index += 1;
                try object.put(self.allocator, key, try self.parseIndentedBlock(indent, log));
            } else {
                if (an) annotate(self.log, "parseMapping-value-is-here", "", .{});
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
    fn parseIndentedBlock(self: *Parser, owner_indent: usize, log: Log) Error!Value {
        const line = self.peek() orelse {
            if (an) annotate(self.log, "parseIndentedBlock-nothing-below", "", .{});
            return .null;
        };

        if (line.indent > owner_indent) {
            if (an) annotate(self.log, "parseIndentedBlock-deeper", "", .{});
            return self.parseBlock(line.indent, log);
        }
        if (line.indent == owner_indent and isSequenceEntry(line.content, self.log)) {
            if (an) annotate(self.log, "parseIndentedBlock-level-sequence", "", .{});
            return self.parseSequence(owner_indent, log);
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
        const line = self.peek() orelse {
            if (an) annotate(self.log, "rejectDanglingIndent-end-of-input", "", .{});
            return;
        };
        if (line.indent > indent) {
            if (an) annotate(self.log, "rejectDanglingIndent-dangling", "", .{});
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
        // A mapping entry with nothing after its colon and a sequence item with nothing after its
        // dash are both handled by the caller, so what arrives here always says something.
        std.debug.assert(trimmed.len != 0);

        switch (trimmed[0]) {
            '[', '{' => {
                if (an) annotate(self.log, "parseScalar-flow-collection", "", .{});
                var flow = Flow{ .parser = self, .text = trimmed, .line = line, .column = column };
                const parsed = try flow.parseValue();
                flow.skipSpaces();
                if (flow.at < flow.text.len) {
                    if (an) annotate(self.log, "parseScalar-trailing-text", "", .{});
                    return self.syntax(line, column + flow.at, "unexpected text after the end of the value");
                }
                return parsed;
            },
            '"', '\'' => {
                if (an) annotate(self.log, "parseScalar-quoted", "", .{});
                var flow = Flow{ .parser = self, .text = trimmed, .line = line, .column = column };
                const parsed = try flow.parseQuoted();
                flow.skipSpaces();
                if (flow.at < flow.text.len) {
                    if (an) annotate(self.log, "parseScalar-trailing-text-after-quotes", "", .{});
                    return self.syntax(line, column + flow.at, "unexpected text after the end of the quoted value");
                }
                return parsed;
            },
            '&', '*', '!', '|', '>', '%', '@', '`' => {
                if (an) annotate(self.log, "parseScalar-unsupported-feature", "", .{});
                return self.syntax(line, column, "this YAML feature is not supported by what-changed");
            },
            else => {
                if (an) annotate(self.log, "parseScalar-plain", "", .{});
                return try self.plainScalar(trimmed);
            },
        }
    }

    //
    // Turns an unquoted scalar into a value, recognising the handful of words and number formats
    // YAML gives a meaning to and treating everything else as a string.
    //
    fn plainScalar(self: *Parser, text: []const u8) Error!Value {
        if (isNull(text)) {
            if (an) annotate(self.log, "plainScalar-null", "", .{});
            return .null;
        }
        if (isTrue(text)) {
            if (an) annotate(self.log, "plainScalar-true", "", .{});
            return value.boolean(true);
        }
        if (isFalse(text)) {
            if (an) annotate(self.log, "plainScalar-false", "", .{});
            return value.boolean(false);
        }

        if (std.fmt.parseInt(i64, text, 10)) |whole| {
            if (an) annotate(self.log, "plainScalar-whole-number", "", .{});
            return value.int(whole);
        } else |_| {
            if (an) annotate(self.log, "plainScalar-not-a-whole-number", "", .{});
        }

        if (looksLikeFloat(text, self.log)) {
            if (an) annotate(self.log, "plainScalar-looks-like-a-float", "", .{});
            // A sign, digits, at most one dot and a whole exponent is exactly what the float parser
            // reads, so it cannot refuse what the check above accepted.
            const number = std.fmt.parseFloat(f64, text) catch unreachable;
            return .{ .float = number };
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
            if (an) annotate(self.parser.log, "skipSpaces-spaces-iteration", "", .{});
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
        if (self.at >= self.text.len) {
            if (an) annotate(self.parser.log, "parseValue-nothing-there", "", .{});
            return self.fail("expected a value");
        }

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
            if (an) annotate(self.parser.log, "parseSequence-empty", "", .{});
            self.at += 1;
            return .{ .array = array };
        }

        while (true) {
            if (an) annotate(self.parser.log, "parseSequence-items-iteration", "", .{});
            try array.append(try self.parseValue());
            self.skipSpaces();
            if (self.at >= self.text.len) {
                if (an) annotate(self.parser.log, "parseSequence-unclosed", "", .{});
                return self.fail("this list is missing its closing \"]\"");
            }
            switch (self.text[self.at]) {
                ',' => {
                    if (an) annotate(self.parser.log, "parseSequence-comma", "", .{});
                    self.at += 1;
                },
                ']' => {
                    if (an) annotate(self.parser.log, "parseSequence-closed", "", .{});
                    self.at += 1;
                    return .{ .array = array };
                },
                else => {
                    if (an) annotate(self.parser.log, "parseSequence-unexpected", "", .{});
                    return self.fail("expected a \",\" or a \"]\" in this list");
                },
            }
        }
    }

    //
    // Parses `{ key: value, other: value }`.
    //
    fn parseMapping(self: *Flow) Parser.Error!Value {
        self.at += 1; // The opening brace.
        var object: value.Object = .empty;

        self.skipSpaces();
        if (self.at < self.text.len and self.text[self.at] == '}') {
            if (an) annotate(self.parser.log, "parseMapping-empty", "", .{});
            self.at += 1;
            return .{ .object = object };
        }

        while (true) {
            if (an) annotate(self.parser.log, "parseMapping-entries-iteration", "", .{});
            self.skipSpaces();
            const key = try self.parseValue();
            if (key != .string) {
                if (an) annotate(self.parser.log, "parseMapping-key-is-not-a-string", "", .{});
                return self.fail("a mapping key must be a plain or quoted string");
            }

            self.skipSpaces();
            if (self.at >= self.text.len or self.text[self.at] != ':') {
                if (an) annotate(self.parser.log, "parseMapping-no-colon", "", .{});
                return self.fail("expected a \":\" after this key");
            }
            self.at += 1;

            try object.put(self.parser.allocator, key.string, try self.parseValue());

            self.skipSpaces();
            if (self.at >= self.text.len) {
                if (an) annotate(self.parser.log, "parseMapping-unclosed", "", .{});
                return self.fail("this mapping is missing its closing \"}\"");
            }
            switch (self.text[self.at]) {
                ',' => {
                    if (an) annotate(self.parser.log, "parseMapping-comma", "", .{});
                    self.at += 1;
                },
                '}' => {
                    if (an) annotate(self.parser.log, "parseMapping-closed", "", .{});
                    self.at += 1;
                    return .{ .object = object };
                },
                else => {
                    if (an) annotate(self.parser.log, "parseMapping-unexpected", "", .{});
                    return self.fail("expected a \",\" or a \"}\" in this mapping");
                },
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
            if (an) annotate(self.parser.log, "parseQuoted-characters-iteration", "", .{});
            const character = self.text[self.at];

            if (character == quote) {
                if (an) annotate(self.parser.log, "parseQuoted-a-quote", "", .{});
                if (quote == '\'' and self.at + 1 < self.text.len and self.text[self.at + 1] == '\'') {
                    if (an) annotate(self.parser.log, "parseQuoted-doubled-quote", "", .{});
                    try out.append(self.parser.allocator, '\'');
                    self.at += 2;
                    continue;
                }
                self.at += 1;
                return value.str(try out.toOwnedSlice(self.parser.allocator));
            }

            if (quote == '"' and character == '\\') {
                if (an) annotate(self.parser.log, "parseQuoted-an-escape", "", .{});
                self.at += 1;
                if (self.at >= self.text.len) {
                    if (an) annotate(self.parser.log, "parseQuoted-ends-in-a-backslash", "", .{});
                    return self.fail("this string ends in a backslash");
                }
                try out.append(self.parser.allocator, switch (self.text[self.at]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    '\\' => '\\',
                    '"' => '"',
                    '/' => '/',
                    else => {
                        if (an) annotate(self.parser.log, "parseQuoted-unsupported-escape", "", .{});
                        return self.fail("unsupported escape in this string");
                    },
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
        while (true) {
            if (an) annotate(self.parser.log, "parsePlain-characters-iteration", "", .{});
            if (self.at >= self.text.len) {
                if (an) annotate(self.parser.log, "parsePlain-end-of-text", "", .{});
                break;
            }
            switch (self.text[self.at]) {
                ',', ']', '}', ':' => {
                    if (an) annotate(self.parser.log, "parsePlain-end-of-value", "", .{});
                    break;
                },
                else => {
                    if (an) annotate(self.parser.log, "parsePlain-another-character", "", .{});
                    self.at += 1;
                },
            }
        }
        const text = std.mem.trim(u8, self.text[start..self.at], " ");
        if (text.len == 0) {
            if (an) annotate(self.parser.log, "parsePlain-nothing-there", "", .{});
            return self.fail("expected a value");
        }
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
pub fn splitMappingEntry(content: []const u8, log: Log) ?MappingEntry {
    var quote: ?u8 = null;
    var at: usize = 0;

    while (at < content.len) : (at += 1) {
        if (an) annotate(log, "splitMappingEntry-characters-iteration", "", .{});
        const character = content[at];

        if (quote) |open| {
            if (an) annotate(log, "splitMappingEntry-inside-quotes", "", .{});
            if (character == open) {
                if (an) annotate(log, "splitMappingEntry-quotes-closed", "", .{});
                quote = null;
            }
            continue;
        }
        if (character == '"' or character == '\'') {
            if (an) annotate(log, "splitMappingEntry-quotes-opened", "", .{});
            quote = character;
            continue;
        }
        if (character == ':' and (at + 1 == content.len or content[at + 1] == ' ')) {
            if (an) annotate(log, "splitMappingEntry-a-colon", "", .{});
            const key = std.mem.trim(u8, content[0..at], " ");
            if (key.len == 0) {
                if (an) annotate(log, "splitMappingEntry-no-key", "", .{});
                return null;
            }
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
pub fn isSequenceEntry(content: []const u8, log: Log) bool {
    if (content.len == 0 or content[0] != '-') {
        if (an) annotate(log, "isSequenceEntry-no-dash", "", .{});
        return false;
    }
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
pub fn looksLikeFloat(text: []const u8, log: Log) bool {
    var at: usize = 0;
    if (at < text.len and (text[at] == '+' or text[at] == '-')) {
        if (an) annotate(log, "looksLikeFloat-signed", "", .{});
        at += 1;
    }

    var digits: usize = 0;
    var dots: usize = 0;
    while (at < text.len) : (at += 1) {
        if (an) annotate(log, "looksLikeFloat-characters-iteration", "", .{});
        switch (text[at]) {
            '0'...'9' => {
                if (an) annotate(log, "looksLikeFloat-a-digit", "", .{});
                digits += 1;
            },
            '.' => {
                if (an) annotate(log, "looksLikeFloat-a-dot", "", .{});
                dots += 1;
            },
            'e', 'E' => {
                if (an) annotate(log, "looksLikeFloat-an-exponent", "", .{});
                //
                // An exponent has to come after some digits and be a whole number itself.
                //
                if (digits == 0 or at + 1 >= text.len) {
                    if (an) annotate(log, "looksLikeFloat-exponent-with-nothing-around-it", "", .{});
                    return false;
                }
                var exponent = at + 1;
                if (text[exponent] == '+' or text[exponent] == '-') {
                    if (an) annotate(log, "looksLikeFloat-signed-exponent", "", .{});
                    exponent += 1;
                }
                if (exponent >= text.len) {
                    if (an) annotate(log, "looksLikeFloat-nothing-after-the-sign", "", .{});
                    return false;
                }
                while (exponent < text.len) : (exponent += 1) {
                    if (an) annotate(log, "looksLikeFloat-exponent-digits-iteration", "", .{});
                    if (!std.ascii.isDigit(text[exponent])) {
                        if (an) annotate(log, "looksLikeFloat-exponent-is-not-whole", "", .{});
                        return false;
                    }
                }
                return dots <= 1;
            },
            else => {
                if (an) annotate(log, "looksLikeFloat-not-a-number-at-all", "", .{});
                return false;
            },
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
pub fn stripComment(content: []const u8, log: Log) []const u8 {
    var quote: ?u8 = null;
    var at: usize = 0;

    while (at < content.len) : (at += 1) {
        if (an) annotate(log, "stripComment-characters-iteration", "", .{});
        const character = content[at];

        if (quote) |open| {
            if (an) annotate(log, "stripComment-inside-quotes", "", .{});
            if (character == open) {
                if (an) annotate(log, "stripComment-quotes-closed", "", .{});
                quote = null;
            }
            continue;
        }
        if (character == '"' or character == '\'') {
            if (an) annotate(log, "stripComment-quotes-opened", "", .{});
            quote = character;
            continue;
        }
        if (character == '#' and (at == 0 or content[at - 1] == ' ' or content[at - 1] == '\t')) {
            if (an) annotate(log, "stripComment-a-comment", "", .{});
            return std.mem.trimEnd(u8, content[0..at], " \t");
        }
    }

    return std.mem.trimEnd(u8, content, " \t");
}

//
// Splits the text into the lines the parser walks, dropping blanks and comments and measuring each
// remaining line's indentation.
//
fn readLines(allocator: std.mem.Allocator, text: []const u8, err: *?SyntaxError, log: Log) error{ Syntax, OutOfMemory }![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    var number: usize = 0;
    var walker = std.mem.splitScalar(u8, text, '\n');
    while (walker.next()) |raw_line| {
        if (an) annotate(log, "readLines-lines-iteration", "", .{});
        number += 1;
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') {
            if (an) annotate(log, "readLines-indent-iteration", "", .{});
            indent += 1;
        }

        //
        // A tab in the indentation is refused rather than counted. YAML forbids it, and guessing a
        // width for it would mean this tool and every editor disagreeing about what the file says.
        //
        if (indent < line.len and line[indent] == '\t') {
            if (an) annotate(log, "readLines-a-tab", "", .{});
            err.* = .{ .message = "a tab is used for indentation, which YAML does not allow", .line = number, .column = indent + 1 };
            return error.Syntax;
        }

        const content = stripComment(line[indent..], log);
        if (content.len == 0) {
            if (an) annotate(log, "readLines-a-blank-line", "", .{});
            continue;
        }

        //
        // The document markers are accepted and dropped, so a config that starts with "---" reads
        // the same as one that does not. A second document is refused: this tool reads one config,
        // and quietly using the first of several would hide the rest.
        //
        if (std.mem.eql(u8, content, "...")) {
            if (an) annotate(log, "readLines-end-of-document", "", .{});
            continue;
        }
        if (std.mem.eql(u8, content, "---")) {
            if (an) annotate(log, "readLines-start-of-document", "", .{});
            if (lines.items.len > 0) {
                if (an) annotate(log, "readLines-a-second-document", "", .{});
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
pub fn parse(allocator: std.mem.Allocator, text: []const u8, err: *?SyntaxError, log: Log) error{ Syntax, OutOfMemory }!Value {
    const lines = try readLines(allocator, text, err, log);
    if (lines.len == 0) {
        if (an) annotate(log, "parse-an-empty-document", "", .{});
        return .null;
    }

    var parser = Parser{ .allocator = allocator, .lines = lines, .log = log };
    const parsed = parser.parseBlock(lines[0].indent, log) catch |caught| switch (caught) {
        error.OutOfMemory => {
            if (an) annotate(log, "parse-no-room", "", .{});
            return error.OutOfMemory;
        },
        error.Syntax => {
            if (an) annotate(log, "parse-a-syntax-error", "", .{});
            err.* = parser.err;
            return error.Syntax;
        },
    };

    //
    // Anything left over means the document does not hang together: a line the structure above it
    // could not account for. Reported rather than ignored, for the same reason a misaligned key is.
    //
    if (parser.peek()) |line| {
        if (an) annotate(log, "parse-a-line-left-over", "", .{});
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
    return parse(allocator, text, &err, fail.log) catch |caught| switch (caught) {
        error.OutOfMemory => error.OutOfMemory,
        error.Syntax => {
            if (an) annotate(fail.log, "parseOrFail-a-syntax-error", "", .{});
            // Every refusal is recorded with the line and column it happened at, both in
            // `readLines` and in the parser, so one always arrives here.
            const detail = err orelse unreachable;
            return fail.set("{s} is not valid YAML: {s} at line {d}, column {d}", .{
                description, detail.message, detail.line, detail.column,
            });
        },
    };
}

//
// True when a string has to be quoted to survive a round trip through YAML.
//
// Erring towards quoting is safe: a quoted string always reads back as itself. Erring the other way
// is not, because a plain `true`, `1.5` or empty string reads back as something else entirely.
//
pub fn needsQuoting(text: []const u8, log: Log) bool {
    if (text.len == 0) {
        if (an) annotate(log, "needsQuoting-empty", "", .{});
        return true;
    }
    if (isNull(text) or isTrue(text) or isFalse(text)) {
        if (an) annotate(log, "needsQuoting-a-yaml-word", "", .{});
        return true;
    }
    if (std.fmt.parseInt(i64, text, 10)) |_| {
        if (an) annotate(log, "needsQuoting-a-whole-number", "", .{});
        return true;
    } else |_| {
        if (an) annotate(log, "needsQuoting-not-a-whole-number", "", .{});
    }
    if (looksLikeFloat(text, log)) {
        if (an) annotate(log, "needsQuoting-a-float", "", .{});
        return true;
    }

    //
    // Leading or trailing whitespace does not survive plain style, since the reader trims it.
    //
    if (text[0] == ' ' or text[text.len - 1] == ' ') {
        if (an) annotate(log, "needsQuoting-padded", "", .{});
        return true;
    }

    //
    // An indicator at the start of a scalar means something to YAML.
    //
    switch (text[0]) {
        '-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => {
            if (an) annotate(log, "needsQuoting-starts-with-an-indicator", "", .{});
            return true;
        },
        else => {
            if (an) annotate(log, "needsQuoting-starts-with-an-ordinary-character", "", .{});
        },
    }

    //
    // Inside the text, only the sequences that would end the scalar or start a comment matter.
    //
    for (text, 0..) |character, at| {
        if (an) annotate(log, "needsQuoting-characters-iteration", "", .{});
        switch (character) {
            '\n', '\r', '\t' => {
                if (an) annotate(log, "needsQuoting-whitespace-inside", "", .{});
                return true;
            },
            ':' => {
                if (an) annotate(log, "needsQuoting-a-colon", "", .{});
                if (at + 1 == text.len or text[at + 1] == ' ') {
                    if (an) annotate(log, "needsQuoting-a-colon-that-ends-the-key", "", .{});
                    return true;
                }
            },
            '#' => {
                if (an) annotate(log, "needsQuoting-a-hash", "", .{});
                if (at > 0 and text[at - 1] == ' ') {
                    if (an) annotate(log, "needsQuoting-a-hash-that-starts-a-comment", "", .{});
                    return true;
                }
            },
            else => {
                if (an) annotate(log, "needsQuoting-an-ordinary-character", "", .{});
            },
        }
    }

    return false;
}

//
// Writes a string as YAML, quoting it only when it would not read back as itself.
//
fn writeString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, log: Log) std.mem.Allocator.Error!void {
    if (!needsQuoting(text, log)) {
        if (an) annotate(log, "writeString-plain", "", .{});
        return out.appendSlice(allocator, text);
    }

    try out.append(allocator, '"');
    for (text) |character| {
        if (an) annotate(log, "writeString-characters-iteration", "", .{});
        switch (character) {
            '"' => {
                if (an) annotate(log, "writeString-a-quote", "", .{});
                try out.appendSlice(allocator, "\\\"");
            },
            '\\' => {
                if (an) annotate(log, "writeString-a-backslash", "", .{});
                try out.appendSlice(allocator, "\\\\");
            },
            '\n' => {
                if (an) annotate(log, "writeString-a-newline", "", .{});
                try out.appendSlice(allocator, "\\n");
            },
            '\r' => {
                if (an) annotate(log, "writeString-a-carriage-return", "", .{});
                try out.appendSlice(allocator, "\\r");
            },
            '\t' => {
                if (an) annotate(log, "writeString-a-tab", "", .{});
                try out.appendSlice(allocator, "\\t");
            },
            else => {
                if (an) annotate(log, "writeString-an-ordinary-character", "", .{});
                try out.append(allocator, character);
            },
        }
    }
    try out.append(allocator, '"');
}

//
// Writes a scalar: anything that is not an array or an object.
//
fn writeScalar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node: Value, log: Log) std.mem.Allocator.Error!void {
    switch (node) {
        .null => {
            if (an) annotate(log, "writeScalar-null", "", .{});
            try out.appendSlice(allocator, "null");
        },
        .bool => |flag| {
            if (an) annotate(log, "writeScalar-a-bool", "", .{});
            try out.appendSlice(allocator, if (flag) "true" else "false");
        },
        .integer => |whole| {
            if (an) annotate(log, "writeScalar-a-whole-number", "", .{});
            try out.print(allocator, "{d}", .{whole});
        },
        .float => |number| {
            if (an) annotate(log, "writeScalar-a-float", "", .{});
            try out.print(allocator, "{d}", .{number});
        },
        .number_string => |text| {
            if (an) annotate(log, "writeScalar-a-number-as-text", "", .{});
            try out.appendSlice(allocator, text);
        },
        .string => |text| {
            if (an) annotate(log, "writeScalar-a-string", "", .{});
            try writeString(out, allocator, text, log);
        },
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
fn writeNode(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node: Value, indent: usize, first_line_written: bool, log: Log) std.mem.Allocator.Error!void {
    switch (node) {
        .array => |array| {
            if (an) annotate(log, "writeNode-an-array", "", .{});
            if (array.items.len == 0) {
                if (an) annotate(log, "writeNode-an-empty-array", "", .{});
                if (!first_line_written) {
                    if (an) annotate(log, "writeNode-empty-array-on-its-own-line", "", .{});
                    try writeIndent(out, allocator, indent);
                }
                try out.appendSlice(allocator, "[]");
                return;
            }
            for (array.items, 0..) |item, at| {
                if (an) annotate(log, "writeNode-items-iteration", "", .{});
                if (at > 0 or !first_line_written) {
                    if (an) annotate(log, "writeNode-item-on-its-own-line", "", .{});
                    if (at > 0) {
                        if (an) annotate(log, "writeNode-a-later-item", "", .{});
                        try out.append(allocator, '\n');
                    }
                    try writeIndent(out, allocator, indent);
                }
                try out.appendSlice(allocator, "- ");
                try writeNode(out, allocator, item, indent + 2, true, log);
            }
        },
        .object => |object| {
            if (an) annotate(log, "writeNode-an-object", "", .{});
            if (object.count() == 0) {
                if (an) annotate(log, "writeNode-an-empty-object", "", .{});
                if (!first_line_written) {
                    if (an) annotate(log, "writeNode-empty-object-on-its-own-line", "", .{});
                    try writeIndent(out, allocator, indent);
                }
                try out.appendSlice(allocator, "{}");
                return;
            }
            var at: usize = 0;
            var walker = object.iterator();
            while (walker.next()) |entry| : (at += 1) {
                if (an) annotate(log, "writeNode-entries-iteration", "", .{});
                if (at > 0 or !first_line_written) {
                    if (an) annotate(log, "writeNode-entry-on-its-own-line", "", .{});
                    if (at > 0) {
                        if (an) annotate(log, "writeNode-a-later-entry", "", .{});
                        try out.append(allocator, '\n');
                    }
                    try writeIndent(out, allocator, indent);
                }
                try writeString(out, allocator, entry.key_ptr.*, log);
                try out.append(allocator, ':');

                if (isBlock(entry.value_ptr.*)) {
                    if (an) annotate(log, "writeNode-value-is-a-block", "", .{});
                    try out.append(allocator, '\n');
                    try writeNode(out, allocator, entry.value_ptr.*, indent + 2, false, log);
                } else {
                    if (an) annotate(log, "writeNode-value-is-on-this-line", "", .{});
                    try out.append(allocator, ' ');
                    try writeNode(out, allocator, entry.value_ptr.*, indent, true, log);
                }
            }
        },
        else => {
            if (an) annotate(log, "writeNode-a-scalar", "", .{});
            try writeScalar(out, allocator, node, log);
        },
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
pub fn stringify(allocator: std.mem.Allocator, root: Value, log: Log) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try writeNode(&out, allocator, root, 0, false, log);
    return out.toOwnedSlice(allocator);
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change
    // to the code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("yaml.test.zig");
}
