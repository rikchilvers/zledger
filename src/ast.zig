//! Abstract Syntax Tree for ledger files.

const std = @import("std");
const Token = @import("tokenizer.zig").Token;
const Ast = @This();

pub const TokenIndex = u32;
pub const ByteOffset = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);

/// Reference to externally-owned data.
source: [:0]const u8,
tokens: TokenList.Slice,
/// The root AST node is assumed to be index 0. Since there can be no
/// references to the root node, this means 0 is available to indicate null.
nodes: NodeList.Slice,

pub const Error = struct {
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

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    // Contains the information associated with the node
    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };

    pub const Index = u32;

    pub const Tag = enum {
        root,
        /// lhs is the account.
        /// rhs is unused.
        account_directive_decl,
    };
};
