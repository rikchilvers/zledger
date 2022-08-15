const std = @import("std");
const Amount = @import("amount.zig");
const Posting = @import("posting.zig");
const BigDecimal = @import("big_decimal.zig");

const Self = @This();

name: []const u8,
// Index into an AccountTree
parent: ?usize,
/// Postings relevant to this account.
/// Indexes into the Journal's list of postings.
postings: std.ArrayList(usize),
amount: Amount,

pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
    var self = .{
        .name = name,
        .parent = null,
        .postings = std.ArrayList(usize).init(allocator),
        .amount = Amount.init(allocator),
    };
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.amount.deinit(allocator);
    self.postings.deinit();
}

pub fn addAmount(self: *Self, accounts: []Self, amount: *BigDecimal) void {
    self.amount.quantity.add(amount);
    if (self.parent) |p| {
        var parent = accounts[p];
        parent.addAmount(accounts, amount);
    }
}
