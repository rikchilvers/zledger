const std = @import("std");

const transaction_indentation: usize = 2;
const max_spaces_in_identifier: usize = 2;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const keywords = std.ComptimeStringMap(Tag, .{
        .{ "account", .keyword_account },
        .{ "apply", .keyword_partial },
        .{ "apply account", .keyword_apply_account },
        .{ "apply tag", .keyword_apply_tag },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const Tag = enum {
        indentation,
        comment,
        date,
        identifier, // payee, account
        status,
        commodity,
        amount,
        keyword_account,
        keyword_partial,
        keyword_apply_account,
        keyword_apply_tag,
        invalid,
        eof,
    };

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub fn debug(self: Token, source: [:0]const u8) void {
        std.log.info("{s}: '{s}'", .{ self.tag, source[self.loc.start..self.loc.end] });
    }
};

pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,
    // FIXME: do we need this?
    pending_invalid_token: ?Token,
    last_newline: ?usize,

    pub fn init(buffer: [:0]const u8) Tokenizer {
        // Skip the UTF-8 BOM if present
        const src_start = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else @as(usize, 0);
        return Tokenizer{
            .buffer = buffer,
            .index = src_start,
            .pending_invalid_token = null,
            .last_newline = null,
        };
    }

    const State = enum {
        start,
        whitespace,
        comment, // both file and transaction level
        date,
        identifier, // payee, account, keywords
        status, // pending or cleared
        commodity,
        amount,
    };

    pub fn next(self: *Tokenizer) Token {
        if (self.pending_invalid_token) |token| {
            self.pending_invalid_token = null;
            return token;
        }
        var state: State = .start;
        var result = Token{
            .tag = .eof,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };

        var seen_spaces: usize = 0;
        while (true) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    0 => break,

                    '\n', '\r' => {
                        self.last_newline = self.index;
                        seen_spaces = 0;
                        result.loc.start = self.index + 1;
                    },

                    ' ', '\t' => {
                        seen_spaces += if (c == ' ') 1 else transaction_indentation;
                        state = .whitespace;
                    },

                    ';', '#' => {
                        state = .comment;
                        result.tag = .comment;
                        result.loc.start = self.index + 1;
                    },

                    '+', '-' => {
                        state = .amount;
                        result.tag = .amount;
                        result.loc.start = self.index;
                    },

                    '0'...'9' => {
                        // are we at the start of a line?
                        if (self.index == 0 or (self.index > 0 and (self.buffer[self.index - 1] == '\n' or self.buffer[self.index - 1] == 'r'))) {
                            state = .date;
                            result.tag = .date;
                        } else {
                            state = .amount;
                            result.tag = .amount;
                        }

                        result.loc.start = self.index;
                    },

                    '!', '*' => {
                        state = .status;
                        result.tag = .status;
                        result.loc.start = self.index;
                    },

                    else => {
                        state = .identifier;
                        result.tag = .identifier;
                        result.loc.start = self.index;
                        seen_spaces = 0;
                    },
                },

                .whitespace => switch (c) {
                    ' ', '\t' => {
                        seen_spaces += if (c == ' ') 1 else transaction_indentation;
                    },
                    else => {
                        const from_beginning = self.index <= (self.last_newline orelse 0) + seen_spaces + 1;
                        if (from_beginning) {
                            if (seen_spaces >= transaction_indentation) {
                                result.tag = .indentation;
                                break;
                            }
                        }

                        seen_spaces = 0;
                        self.index -= 1;
                        state = .start;
                    },
                },

                .amount => switch (c) {
                    '0'...'9', '.', ',' => {},
                    else => break,
                },

                .status => switch (c) {
                    ' ', '\t', '\n', '\r' => break,
                    else => {
                        state = .identifier;
                        result.tag = .identifier;
                    },
                },

                .comment => switch (c) {
                    '\n', '\r' => break,
                    else => {
                        if (self.index == self.buffer.len) break;
                    },
                },

                .date => switch (c) {
                    '/', '-', '.', '0'...'9' => {},
                    ' ', '\t', '\n', '\r', 0 => break,
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .identifier => switch (c) {
                    0, '0'...'9', '\n', '\r' => break,
                    ' ', '\t' => {
                        // this could be a keyword if it begins at the start of the line
                        const from_beginning = blk: {
                            if (result.loc.start == 0) break :blk true;
                            break :blk self.buffer[result.loc.start - 1] == '\n' or self.buffer[result.loc.start - 1] == '\r';
                        };
                        if (from_beginning) {
                            if (Token.getKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                                if (tag == .keyword_partial) continue;
                                result.tag = tag;
                            } else {
                                result.tag = .invalid;
                            }
                            break;
                        }

                        seen_spaces += if (c == ' ') 1 else transaction_indentation;
                        if (seen_spaces >= max_spaces_in_identifier) {
                            self.index -= 1;
                            break;
                        }
                    },
                    ';', '#' => {
                        if (seen_spaces >= max_spaces_in_identifier) {
                            // need to return the identifier and move into the comment
                            // so we backtrack to catch the comment opener
                            self.index -= 1;
                            break;
                        }
                    },
                    else => seen_spaces = 0,
                },

                else => {
                    result.tag = .invalid;
                    result.loc.end = self.index;
                    self.index += 1;
                    return result;
                },
            }
        }

        if (result.tag == .eof) {
            // FIXME: we're not using this - should it be removed?
            if (self.pending_invalid_token) |token| {
                self.pending_invalid_token = null;
                return token;
            }
            result.loc.start = self.index;
        }

        // invalid tags run until the next double space or newline
        if (result.tag == .invalid) {
            while (true) : (self.index += 1) {
                const c = self.buffer[self.index];
                seen_spaces = 0;
                switch (c) {
                    '\n', '\r', 0 => break,
                    '\t' => seen_spaces += transaction_indentation,
                    ' ' => seen_spaces += 1,
                    else => {},
                }
                if (seen_spaces >= 2) {
                    break;
                }
            }
        }

        result.loc.end = self.index;
        return result;
    }
};

fn testTokenize(source: [:0]const u8, expected_tokens: []const Token.Tag) !void {
    var tokenizer = Tokenizer.init(source);
    for (expected_tokens) |expected_token_id| {
        const token = tokenizer.next();
        token.debug(source);
        if (token.tag != expected_token_id) {
            std.debug.panic("expected {s}, found {s}\n", .{
                @tagName(expected_token_id), @tagName(token.tag),
            });
        }
    }
    const last_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.eof, last_token.tag);
    try std.testing.expectEqual(source.len, last_token.loc.start);
}

test "keywords" {
    try testTokenize(" \naccount a:b:c", &.{ .keyword_account, .identifier });
    try testTokenize("apply tag abc\n", &.{ .keyword_apply_tag, .identifier });
    try testTokenize("apply account abc\n", &.{ .keyword_apply_account, .identifier });
}

test "dates" {
    try testTokenize("2021-02-03", &.{.date});
    try testTokenize("2021a02-03", &.{.invalid});
}

test "statuses" {
    try testTokenize("2020 ! abc", &.{ .date, .status, .identifier });
    try testTokenize("2020-01 * abc", &.{ .date, .status, .identifier });
    try testTokenize("2020-01 *abc", &.{ .date, .identifier });
}

test "indentations and identifiers" {
    try testTokenize("  abc", &.{ .indentation, .identifier });
    try testTokenize("\txyz", &.{ .indentation, .identifier });
    try testTokenize(" \n    abc def", &.{ .indentation, .identifier });
    try testTokenize(" \n\txyz", &.{ .indentation, .identifier });
}

test "comments" {
    try testTokenize("; hi", &.{.comment});
    try testTokenize("2020 abc  ; xyz", &.{ .date, .identifier, .comment });
    try testTokenize("\t ; xyz", &.{ .indentation, .comment });
}

test "commodities" {
    try testTokenize("\tabc:def    £10.00", &.{ .indentation, .identifier, .identifier, .amount });
    try testTokenize("\tabc:def    USD 10.00", &.{ .indentation, .identifier, .identifier, .amount });
    try testTokenize("\tabc:def    10.00€", &.{ .indentation, .identifier, .amount, .identifier });
    try testTokenize("\tabc:def    10.00 EUR", &.{ .indentation, .identifier, .amount, .identifier });
}

test "amounts" {
    try testTokenize("\tabc:def    10", &.{ .indentation, .identifier, .amount });
}

test "transactions" {
    try testTokenize(
        \\2020 abc
        \\    d:e
        \\    x:y
    , &.{ .date, .identifier, .indentation, .identifier, .indentation, .identifier });

    try testTokenize(
        \\2020 abc
        \\    d:e  $10
        \\    x:y  
    , &.{ .date, .identifier, .indentation, .identifier, .identifier, .amount, .indentation, .identifier });
}

test "multiple transactions" {
    const source: [:0]const u8 =
        \\2020-01-02  abc
        \\  a:b   $1
        \\  c:d
        \\
        \\2020-01-03  xyz
        \\  e:f   $2
        \\  c:d
    ;
    try testTokenize(source, &.{ .date, .identifier, .indentation, .identifier, .identifier, .amount, .indentation, .identifier, .date, .identifier, .indentation, .identifier, .identifier, .amount, .indentation, .identifier });
}
