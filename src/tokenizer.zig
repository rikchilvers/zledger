const std = @import("std");

const transaction_indentation: usize = 4;

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
        status_cleared,
        status_pending,
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
};

pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,
    // FIXME: do we need this?
    pending_invalid_token: ?Token,

    pub fn init(buffer: [:0]const u8) Tokenizer {
        // Skip the UTF-8 BOM if present
        const src_start = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else @as(usize, 0);
        return Tokenizer{
            .buffer = buffer,
            .index = src_start,
            .pending_invalid_token = null,
        };
    }

    const State = enum {
        start,
        indentation,
        comment, // both file and transaction level
        date,
        identifier, // payee, account, keywords
        status, // pending or cleared
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
        // var seen_escape_digits: usize = undefined;
        // var remaining_code_units: usize = undefined;
        while (true) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    0 => break,
                    '\n', '\r' => {
                        result.loc.start = self.index + 1;
                        seen_spaces = 0;
                    },
                    ' ', '\t' => {
                        seen_spaces += if (c == ' ') 1 else transaction_indentation;

                        if (seen_spaces >= transaction_indentation) {
                            // Are the spaces at the start of the line?
                            if (self.index + 1 <= result.loc.start + seen_spaces) {
                                state = .indentation;
                                result.tag = .indentation;
                                self.index += 1;
                                break;
                            }
                        }
                    },
                    ';', '#' => {
                        state = .comment;
                        result.tag = .comment;
                        result.loc.start = self.index + 1;
                    },
                    '0'...'9' => {
                        state = .date;
                        result.tag = .date;
                        result.loc.start = self.index;
                    },
                    'a'...'z', 'A'...'Z' => {
                        state = .identifier;
                        result.tag = .identifier;
                        result.loc.start = self.index;
                        seen_spaces = 0;
                    },
                    '!' => {
                        state = .status;
                        result.tag = .status_pending;
                        result.loc.start = self.index;
                    },
                    '*' => {
                        state = .status;
                        result.tag = .status_cleared;
                        result.loc.start = self.index;
                    },
                    else => {
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        self.index += 1;
                        return result;
                    },
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
                    ' ', '\t' => {
                        // this could be a keyword if it begins at the start of the line
                        if (result.loc.start == 0) {
                            if (Token.getKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                                result.tag = tag;
                                break;
                            }
                        }

                        seen_spaces += if (c == ' ') 1 else transaction_indentation;
                    },
                    ';', '#' => {
                        if (seen_spaces >= 2) {
                            // need to return the identifier and move into the comment
                            // so we backtrack to catch the comment opener
                            self.index -= 1;
                            break;
                        }
                    },
                    // TODO: convert chars to unicode values and use a range so we can include more
                    'a'...'z', 'A'...'Z', '0'...'9', ':' => {
                        seen_spaces = 0;
                    },
                    else => {
                        // this could be a keyword if it begins at the start of the line
                        if (result.loc.start == 0) {
                            if (Token.getKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                                result.tag = tag;
                            }
                        }
                        break;
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
    var tokenizer = Tokenizer.init(source);
    for (expected_tokens) |expected_token_id| {
        const token = tokenizer.next();
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

test "transactions" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    try testTokenize(
        \\
        \\2020 ! abc
        \\    x:y:z
        \\    ; comment
        \\    x:y:z
    , &.{ .date, .status_pending, .identifier, .indentation, .identifier, .indentation, .comment, .indentation, .identifier });
}

test "cleared and pending" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    try testTokenize("2020 ! abc", &.{ .date, .status_pending, .identifier });
    try testTokenize("2020-01 * abc", &.{ .date, .status_cleared, .identifier });

    try testTokenize("2020-01 *abc", &.{ .date, .identifier });
}

test "comments" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    try testTokenize("; hi", &.{.comment});
    try testTokenize("2020 abc  ; xyz", &.{ .date, .identifier, .comment });
    try testTokenize("\t ; xyz", &.{ .indentation, .comment });
}

test "dates" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    try testTokenize("2021-02-03", &.{.date});
}

test "keywords" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    try testTokenize("\taccount", &.{ .indentation, .identifier });
    try testTokenize("account a:b:c", &.{ .keyword_account, .identifier });
    try testTokenize("account a:b:c\n", &.{ .keyword_account, .identifier });
    try testTokenize("apply tag abc\n", &.{ .keyword_apply_tag, .identifier });
    try testTokenize("apply account abc\n", &.{ .keyword_apply_account, .identifier });
}

test "indentations" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    try testTokenize(" \n    abc def", &.{ .indentation, .identifier });
    try testTokenize(" \n\txyz", &.{ .indentation, .identifier });
}
