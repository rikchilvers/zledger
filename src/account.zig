const std = @import("std");
const Amount = @import("amount.zig");
const Posting = @import("posting.zig");

const Self = @This();

name: []const u8,
/// Postings relevant to this account.
/// Indexes into the Journal's list of postings.
postings: std.ArrayList(usize),
amount: Amount,

/// NOTE: The allPostings ptr must be set separately to this.
pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
    var self = .{
        .name = name,
        .postings = std.ArrayList(usize).init(allocator),
        .amount = Amount.init(allocator),
    };
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    std.log.info("deinit {s}", .{self.name});
    self.amount.deinit(allocator);
    self.postings.deinit();
}
