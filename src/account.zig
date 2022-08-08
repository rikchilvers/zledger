const std = @import("std");
const Amount = @import("amount.zig");
const Posting = @import("posting.zig");

const Self = @This();

name: []const u8,
/// The Journal's list of all postings.
allPostings: *std.ArrayList(Posting),
/// Postings relevant to this account.
/// Indexes into the allPostings array.
postings: std.ArrayList(usize),
amount: Amount,

pub fn init(allocator: std.mem.Allocator, name: []const u8, allPostings: *std.ArrayList(Posting)) Self {
    var self = .{
        .name = name,
        .allPostings = allPostings,
        .postings = std.ArrayList(usize).init(allocator),
        .amount = Amount.init(allocator),
    };
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.amount.deinit(allocator);
    self.postings.deinit();
}
