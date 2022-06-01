const std = @import("std");
const datetime = @import("datetime").datetime;

const assert = std.debug.assert;

const Date = datetime.Date;

const Allocator = std.mem.Allocator;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("./tokenizer.zig").Token;

pub const Error = error{ParseError} || Allocator.Error;

// TODO: why do we use a u32 as the offset and not, say, u8?
pub const ByteOffset = u32;
pub const TokenIndex = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});

pub fn parse(gpa: Allocator, source: [:0]const u8) !void {
    var tokens = TokenList{};
    defer tokens.deinit(gpa);

    var tokenizer = Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        std.log.info("tokenizer saw: {s}", .{token.tag});
        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(u32, token.loc.start),
        });
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .gpa = gpa,
        .source = source,
        .warnings = std.ArrayList(Parser.Warning).init(gpa),
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .token_index = 0,
    };

    try parser.start();
}

const Parser = struct {
    const Warning = struct {
        tag: Tag,
        /// True if `token` points to the token before the token causing an issue.
        token_is_prev: bool = false,
        token: TokenIndex,
        extra: union {
            none: void,
            expected_tag: Token.Tag,
        } = .{ .none = {} },

        pub const Tag = enum {
            /// `expected_tag` is populated.
            expected_token,
        };
    };

    gpa: Allocator,
    source: []const u8,
    warnings: std.ArrayList(Warning),

    /// token_tags.len == token_starts.len as they're the deconstructed results of tokenization
    token_tags: []const Token.Tag,
    token_starts: []const ByteOffset,
    /// the index to the current token that the parser is looking at (starting at 0)
    token_index: TokenIndex,

    fn start(p: *Parser) !void {
        while (true) {
            std.log.info("parser saw {s}", .{p.token_tags[p.token_index]});
            switch (p.token_tags[p.token_index]) {
                .date => {
                    _ = try p.expectTransaction();
                },
                .eof => {
                    break;
                },
                else => {
                    _ = p.nextToken();
                },
            }
        }
    }

    fn expectTransaction(p: *Parser) !Transaction {
        _ = try p.expectToken(.date);
        unreachable;
    }

    fn expectToken(p: *Parser, tag: Token.Tag) Error!TokenIndex {
        if (p.token_tags[p.token_index] != tag) {
            return p.fail(.{
                .tag = .expected_token,
                .token = p.token_index,
                .extra = .{ .expected_tag = tag },
            });
        }
        return p.nextToken();
    }

    fn recordWarning(p: *Parser, msg: Warning) error{OutOfMemory}!void {
        switch (msg.tag) {
            .expected_token => if (msg.token != 0 and !p.tokensOnSameLine(msg.token - 1, msg.token)) {
                var copy = msg;
                copy.token_is_prev = true;
                copy.token -= 1;
                return p.warnings.append(copy);
            },
            // else => {},
        }
        try p.warnings.append(msg);
    }

    fn tokensOnSameLine(p: *Parser, token1: TokenIndex, token2: TokenIndex) bool {
        return std.mem.indexOfScalar(u8, p.source[p.token_starts[token1]..p.token_starts[token2]], '\n') == null;
    }

    fn fail(p: *Parser, msg: Warning) error{ ParseError, OutOfMemory } {
        try p.recordWarning(msg);
        return error.ParseError;
    }

    fn eatToken(p: *Parser, tag: Token.Tag) ?TokenIndex {
        return if (p.token_tags[p.token_index] == tag) p.nextToken() else null;
    }

    fn nextToken(p: *Parser) TokenIndex {
        const result = p.token_index;
        p.token_index += 1;
        return result;
    }
};

// Transaction holds details about an individual transaction
// type Transaction struct {
// 	Date                    time.Time
// 	State                   TransactionState
// 	Payee                   string
// 	Postings                []*Posting
// 	postingWithElidedAmount *Posting
// 	HeaderNote              string   // note in the header
// 	Notes                   []string // notes under the header
// }

pub const Transaction = struct {
    pub const State = enum { pending, cleared };

    date: Date,
    state: ?State,
    payee: []const u8,
    // posting
};

test "basic" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    const source: [:0]const u8 = "2020-01-02 abc";
    _ = try parse(std.testing.allocator, source);
}
