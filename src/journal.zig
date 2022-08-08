const Date = @import("datetime").Date;
const std = @import("std");
const Posting = @import("posting.zig");
const Account = @import("account.zig");
const AccountTree = @import("account_tree.zig");

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

pub fn addPosting(self: *Self, posting: Posting) !usize {
    const index = std.mem.len(self.postings.items);
    var p = try self.postings.addOne();
    p.* = posting;
    return index;
}
