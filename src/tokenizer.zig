const std = @import("std");

const transaction_indentation: usize = 4;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Tag = enum {
        posting_indentation,
        comment,
        date,
        identifier, // payee, account
        invalid,
        eof,
    };

    pub const Loc = struct {
        start: usize,
        end: usize,
    };
};

/// A thing
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
        posting_indentation,
        comment, // both file and transaction level
        date,
        identifier, // payee, account
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
            std.log.info("while switching on '{c}' as {s}", .{ c, state });
            switch (state) {
                .start => switch (c) {
                    0 => break,
                    '\n', '\r' => {
                        result.loc.start = self.index + 1;
                        seen_spaces = 0;
                    },
                    ' ', '\t' => {
                        seen_spaces += if (c == ' ') 1 else transaction_indentation;
                        // std.log.info("seen {d} spaces", .{seen_spaces});

                        if (seen_spaces >= transaction_indentation) {
                            // Are the spaces at the start of the line?
                            std.log.info("{d} + 1 - {d} <= {d}", .{ self.index, seen_spaces, result.loc.start });
                            if (self.index + 1 <= result.loc.start + seen_spaces) {
                                state = .posting_indentation;
                                result.tag = .posting_indentation;
                                self.index += 1;
                                break;
                            }
                        }
                    },
                    ';', '#' => {
                        std.log.info("start saw comment", .{});
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
                        std.log.info("start saw a-z with {d} spaces", .{seen_spaces});

                        state = .identifier;
                        result.tag = .identifier;
                        result.loc.start = self.index;
                        seen_spaces = 0;
                    },
                    else => {
                        std.log.info("start saw '{c}'", .{c});
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        self.index += 1;
                        return result;
                    },
                },

                .comment => switch (c) {
                    '\n', '\r' => {
                        std.log.info("comment saw line break", .{});
                        break;
                    },
                    else => {
                        std.log.info("comment saw any char", .{});
                        if (self.index == self.buffer.len) break;
                    },
                },

                .date => switch (c) {
                    '/', '-', '.', '0'...'9' => {},
                    else => break,
                },

                .identifier => switch (c) {
                    ' ', '\t' => {
                        seen_spaces += if (c == ' ') 1 else transaction_indentation;
                    },
                    ';', '#' => {
                        if (seen_spaces >= 2) {
                            std.log.info("enter comment from idenfifier", .{});
                        }
                    },
                    'a'...'z' => {},
                    else => break,
                },

                else => {
                    std.log.info("switch didn't match anything", .{});
                    result.tag = .invalid;
                    result.loc.end = self.index;
                    self.index += 1;
                    return result;
                },
            }
        }
        std.log.info("end of while", .{});

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
        std.log.info(">> test got {s}", .{token.tag});
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

test "finds comments" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});
    try testTokenize("; hi", &.{.comment});
}

test "finds dates" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    try testTokenize("2021-02-03", &.{.date});
}

test "finds posting indentations" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    try testTokenize(" \n    abc", &.{ .posting_indentation, .identifier });
    try testTokenize(" \n\txyz", &.{ .posting_indentation, .identifier });
}
