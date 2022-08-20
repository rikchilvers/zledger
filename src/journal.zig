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

const PartialTransaction = struct {
    sum: Amount,
    /// The account from a posting with no account.
    /// There can only be one of these per xact.
    /// We don't store a reference to the account because it might have been invalidated before
    /// we use it (e.g. if the AccountTree's backing ArrayList was resized).
    incomplete_posting_account: ?usize,

    fn init(allocator: std.mem.Allocator) PartialTransaction {
        var self = .{
            .sum = Amount.init(allocator),
            .incomplete_posting_account = null,
        };

        return self;
    }

    fn deinit(self: *PartialTransaction, allocator: std.mem.Allocator) void {
        self.sum.deinit(allocator);
    }

    fn reset(self: *PartialTransaction) void {
        self.sum.zero();
        self.incomplete_posting_account = null;
    }

    fn validate(self: *PartialTransaction, tree: *AccountTree) void {
        if (self.incomplete_posting_account) |i| {
            const account = &tree.accounts.items[i];
            self.sum.setNegative();
            account.amount.add(&self.sum);
        }
    }
};

// Constructs a
pub fn read(self: *Self, ast: Ast) !void {
    var temp = Amount.init(self.allocator);
    temp.zero();

    var partial_xact = PartialTransaction.init(self.allocator);
    defer partial_xact.deinit(self.allocator);

    for (ast.nodes.items(.tag)) |tag, i| {
        switch (tag) {
            .root => {},
            .transaction_header => {
                partial_xact.validate(&self.account_tree);
                partial_xact.reset();

                const date = extractField(&ast, ast.nodes.items(.main_token)[i]);
                const data = ast.nodes.items(.data)[i];
                const header = ast.extraData(data.lhs, Ast.Node.TransactionHeader);
                const payee = extractOptionalField(&ast, header.payee) orelse "??";

                std.log.info("'{s}'  '{s}'", .{ date, payee });
            },
            .posting => {
                // We need to get the lhs of the posting node for the data
                const data = ast.nodes.items(.data)[i];
                const posting = ast.extraData(data.lhs, Ast.Node.Posting);

                const account_path = extractField(&ast, posting.account);
                const account_index = try self.account_tree.addAccount(account_path);
                const account = &self.account_tree.accounts.items[account_index];

                const amount = extractOptionalField(&ast, posting.amount);
                if (amount) |a| {
                    std.log.info("\t'{s}'  '{s}'", .{ account_path, a });
                    temp.set([]const u8, a);
                    account.addAmount(self.account_tree.accounts.items, &temp);
                    partial_xact.sum.add(&temp);
                } else {
                    std.log.info("\t'{s}'", .{account_path});
                    if (partial_xact.incomplete_posting_account != null) unreachable;
                    partial_xact.incomplete_posting_account = account_index;
                }
            },
            else => {
                // std.log.info(">> index {d: >2}: {} = {s}", .{ i, tag, "???" });
            },
        }
    }
    partial_xact.validate(&self.account_tree);
    partial_xact.reset();

    temp.deinit(self.allocator);
}

fn extractField(ast: *const Ast, index: usize) []const u8 {
    const start = ast.tokens.items(.start)[index];
    const end = ast.tokens.items(.end)[index];
    return ast.source[start..end];
}

fn extractOptionalField(ast: *const Ast, index: usize) ?[]const u8 {
    if (index == 0) return null;
    const start = ast.tokens.items(.start)[index];
    const end = ast.tokens.items(.end)[index];
    return ast.source[start..end];
}

pub fn addPosting(self: *Self, posting: Posting) !usize {
    const index = std.mem.len(self.postings.items);
    var p = try self.postings.addOne();
    p.* = posting;
    return index;
}

test "reads accounts" {
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

test "correctly parses postings" {
    std.testing.log_level = .debug;
    std.log.info("", .{});

    // const source =
    //     \\2020-01-02
    //     \\  a:b   $1
    //     \\  c:d   $-1
    //     \\
    //     \\2020-01-03  xyz
    //     \\
    //     \\  e:f   $2
    //     \\  a:b
    //     \\  c:d   $2
    // ;

    const source =
        \\2022-04-11 ! Test payee
        \\  account   £-10.01
        \\  another:account   £10.01
        \\
        \\2022-04-12 ! Test payee
        \\  account
        \\  another:account   £5
        \\
        \\2022-04-11 ! Test payee
        \\  account   £-100
        \\  another:account
    ;

    const allocator = std.testing.allocator;

    const parse = @import("parser.zig").parse;
    var ast = try parse(allocator, source);
    defer ast.deinit(allocator);

    var journal = try Self.init(allocator);
    defer journal.deinit();
    try journal.read(ast);

    const unbuffered_out = std.io.getStdOut().writer();
    var buffer = std.io.bufferedWriter(unbuffered_out);
    defer buffer.flush() catch unreachable;
    var out = buffer.writer();
    journal.account_tree.print(out);
}
