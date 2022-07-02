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
        .scratch = std.ArrayList(Node.Index).init(gpa),
        .extra_data = std.ArrayList(Node.Index).init(gpa),
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .token_index = 0,
    };
    defer parser.errors.deinit();
    defer parser.nodes.deinit(gpa);
    defer parser.scratch.deinit();
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
    /// Used to transiently hold references to Node.Indexes as the parser works
    scratch: std.ArrayList(Node.Index),

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
                    const xact = try p.expectTransactionRecoverable();
                    if (xact == 0) {
                        try p.recordError(.{
                            .tag = .expected_transaction,
                            .token = p.token_index,
                        });
                        continue;
                    }

                    // parse the postings
                    // add start/finish indices to the node
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

    fn addNode(p: *Parser, elem: Tree.NodeList.Elem) Allocator.Error!Node.Index {
        const result = @intCast(Node.Index, p.nodes.len);
        try p.nodes.append(p.gpa, elem);
        return result;
    }

    fn setNode(p: *Parser, i: usize, elem: Tree.NodeList.Elem) Node.Index {
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
        // TODO: eat docs
        const date = try p.expectToken(.date);
        const status = p.eatToken(.status) orelse 0;
        const payee = p.eatToken(.identifier) orelse 0;

        var decl_extra: Node.Index = 0;
        if (status + payee > 0) {
            decl_extra = try p.addExtra(Node.TransactionDeclaration{
                .status = status,
                .payee = payee,
            });
        }

        // TODO: next
        // probably need to reserve a node for the TransactionBody
        // and go on to parse the postings
        // that way, we can add them to the body but maintain the order

        const decl = try p.addNode(.{
            .tag = .transaction_declaration,
            .main_token = date,
            .data = .{
                .lhs = decl_extra,
                .rhs = 0,
            },
        });

        const body_index = try p.reserveNode();

        // get the postings
        // first two are required
        p.eatComments();
        var first_posting = try p.expectPosting();
        p.eatComments();
        var last_posting = try p.expectPosting();
        while (true) {
            p.eatComments();
            const posting = try p.expectPostingRecoverable();
            if (posting == 0) break;
            last_posting = posting;
        }

        _ = p.setNode(body_index, .{ .tag = .transaction_body, .main_token = decl, .data = .{
            .lhs = try p.addExtra(Node.TransactionBody{
                .postings_start = first_posting,
                .postings_end = last_posting,
            }),
            .rhs = 0,
        } });

        return decl;
    }

    fn expectPostingRecoverable(p: *Parser) !Node.Index {
        return p.expectPosting() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => return null_node,
        };
    }

    fn expectPosting(p: *Parser) !Node.Index {
        _ = p;
        return null_node;
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
            return p.fail(.{
                .tag = .expected_token,
                .token = p.token_index,
                .extra = .{ .expected_tag = tag },
            });
        }
        return p.nextToken();
    }

    fn recordError(p: *Parser, msg: Tree.Error) error{OutOfMemory}!void {
        switch (msg.tag) {
            .expected_token, .expected_transaction => if (msg.token != 0 and !p.tokensOnSameLine(msg.token - 1, msg.token)) {
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
    var tree = try parse(std.testing.allocator, source);
    tree.deinit(std.testing.allocator);
}
