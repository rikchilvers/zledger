const Date = @import("datetime").Date;
const std = @import("std");
const Posting = @import("posting.zig");
const Account = @import("account.zig");

// Here's my thinking: for most commands, we don't need to create anything other than the account tree.

// For the account tree:
// - https://stackoverflow.com/a/28643465

const Self = @This();

/// All the postings
const Postings = std.ArrayList(Posting);

/// All the accounts
/// TODO: consider making this a MultiArrayList instead
const Accounts = std.ArrayList(Account);
/// Maps the accounts to an index of the accounts ArrayList
const AccountsMap = std.StringHashMap(usize);
/// Maps an index of the accounts ArrayList to an ArrayList of indexes to the same ArrayList (children)
const AccountChildren = std.AutoHashMap(usize, std.ArrayList(usize));

allocator: std.mem.Allocator,

postings: Postings,

accounts: Accounts,
accounts_map: AccountsMap,
account_children: AccountChildren,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .postings = Postings.init(allocator),
        .accounts = Accounts.init(allocator),
        .accounts_map = AccountsMap.init(allocator),
        .account_children = AccountChildren.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.postings.deinit();

    for (self.accounts.items) |*account| account.deinit(self.allocator);
    self.accounts.deinit();

    self.accounts_map.deinit();

    var iter = self.account_children.valueIterator();
    while (iter.next()) |child_list| child_list.deinit();
    self.account_children.deinit();
}

/// Account names are case sensitive.
/// Returns the index into Journal's accounts ArrayList.
pub fn addAccount(self: *Self, account_path: []const u8) !usize {
    // TODO: handle this case: 'a:b:'. Should have accounts: 'a' and 'a:b:', not 'a', 'a:b' and 'a:b:'.

    // For the account_path a:b:c, we want to add three accounts:
    //      a
    //      a:b
    //      a:b:c

    // If we already have this account path stored, just return it.
    if (self.accounts_map.contains(account_path)) return self.accounts_map.get(account_path).?;

    // Add full path
    const account_index = std.mem.len(self.accounts.items);
    var account = Account.init(self.allocator, account_path, &self.postings);
    try self.accounts.append(account);
    try self.accounts_map.put(account_path, account_index);

    // Add parent, if there is one
    if (std.mem.lastIndexOf(u8, account_path, ":")) |index| {
        var parent = self.addAccount(account_path[0..index]) catch unreachable;

        // Add full path as parent
        var entry = try self.account_children.getOrPut(parent);
        if (!entry.found_existing) entry.value_ptr.* = std.ArrayList(usize).init(self.allocator);
        try entry.value_ptr.append(account_index);
    }

    return account_index;
}

/// Returned pointer will become invalid when the backing Arraylist is resized.
pub fn getAccount(self: *Self, account_path: []const u8) ?*Account {
    if (self.accounts_map.get(account_path)) |index| return &self.accounts.items[index];
    return null;
}

pub fn addPosting(self: *Self, posting: Posting) !usize {
    const index = std.mem.len(self.postings.items);
    var p = try self.postings.addOne();
    p.* = posting;
    return index;
}

test "adds and gets accounts" {
    var journal = Self.init(std.testing.allocator);
    defer journal.deinit();

    _ = try journal.addAccount("a:b:c");
    _ = try journal.addAccount("a:d");

    try std.testing.expectEqual(@as(usize, 4), std.mem.len(journal.accounts.items));

    const account_a = journal.getAccount("a");
    try std.testing.expectEqualSlices(u8, "a", account_a.?.name);

    const a_index = journal.accounts_map.get("a").?;
    const children = journal.account_children.get(a_index).?;
    try std.testing.expectEqual(@as(usize, 2), std.mem.len(children.items));
}
