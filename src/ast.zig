//! Abstract Syntax Ast for Zig source code.

/// Reference to externally-owned data.
source: []const u8,

tokens: TokenList.Slice,
/// The root AST node is assumed to be index 0. Since there can be no
/// references to the root node, this means 0 is available to indicate null.
nodes: NodeList.Slice,
extra_data: []Node.Index,

errors: []const Error,

const std = @import("std");
const assert = std.debug.assert;
const Token = @import("tokenizer.zig").Token;
const Ast = @This();

pub const ByteOffset = u32;
pub const TokenIndex = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: Ast.ByteOffset,
    end: Ast.ByteOffset,
});
pub const NodeList = std.MultiArrayList(Node);

pub fn deinit(tree: *Ast, gpa: std.mem.Allocator) void {
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

        /// main_token: import keyword
        /// lhs: path
        /// rhs: unused
        import,

        /// main_token: the comment
        /// lhs: transaction_header if in a transaction
        /// rhs: unused
        comment_line,

        /// main_token: begin keyword
        /// lhs: transaction_header if in a transaction
        /// rhs: end keyword
        comment_block,

        /// main_token: date
        /// lhs: TransactionHeader in extra_data
        /// rhs: unused
        transaction_header,

        /// main_token: indentation that starts the posting
        /// lhs: Posting in extra_data
        /// rhs: transaction_header node index
        posting,
    };

    /// Information associated with the Node
    /// lhs and rhs may be used differently for each tag
    /// either may point to values in the Ast's extra_data array
    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };

    pub const TransactionHeader = struct {
        status: Index,
        payee: Index,
        comment: Index, // 0 if null
    };

    pub const Posting = struct {
        account: Index,
        commodity: Index, // 0 if null
        amount: Index, // 0 if null
        comment: Index, // 0 if null
    };
};

pub fn extraData(tree: Ast, index: usize, comptime T: type) T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    inline for (fields) |field, i| {
        comptime assert(field.field_type == Node.Index);
        @field(result, field.name) = tree.extra_data[index + i];
    }
    return result;
}
