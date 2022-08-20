const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;

const Ast = @import("ast.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

pub const Error = error{ParseError} || Allocator.Error;

const null_node: Node.Index = 0;

pub fn parse(gpa: Allocator, source: []const u8) Allocator.Error!Ast {
    var tokens = Ast.TokenList{};
    defer tokens.deinit(gpa);

    var tokenizer = Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(u32, token.loc.start),
            .end = @intCast(u32, token.loc.end),
        });
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .gpa = gpa,
        .source = source,
        .errors = std.ArrayList(Ast.Error).init(gpa),
        .nodes = .{},
        .extra_data = std.ArrayList(Node.Index).init(gpa),
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .token_index = 0,
    };
    defer parser.errors.deinit();
    defer parser.nodes.deinit(gpa);
    defer parser.extra_data.deinit();

    // TODO: would it be possible to work out the ratio of tokens to AST nodes for ledger files?
    // Make sure at least 1 so we can use appendAssumeCapacity on the root node below.
    const estimated_node_count = (tokens.len + 2) / 2;
    try parser.nodes.ensureTotalCapacity(gpa, estimated_node_count);

    // Root node must be index 0.
    parser.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });

    try parser.start();

    return Ast{
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
    errors: std.ArrayList(Ast.Error),
    nodes: Ast.NodeList,
    /// Additional information associated with a Node (e.g. postings for a transaction)
    /// Use Ast.extraData() to extra the data
    extra_data: std.ArrayList(Node.Index),

    /// token_tags.len == token_starts.len as they're the deconstructed results of tokenization
    token_tags: []const Token.Tag,
    token_starts: []const Ast.ByteOffset,
    /// the index to the current token that the parser is looking at (starting at 0)
    token_index: TokenIndex,

    fn start(p: *Parser) Allocator.Error!void {
        while (true) {
            switch (p.token_tags[p.token_index]) {
                .date => {
                    const xact = try p.expectTransactionRecoverable();
                    if (xact == 0) {
                        try p.recordError(.{
                            .tag = .expected_transaction,
                            .token = p.token_index,
                        });
                        continue;
                    }
                },
                .eof => {
                    break;
                },
                else => {
                    p.findNextBlock();
                },
            }
        }
    }

    fn addNode(p: *Parser, elem: Ast.NodeList.Elem) Allocator.Error!Node.Index {
        const result = @intCast(Node.Index, p.nodes.len);
        try p.nodes.append(p.gpa, elem);
        return result;
    }

    fn setNode(p: *Parser, i: usize, elem: Ast.NodeList.Elem) Node.Index {
        p.nodes.set(i, elem);
        return @intCast(Node.Index, i);
    }

    fn reserveNode(p: *Parser) !usize {
        try p.nodes.resize(p.gpa, p.nodes.len + 1);
        return p.nodes.len - 1;
    }

    fn addExtra(p: *Parser, extra: anytype) Allocator.Error!Node.Index {
        const fields = std.meta.fields(@TypeOf(extra));
        try p.extra_data.ensureUnusedCapacity(fields.len);
        const result = @intCast(u32, p.extra_data.items.len);
        inline for (fields) |field| {
            comptime assert(field.field_type == Node.Index);
            p.extra_data.appendAssumeCapacity(@field(extra, field.name));
        }
        return result;
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
        // get the header
        const date = try p.expectToken(.date);
        const status = p.eatToken(.status) orelse 0;
        const payee = p.eatToken(.identifier) orelse 0;
        // TODO: parse comments in header line
        const comment = 0;
        const header = try p.addNode(.{
            .tag = .transaction_header,
            .main_token = date,
            .data = .{
                .lhs = try p.addExtra(Node.TransactionHeader{
                    .status = status,
                    .payee = payee,
                    .comment = comment,
                }),
                .rhs = 0,
            },
        });

        // TODO: maybe comment
        _ = try p.expectPosting(header);
        // TODO: maybe comment
        _ = try p.expectPosting(header);
        // more
        while (true) {
            // TODO: maybe comment
            const posting = try p.expectPostingRecoverable(header);
            if (posting == null_node) break;
        }
        // TODO: maybe comment

        return header;
    }

    fn expectPostingRecoverable(p: *Parser, header_index: Node.Index) !Node.Index {
        return p.expectPosting(header_index) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => return null_node,
        };
    }

    fn expectPosting(p: *Parser, header_index: Node.Index) !Node.Index {
        const indentation = try p.expectToken(.indentation);

        // If the user has called their account one of the keywords, the tokenizer will have
        // classed it as such so we need to handle both .identifier and .keyword_??? here.
        var account: TokenIndex = undefined;
        const token = p.token_tags[p.token_index];
        if (token != .identifier and token.isKeyword()) {
            account = p.nextToken();
        } else {
            account = try p.expectToken(.identifier);
        }
        var commodity = p.eatToken(.identifier);
        const amount = p.eatToken(.amount);
        if (commodity == null and amount != null) {
            commodity = p.eatToken(.identifier);
        }

        return p.addNode(.{
            .tag = .posting,
            .main_token = indentation,
            .data = .{
                .lhs = try p.addExtra(Node.Posting{
                    .account = account,
                    .commodity = commodity orelse 0,
                    .amount = amount orelse 0,
                    .comment = 0, // FIXME: parse
                }),
                .rhs = header_index,
            },
        });
    }

    // Skips over comments
    fn eatComments(p: *Parser) void {
        _ = p;
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
                .eof => {
                    p.token_index -= 1;
                    return;
                },
                else => {},
            }
        }
    }

    fn expectToken(p: *Parser, tag: Token.Tag) Error!TokenIndex {
        if (p.token_tags[p.token_index] != tag) {
            // std.log.err("expectToken() found a {any}, not a {any}", .{
            //     p.token_tags[p.token_index],
            //     tag,
            // });
            return p.fail(.{
                .tag = .expected_token,
                .token = p.token_index,
                .extra = .{ .expected_tag = tag },
            });
        }
        return p.nextToken();
    }

    fn recordError(p: *Parser, msg: Ast.Error) error{OutOfMemory}!void {
        switch (msg.tag) {
            .expected_token, .expected_transaction => if (msg.token != 0 and !p.tokensOnSameLine(msg.token - 1, msg.token)) {
                var copy = msg;
                copy.token_is_prev = true;
                copy.token -= 1;
                return p.errors.append(copy);
            },
        }
        try p.errors.append(msg);
    }

    fn tokensOnSameLine(p: *Parser, token1: TokenIndex, token2: TokenIndex) bool {
        return std.mem.indexOfScalar(u8, p.source[p.token_starts[token1]..p.token_starts[token2]], '\n') == null;
    }

    fn fail(p: *Parser, msg: Ast.Error) error{ ParseError, OutOfMemory } {
        try p.recordError(msg);
        return error.ParseError;
    }

    /// Returns the index of an expected type of token or null.
    /// Moves parser to the next token.
    fn eatToken(p: *Parser, tag: Token.Tag) ?TokenIndex {
        return if (p.token_tags[p.token_index] == tag) p.nextToken() else null;
    }

    /// Moves the Parser to the next token but returns the index of the current one.
    fn nextToken(p: *Parser) TokenIndex {
        const result = p.token_index;
        p.token_index += 1;
        return result;
    }
};

test "transaction decl and body" {
    const source: []const u8 = "2020-01-02 abc\n\ta:b   $1\n\tc:d";
    var tree = try parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(Node.Tag, &.{
        .root,
        .transaction_header,
        .posting,
        .posting,
    }, tree.nodes.items(.tag));
}

test "multiple transactions with keyword account names" {
    const source: []const u8 =
        \\2020-01-02  abc
        \\  apply account   $1
        \\  apply tag
        \\
        \\2020-01-03 ! xyz
        \\  account   $2
        \\  alias
    ;
    var tree = try parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(Node.Tag, &.{
        .root,
        .transaction_header,
        .posting,
        .posting,
        .transaction_header,
        .posting,
        .posting,
    }, tree.nodes.items(.tag));
}

// test "postings" {
//     std.testing.log_level = .debug;
//     std.log.info("\n", .{});

//     const source: [:0]const u8 = "2020-01-02 abc\n\taccount:sub\t£123\n\taccount2\t";
//     var tree = try parse(std.testing.allocator, source);
//     defer tree.deinit(std.testing.allocator);

//     std.log.info("{s}", .{tree.nodes.items(.tag)});
// }
