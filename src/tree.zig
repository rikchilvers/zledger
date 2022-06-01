//! Abstract Syntax Tree for Zig source code.

/// Reference to externally-owned data.
source: [:0]const u8,

tokens: TokenList.Slice,
/// The root AST node is assumed to be index 0. Since there can be no
/// references to the root node, this means 0 is available to indicate null.
nodes: NodeList.Slice,
extra_data: []Node.Index,

errors: []const Error,

const std = @import("std");
const assert = std.debug.assert;
const Token = @import("./tokenizer.zig").Token;
const Tree = @This();

// TODO: why do we use a u32 as the offset and not, say, u8?
pub const ByteOffset = u32;
pub const TokenIndex = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: Tree.ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);

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
    /// Type of Node
    tag: Tag,
    /// Main token associated with the Node (index into the list of tokens)
    main_token: TokenIndex,
    /// Information associated with the Node
    data: Data,

    pub const Index = u32;

    /// Possible Node types
    pub const Tag = enum {
        root,
        transaction_prototype,
        postings_prototype,
    };

    /// Information associated with the Node
    /// lhs and rhs may be used differently for each tag
    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };

    pub const TransactionPrototype = struct {
        date: Index,
        status: ?Index,
        payee: ?Index,
        postings_start: Index,
        postings_end: Index,
    };

    pub const PostingPrototype = struct {
        account: Index,
        commodity: ?Index,
        amount: ?Index,
    };
};

pub fn extraData(tree: Tree, index: usize, comptime T: type) T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    inline for (fields) |field, i| {
        comptime assert(field.field_type == Node.Index);
        @field(result, field.name) = tree.extra_data[index + i];
    }
    return result;
}
