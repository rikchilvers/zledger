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

pub fn deinit(tree: *Tree, gpa: std.mem.Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra_data);
    gpa.free(tree.errors);
    tree.* = undefined;
}

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
        expected_transaction,
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
        /// main_token: date
        /// lhs: index to data; 0 if no data
        /// rhs: unused
        transaction_declaration,

        /// main_token: index of transaction_declaration
        /// lhs: index to data
        /// rhs: unused
        transaction_body,

        /// main_token: account
        /// lhs: index of transaction_body
        /// rhs: index to data
        posting_prototype,
    };

    /// Information associated with the Node
    /// lhs and rhs may be used differently for each tag
    /// either may point to values in the Tree's extra_data array
    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };

    pub const TransactionDeclaration = struct {
        status: Index, // 0 if null
        payee: Index, // 0 if null
    };

    pub const TransactionBody = struct {
        postings_start: Index,
        postings_end: Index,
    };

    pub const Posting = struct {
        commodity: Index, // 0 if null
        amount: Index, // 0 if null
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
