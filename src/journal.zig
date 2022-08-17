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
    /// Postings relevant to this xact.
    /// Indexes into the Ast's nodes.
    postings: std.ArrayList(usize),
    /// A posting that does not have an amount.
    /// There can only be one of these per xact.
    incomplete_posting: ?usize,

    fn init(allocator: std.mem.Allocator) PartialTransaction {
        var self = .{
            .postings = std.ArrayList(usize).init(allocator),
            .incomplete_posting = null,
        };

        return self;
    }

    fn deinit(self: *PartialTransaction) void {
        self.postings.deinit();
    }

    fn reset(self: *PartialTransaction) void {
        self.postings.clearRetainingCapacity();
        self.incomplete_posting = null;
    }

    fn validate(self: *PartialTransaction) void {
        if (self.incomplete_posting) |i| {
            std.log.info("have an incomplete posting ?? at {d}", .{i});
        }
    }
};

// Constructs a
pub fn read(self: *Self, ast: Ast) !void {
    var temp = Amount.init(self.allocator);
    try temp.set("0.0");

    var partial_xact = PartialTransaction.init(self.allocator);
    defer partial_xact.deinit();

    for (ast.nodes.items(.tag)) |tag, i| {
        switch (tag) {
            .root => {},
            .transaction_header => {
                partial_xact.validate();
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
                    try temp.set(a);
                    account.addAmount(self.account_tree.accounts.items, &temp);
                } else {
                    std.log.info("\t'{s}'", .{account_path});
                    if (partial_xact.incomplete_posting != null) unreachable;
                    partial_xact.incomplete_posting = i;
                }
            },
            else => {
                // std.log.info(">> index {d: >2}: {} = {s}", .{ i, tag, "???" });
            },
        }
    }

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

test "correctly parses postings" {
    std.testing.log_level = .debug;
    std.log.info("", .{});

    const source =
        \\2020-01-02
        \\  a:b   $1
        \\  c:d   $-1
        \\
        \\2020-01-03  xyz
        \\  e:f   $2
        \\  c:d
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
