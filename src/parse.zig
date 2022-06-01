const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("./tokenizer.zig").Token;

const Tree = @import("./tree.zig");
const Node = Tree.Node;
const TokenIndex = Tree.TokenIndex;

pub const Error = error{ParseError} || Allocator.Error;

const null_node: Node.Index = 0;

pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!Tree {
    var tokens = Tree.TokenList{};
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
        .errors = std.ArrayList(Tree.Error).init(gpa),
        .nodes = .{},
        .extra_data = std.ArrayList(Node.Index).init(gpa),
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .token_index = 0,
    };
    defer parser.errors.deinit();
    defer parser.nodes.deinit(gpa);
    defer parser.extra_data.deinit();

    // Root node must be index 0.
    parser.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });

    try parser.start();

    return Tree{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = parser.extra_data.toOwnedSlice(),
        .errors = parser.errors.toOwnedSlice(),
    };
}

/// Converts a stream of Tokens into a stream of Nodes
const Parser = struct {
    gpa: Allocator,
    source: []const u8,
    errors: std.ArrayList(Tree.Error),
    nodes: Tree.NodeList,
    /// Additional information associated with a Node (e.g. postings for a transaction)
    /// Use Tree.extraData() to extra the data
    extra_data: std.ArrayList(Node.Index),

    /// token_tags.len == token_starts.len as they're the deconstructed results of tokenization
    token_tags: []const Token.Tag,
    token_starts: []const Tree.ByteOffset,
    /// the index to the current token that the parser is looking at (starting at 0)
    token_index: TokenIndex,

    fn start(p: *Parser) Allocator.Error!void {
        while (true) {
            std.log.info("parser saw {s}", .{p.token_tags[p.token_index]});
            switch (p.token_tags[p.token_index]) {
                .date => {
                    _ = try p.expectTransactionRecoverable();
                    // TODO: add the node if it's not 0
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

    fn expectTransactionRecoverable(p: *Parser) !Node.Index {
        return p.expectTransaction() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {
                p.findNextBlock();
                return null_node;
            },
        };
    }

    fn expectTransaction(p: *Parser) !Node.Index {
        _ = try p.expectToken(.date);
        _ = p.possibleToken(.status);
        _ = try p.expectToken(.identifier);

        return null_node;
    }

    /// Attempts to find next block by searching for certain tokens
    fn findNextBlock(p: *Parser) void {
        while (true) {
            const token = p.nextToken();
            switch (p.token_tags[token]) {
                // any of these can start a new block
                .date => {
                    p.token_index -= 1;
                    return;
                },
                else => {},
            }
        }
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

    fn possibleToken(p: *Parser, tag: Token.Tag) ?TokenIndex {
        if (p.token_tags[p.token_index] != tag) return null;
        return p.nextToken();
    }

    fn recordError(p: *Parser, msg: Tree.Error) error{OutOfMemory}!void {
        switch (msg.tag) {
            .expected_token => if (msg.token != 0 and !p.tokensOnSameLine(msg.token - 1, msg.token)) {
                var copy = msg;
                copy.token_is_prev = true;
                copy.token -= 1;
                return p.errors.append(copy);
            },
            // else => {},
        }
        try p.errors.append(msg);
    }

    fn tokensOnSameLine(p: *Parser, token1: TokenIndex, token2: TokenIndex) bool {
        return std.mem.indexOfScalar(u8, p.source[p.token_starts[token1]..p.token_starts[token2]], '\n') == null;
    }

    fn fail(p: *Parser, msg: Tree.Error) error{ ParseError, OutOfMemory } {
        try p.recordError(msg);
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

test "basic" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    const source: [:0]const u8 = "2020-01-02 abc";
    _ = try parse(std.testing.allocator, source);
}
