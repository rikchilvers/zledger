const std = @import("std");
// const Date = @import("datetime").Date;
const Posting = @import("posting.zig");
const AccountTree = @import("account_tree.zig");
const Ast = @import("ast.zig");
const BigDecimal = @import("big_decimal.zig");

const Self = @This();

/// All the postings
pub const Postings = std.ArrayList(Posting);

allocator: std.mem.Allocator,
postings: Postings,
account_tree: AccountTree,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .postings = Postings.init(allocator),
        .account_tree = AccountTree.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.postings.deinit();
    self.account_tree.deinit();
}

pub fn read(self: *Self, ast: Ast) !void {
    _ = self;

    var sum = BigDecimal.initAlloc(self.allocator);
    try sum.set("0.0");

    var temp = BigDecimal.initAlloc(self.allocator);
    try temp.set("0.0");

    std.log.info("node tags:", .{});
    for (ast.nodes.items(.tag)) |tag, i| {
        switch (tag) {
            .transaction_declaration => {
                const main_token_index = ast.nodes.items(.main_token)[i];

                const token_start = ast.tokens.items(.start)[main_token_index];
                const token_end = ast.tokens.items(.start)[main_token_index + 1];
                const token = ast.source[token_start .. token_end - 1];

                std.log.info("xact date = '{s}'", .{token});
            },
            .posting => {
                const dataIndex = ast.nodes.items(.data)[i].rhs;
                const extra = Ast.extraData(ast, dataIndex, Ast.Node.Posting).amount;

                if (extra == 0) continue;

                const token_start = ast.tokens.items(.start)[extra];
                const token_end = ast.tokens.items(.start)[extra + 1];
                var token = ast.source[token_start .. token_end - 1];

                // Handle trailing characters in the token
                if (std.mem.len(token) > 0) {
                    if (token[std.mem.len(token) - 1] == '\n') {
                        token = token[0 .. std.mem.len(token) - 1];
                    }
                }

                std.log.info("setting to '{s}'", .{token});
                try temp.set(token);
                sum.add(temp);
            },
            else => {
                std.log.info("{d: >2}: {} = {s}", .{ i, tag, "???" });
            },
        }
    }

    sum.print();
    sum.deinit(self.allocator);
    temp.deinit(self.allocator);
    try BigDecimal.cleanUpMemory();
}

pub fn addPosting(self: *Self, posting: Posting) !usize {
    const index = std.mem.len(self.postings.items);
    var p = try self.postings.addOne();
    p.* = posting;
    return index;
}
