const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Ast = @import("./ast.zig");
const AstError = Ast.Error;
const Node = Ast.Node;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const TokenIndex = Ast.TokenIndex;
const Token = @import("./tokenizer.zig").Token;

pub const Error = error{ParseError} || Allocator.Error;

// FIXME: should return Ast
pub fn parse(gpa: Allocator, source: [:0]const u8) Allocator.Error!void {
    var tokens = Ast.TokenList{};
    defer tokens.deinit(gpa);

    var tokenizer = Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(u32, token.loc.start),
        });
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .source = source,
        .gpa = gpa,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .tok_i = 0,
        .nodes = .{},
        .errors = .{},
        .scratch = .{},
        // .extra_data = .{},
    };
    defer parser.nodes.deinit(gpa);
    defer parser.errors.deinit(gpa);
    defer parser.scratch.deinit(gpa);
    // defer parser.extra_data.deinit(gpa);

    // A ledger file has more tokens than nodes (e.g., indentation is not a node) so this is conservative
    try parser.nodes.ensureTotalCapacity(gpa, tokens.len);

    // Root node must be index 0.
    // Root <- skip ContainerMembers eof
    parser.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });

    // FIXME: this works when caught as unreachable
    try parser.parseTopLevel();
}

const Parser = struct {
    gpa: Allocator,
    source: []const u8,

    /// token_tags.len == token_starts.len as they're the deconstructed results of tokenization
    token_tags: []const Token.Tag,
    token_starts: []const Ast.ByteOffset,
    /// the index to the current token that the parser is looking at (starting at 0)
    tok_i: TokenIndex,

    nodes: Ast.NodeList,
    errors: std.ArrayListUnmanaged(AstError),
    scratch: std.ArrayListUnmanaged(Node.Index),
    // extra_data: std.ArrayListUnmanaged(Node.Index),

    ///
    const Members = struct {
        len: usize,
        lhs: Node.Index,
        rhs: Node.Index,
        trailing: bool,

        fn toSpan(self: Members, p: *Parser) !Node.SubRange {
            if (self.len <= 2) {
                const nodes = [2]Node.Index{ self.lhs, self.rhs };
                return p.listToSpan(nodes[0..self.len]);
            } else {
                return Node.SubRange{ .start = self.lhs, .end = self.rhs };
            }
        }
    };

    fn addNode(p: *Parser, elem: Ast.NodeList.Elem) Allocator.Error!Node.Index {
        const result = @intCast(Node.Index, p.nodes.len);
        try p.nodes.append(p.gpa, elem);
        return result;
    }

    fn warnMsg(p: *Parser, msg: Ast.Error) error{OutOfMemory}!void {
        @setCold(true);
        switch (msg.tag) {
            .expected_token => if (msg.token != 0 and !p.tokensOnSameLine(msg.token - 1, msg.token)) {
                var copy = msg;
                copy.token_is_prev = true;
                copy.token -= 1;
                return p.errors.append(p.gpa, copy);
            },
            // else => {},
        }
        try p.errors.append(p.gpa, msg);
    }

    fn failMsg(p: *Parser, msg: Ast.Error) error{ ParseError, OutOfMemory } {
        @setCold(true);
        try p.warnMsg(msg);
        return error.ParseError;
    }

    fn parseTopLevel(p: *Parser) !void {
        while (true) {
            const current_tag = p.token_tags[p.tok_i];
            std.log.info("parseTopLevel saw {s}", .{current_tag});
            switch (current_tag) {
                .eof => break,
                .keyword_account => {
                    const keyword_account_node = try p.expectAccountDirective();
                    if (keyword_account_node != 0) {
                        try p.scratch.append(p.gpa, keyword_account_node);
                    } else {
                        std.log.info("keyword_account_node was 0", .{});
                    }
                    // Start a new transaction
                },
                else => {
                    _ = p.eatToken(current_tag);
                },
            }
        }

        return;
    }

    /// AccountDirective <- KEYWORD_account IDENTIFIER
    fn expectAccountDirective(p: *Parser) !Node.Index {
        const keyword_token = p.assertToken(.keyword_account);
        const account_token = try p.expectToken(.identifier);

        return p.addNode(.{ .tag = .account_directive_decl, .main_token = keyword_token, .data = .{
            .lhs = account_token,
            .rhs = 0,
        } });
    }

    fn assertToken(p: *Parser, tag: Token.Tag) TokenIndex {
        const token = p.nextToken();
        assert(p.token_tags[token] == tag);
        return token;
    }

    fn expectToken(p: *Parser, tag: Token.Tag) Error!TokenIndex {
        if (p.token_tags[p.tok_i] != tag) {
            return p.failMsg(.{
                .tag = .expected_token,
                .token = p.tok_i,
                .extra = .{ .expected_tag = tag },
            });
        }
        return p.nextToken();
    }

    fn eatToken(p: *Parser, tag: Token.Tag) ?TokenIndex {
        return if (p.token_tags[p.tok_i] == tag) p.nextToken() else null;
    }

    fn nextToken(p: *Parser) TokenIndex {
        const result = p.tok_i;
        p.tok_i += 1;
        return result;
    }

    fn tokensOnSameLine(p: *Parser, token1: TokenIndex, token2: TokenIndex) bool {
        return std.mem.indexOfScalar(u8, p.source[p.token_starts[token1]..p.token_starts[token2]], '\n') == null;
    }
};

test "basic" {
    std.testing.log_level = .debug;
    std.log.info("\n", .{});

    const source: [:0]const u8 = "2020-01-02 abc";
    _ = try parse(std.testing.allocator, source);
}
