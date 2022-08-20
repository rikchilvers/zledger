const std = @import("std");

const transaction_indentation: usize = 2;
const max_spaces_in_identifier: usize = 2;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Tag = enum {
        indentation,
        comment,
        date,
        identifier, // payee, account
        status,
        commodity,
        amount,
        keyword_partial,
        keyword_account,
        keyword_apply_account,
        keyword_apply_tag,
        keyword_import,
        keyword_alias,
        invalid,
        eof,

        pub fn isKeyword(self: Token.Tag) bool {
            switch (self) {
                .keyword_partial,
                .keyword_account,
                .keyword_apply_account,
                .keyword_apply_tag,
                .keyword_import,
                .keyword_alias,
                => return true,
                else => return false,
            }
        }
    };

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.ComptimeStringMap(Tag, .{
        .{ "account", .keyword_account },
        .{ "apply", .keyword_partial },
        .{ "import", .keyword_import },
        .{ "alias", .keyword_alias },
        .{ "apply account", .keyword_apply_account },
        .{ "apply tag", .keyword_apply_tag },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        // std.log.info("checking", .{});
        return keywords.get(bytes);
    }

    pub fn debug(self: Token, source: []const u8) void {
        std.log.info("{any}: '{s}'", .{ self.tag, source[self.loc.start..self.loc.end] });
    }
};

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize,
    last_newline: usize,

    pub fn init(buffer: []const u8) Tokenizer {
        // Skip the UTF-8 BOM if present
        const src_start = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else @as(usize, 0);
        return Tokenizer{
            .buffer = buffer,
            .index = src_start,
            .last_newline = src_start,
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

    pub fn charAtStartOfLine(self: *Tokenizer) bool {
        const last_char = if (self.index > 0) self.buffer[self.index - 1] else '0';
        return (last_char == '\n' or last_char == '\r') or self.index == 0;
    }

    pub fn next(self: *Tokenizer) Token {
        var state: State = .start;
        var result = Token{
            .tag = .eof,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };

        var seen_spaces: usize = 0;
        while (self.index < self.buffer.len) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    '\n', '\r' => {
                        seen_spaces = 0;
                        self.last_newline = self.index;
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
                        if (self.charAtStartOfLine()) {
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
                        // We only care about indentation when it starts from the beginning of a line.
                        // After that, it's not useful to output a token for it since it doesn't have meaning
                        // in a ledger file.
                        // During parsing, we can choose to ignore indentation that does not come after a transaction declaration.

                        // check if we've only seen whitespace on this line so far
                        // FIXME: could we make this faster? is there a way of not having to backtrack like this?
                        var cursor = self.index - 1;
                        while (cursor > self.last_newline) : (cursor -= 1) {
                            const char = self.buffer[cursor];
                            if (char != '\t' and char != ' ') break;
                        }

                        if (cursor == self.last_newline) {
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
                    ' ', '\t', '\n', '\r' => break,
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                // Could also be a keyword
                .identifier => switch (c) {
                    '0'...'9', '\n', '\r', '+', '-' => break,
                    ' ', '\t' => {
                        seen_spaces += if (c == ' ') 1 else transaction_indentation;
                        if (seen_spaces >= max_spaces_in_identifier) {
                            self.index -= 1;
                            break;
                        }

                        // There are no reserved words in ledger files which means that keywords
                        // (e.g., account) can be used as identifiers. That means that when we
                        // encounter a space in an identifier, it could mean that
                        //      more is coming (e.g., Expenses:A Store Name)
                        //      that a keyword has been used (e.g., apply[ ]tag).
                        // As we can't know which is happening at the tokinzation stage, we eagerly
                        // classify matching words as keywords and let the parser handle it.
                        // We also cannot use a heuristic such as the token starting from the beginning
                        // of a line or being indented because how that is handled depends on what tokens
                        // have come before, which this tokenizer is not aware of.
                        if (Token.getKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                            if (tag == .keyword_partial) continue;
                            result.tag = tag;
                            break;
                        }
                    },
                    ';', '#' => {
                        if (seen_spaces >= max_spaces_in_identifier) {
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
            result.loc.start = self.index;
        }

        // invalid tags run until the next double space or newline
        if (result.tag == .invalid) {
            while (self.index < self.buffer.len) : (self.index += 1) {
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

fn testTokenize(source: []const u8, expected_tokens: []const Token.Tag) !void {
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
    try testTokenize("import ./abc.ledger\n", &.{ .keyword_import, .identifier });
    try testTokenize("\talias bloop \n", &.{ .indentation, .keyword_alias, .identifier });
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
    try testTokenize(" abc", &.{.identifier});
    try testTokenize("  abc", &.{ .indentation, .identifier });
    try testTokenize("\txyz", &.{ .indentation, .identifier });
    try testTokenize(" \n    abc def", &.{ .indentation, .identifier });
    try testTokenize("one long identifier  another one", &.{ .identifier, .identifier });
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
    , &.{
        .date,
        .identifier,
        .indentation,
        .identifier,
        .indentation,
        .identifier,
    });

    try testTokenize(
        \\2020 abc
        \\    d:e  $10
        \\    x:y  
    , &.{
        .date,
        .identifier,
        .indentation,
        .identifier,
        .identifier,
        .amount,
        .indentation,
        .identifier,
    });
}

test "multiple transactions" {
    const source: []const u8 =
        \\2020-01-02  abc
        \\  a:b   $1
        \\  c:d
        \\
        \\2020-01-03  xyz
        \\  e:f   $2
        \\  c:d
    ;
    try testTokenize(source, &.{
        .date,
        .identifier,
        .indentation,
        .identifier,
        .identifier,
        .amount,
        .indentation,
        .identifier,
        .date,
        .identifier,
        .indentation,
        .identifier,
        .identifier,
        .amount,
        .indentation,
        .identifier,
    });
}
