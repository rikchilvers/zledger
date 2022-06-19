const std = @import("std");

const transaction_indentation: usize = 2;
const max_spaces_in_identifier: usize = 2;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const keywords = std.ComptimeStringMap(Tag, .{
        .{ "account", .keyword_account },
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
        std.log.info("next", .{});

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

            if (c == '\n' or c == '\r') {
                std.log.info("while loop on {d}: {d}:'{s}' ({d} spaces) - {s}", .{ self.index, c, "/n", seen_spaces, state });
            } else {
                std.log.info("while loop on {d}: {d}:'{c}' ({d} spaces) - {s}", .{ self.index, c, c, seen_spaces, state });
            }

            switch (state) {
                .start => switch (c) {
                    0 => break,

                    '\n', '\r' => {
                        result.loc.start = self.index + 1;
                        self.last_newline = self.index;
                        std.log.info("\tstoring last newline at {}", .{self.last_newline});
                        seen_spaces = 0;
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
                        std.log.info("\tstart found a number. last newline on {}", .{self.last_newline});
                        // this could be the start of a date or an amount
                        // are we at the start of a line?
                        if (self.index == 0 or self.index > 0 and (self.buffer[self.index - 1] == '\n' or self.buffer[self.index - 1] == 'r')) {
                            state = .date;
                            result.tag = .date;
                        } else {
                            state = .amount;
                            result.tag = .amount;
                        }

                        result.loc.start = self.index;
                    },

                    // FIXME: we also need to catch commodities here (I think)
                    // i.e. remove the commodity tag and just use identifier
                    'a'...'z', 'A'...'Z', 0xc0...0xf7 => {
                        state = .identifier;
                        result.tag = .identifier;
                        result.loc.start = self.index;
                        seen_spaces = 0;
                    },

                    '!', '*' => {
                        state = .status;
                        result.tag = .status;
                        result.loc.start = self.index;
                    },

                    else => {
                        std.log.info("start found {x}", .{c});
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        self.index += 1;
                        return result;
                    },
                },

                .whitespace => switch (c) {
                    ' ', '\t' => {
                        seen_spaces += if (c == ' ') 1 else transaction_indentation;
                    },
                    else => {
                        // std.log.info("whitespace break", .{});
                        const i = self.last_newline orelse 0;
                        std.log.info("    {} <= {} + {} + 1", .{ self.index, i, seen_spaces });
                        const from_beginning = self.index <= (self.last_newline orelse 0) + seen_spaces + 1;
                        if (from_beginning) {
                            // std.log.info("\t\tspaces from line beginning", .{});
                            if (seen_spaces >= transaction_indentation) {
                                // std.log.info("\t\tindentation", .{});
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
                    '0'...'9', '.' => {},
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
                    else => break,
                },

                .identifier => switch (c) {
                    0, '0'...'9', '\n', '\r' => {
                        break;
                    },
                    ' ', '\t' => {
                        // this could be a keyword if it begins at the start of the line
                        if (result.loc.start == 0) {
                            if (Token.getKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                                result.tag = tag;
                                break;
                            }
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
                    // TODO: convert chars to unicode values and use a range so we can include more
                    // 'a'...'z', 'A'...'Z', '0'...'9', ':' => {
                    //     seen_spaces = 0;
                    // },
                    else => {
                        seen_spaces = 0;
                        // this could be a keyword if it begins at the start of the line
                        if (result.loc.start == 0) {
                            if (Token.getKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                                result.tag = tag;
                            }
                        }
                        // break;
                    },
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

        result.loc.end = self.index;
        return result;
    }
};

fn testTokenize(source: [:0]const u8, expected_tokens: []const Token.Tag) !void {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

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
    // std.testing.log_level = .debug;
    // std.log.info("\n", .{});

    try testTokenize("\taccount", &.{ .indentation, .identifier });
    try testTokenize("account a:b:c", &.{ .keyword_account, .identifier });
    try testTokenize("account a:b:c\n", &.{ .keyword_account, .identifier });
    try testTokenize("apply tag abc\n", &.{ .keyword_apply_tag, .identifier });
    try testTokenize("apply account abc\n", &.{ .keyword_apply_account, .identifier });
}

test "dates" {
    // std.testing.log_level = .debug;
    // std.log.info("\n", .{});

    try testTokenize("2021-02-03", &.{.date});
}

test "identifiers" {
    // std.testing.log_level = .debug;
    // std.log.info("\n", .{});

    try testTokenize("abc def", &.{.identifier});
    try testTokenize("abc:def", &.{.identifier});

    try testTokenize("abc   xyz", &.{ .identifier, .identifier });
}

test "statuses" {
    // std.testing.log_level = .debug;
    // std.log.info("\n", .{});

    try testTokenize("2020 ! abc", &.{ .date, .status, .identifier });
    try testTokenize("2020-01 * abc", &.{ .date, .status, .identifier });
    try testTokenize("2020-01 *abc", &.{ .date, .identifier });
}

test "indentations" {
    // std.testing.log_level = .debug;
    // std.log.info("\n", .{});

    try testTokenize("  abc", &.{ .indentation, .identifier });
    try testTokenize("\txyz", &.{ .indentation, .identifier });
    try testTokenize(" \n    abc def", &.{ .indentation, .identifier });
    try testTokenize(" \n\txyz", &.{ .indentation, .identifier });
}

test "comments" {
    // std.testing.log_level = .debug;
    // std.log.info("\n", .{});

    try testTokenize("; hi", &.{.comment});
    try testTokenize("2020 abc  ; xyz", &.{ .date, .identifier, .comment });
    try testTokenize("\t ; xyz", &.{ .indentation, .comment });
}

test "commodities" {
    try testTokenize("abc:def    £10.00", &.{ .identifier, .identifier, .amount });
    // try testTokenize("abc:def    USD 10.00", &.{ .identifier, .indentation, .identifier, .amount });
    // try testTokenize("abc:def    10.00€", &.{ .identifier, .indentation, .amount, .identifier });
    // try testTokenize("abc:def    10.00 EUR", &.{ .identifier, .indentation, .amount, .identifier });

    std.log.info("\n", .{});
}

test "amounts" {
    try testTokenize("\tabc:def    10", &.{ .indentation, .identifier, .amount });

    std.log.info("\n", .{});
}

test "transactions" {
    try testTokenize(
        \\2020 abc
        \\    d:e
        \\    x:y
    , &.{ .date, .identifier, .indentation, .identifier, .indentation, .identifier });
}
