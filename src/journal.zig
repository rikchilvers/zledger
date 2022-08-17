const std = @import("std");
// const Date = @import("datetime").Date;
const Posting = @import("posting.zig");
const AccountTree = @import("account_tree.zig");
const Ast = @import("ast.zig");
const Amount = @import("amount.zig");

const Self = @This();

/// All the postings
pub const Postings = std.ArrayList(Posting);

allocator: std.mem.Allocator,
postings: Postings,
account_tree: AccountTree,

pub fn init(allocator: std.mem.Allocator) !Self {
    var self = .{
        .allocator = allocator,
        .postings = Postings.init(allocator),
        .account_tree = try AccountTree.init(allocator),
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.postings.deinit();
    self.account_tree.deinit();
}

pub fn read(self: *Self, ast: Ast) !void {
    var temp = Amount.init(self.allocator);
    try temp.set("0.0");

    for (ast.nodes.items(.tag)) |tag, i| {
        switch (tag) {
            .root => {},
            .transaction_declaration => {
                const main_token_index = ast.nodes.items(.main_token)[i];

                const token_start = ast.tokens.items(.start)[main_token_index];
                const token_end = ast.tokens.items(.start)[main_token_index + 1];
                const token = ast.source[token_start .. token_end - 1];
                _ = token;
            },
            .posting => {
                const account_path = extractAccount(&ast, i);
                const account_index = try self.account_tree.addAccount(account_path);
                const account = &self.account_tree.accounts.items[account_index];

                const amount = extractAmount(&ast, i);
                if (amount) |a| {
                    try temp.set(a);
                    account.addAmount(self.account_tree.accounts.items, &temp);
                }
            },
            else => {
                std.log.info("{d: >2}: {} = {s}", .{ i, tag, "???" });
            },
        }
    }

    temp.deinit(self.allocator);
}

fn extractAccount(ast: *const Ast, token_index: usize) []const u8 {
    const index = ast.nodes.items(.main_token)[token_index];
    const start = ast.tokens.items(.start)[index];
    const end = ast.tokens.items(.start)[index + 1];
    // TODO: move this trim to the tokenizer
    return std.mem.trimRight(u8, ast.source[start .. end - 1], " ");
}

fn extractAmount(ast: *const Ast, token_index: usize) ?[]const u8 {
    const index = ast.nodes.items(.data)[token_index].rhs;
    const extra = Ast.extraData(ast.*, index, Ast.Node.Posting).amount;

    if (extra == 0) return null;

    const start = ast.tokens.items(.start)[extra];
    const end = ast.tokens.items(.start)[extra + 1];

    // When the amount is in the final posting of a transaction, we can end up with a trailing
    // new line char so we trim here.
    // TODO: could this be handled in the tokenizer?
    return std.mem.trimRight(u8, ast.source[start .. end - 1], " \n\r\t\x0A");
}

pub fn addPosting(self: *Self, posting: Posting) !usize {
    const index = std.mem.len(self.postings.items);
    var p = try self.postings.addOne();
    p.* = posting;
    return index;
}

test "reads accounts" {
    std.testing.log_level = .debug;
    std.log.info("", .{});

    const source =
        \\2022-04-11 ! Payee One
        \\  a       £-10.50
        \\  b:c     £ 10.50
        \\
        \\2022-04-12 * Payee Two
        \\  a       £-20
        \\  b:d     £ 20
        \\2022-04-11 Payee One
        \\  a       £-100
        \\  b:c     £ 100
    ;

    const allocator = std.testing.allocator;

    const parse = @import("parser.zig").parse;
    var ast = try parse(allocator, source);
    defer ast.deinit(allocator);

    var journal = try Self.init(allocator);
    defer journal.deinit();

    try journal.read(ast);
}
