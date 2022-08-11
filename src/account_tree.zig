// For the account tree:
// - https://stackoverflow.com/a/28643465

const std = @import("std");
const Account = @import("account.zig");

const Self = @This();

allocator: std.mem.Allocator,
/// All the accounts
/// TODO: consider making this a MultiArrayList instead
accounts: std.ArrayList(Account),
/// Maps the accounts to an index of the accounts ArrayList
accounts_map: std.StringHashMap(usize),
/// Maps an index of the accounts ArrayList to an ArrayList of indices to the same ArrayList (children)
account_children: std.AutoHashMap(usize, std.ArrayList(usize)),

pub fn init(allocator: std.mem.Allocator) !Self {
    var self = .{
        .allocator = allocator,
        .accounts = std.ArrayList(Account).init(allocator),
        .accounts_map = std.StringHashMap(usize).init(allocator),
        .account_children = std.AutoHashMap(usize, std.ArrayList(usize)).init(allocator),
    };

    const path = "root";
    var root = Account.init(allocator, path);
    try self.accounts.append(root);
    try self.accounts_map.put(path, 0);
    try self.account_children.put(0, std.ArrayList(usize).init(self.allocator));

    return self;
}

pub fn deinit(self: *Self) void {
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

    // Extract tail
    const last_colon = std.mem.lastIndexOf(u8, account_path, ":");
    const name = blk: {
        if (last_colon) |index| {
            break :blk account_path[index + 1 ..];
        } else {
            break :blk account_path;
        }
    };

    // Add full path
    const account_index = std.mem.len(self.accounts.items);
    var account = Account.init(self.allocator, name);
    try self.accounts.append(account);
    try self.accounts_map.put(account_path, account_index);

    // Add parent, if there is one
    if (last_colon) |index| {
        var parent = self.addAccount(account_path[0..index]) catch unreachable;

        var child = &self.accounts.items[account_index];
        child.parent = parent;

        // Make the current account a child of the parent
        var entry = try self.account_children.getOrPut(parent);
        if (!entry.found_existing) entry.value_ptr.* = std.ArrayList(usize).init(self.allocator);
        try entry.value_ptr.append(account_index);
    } else {
        // Add this account as a child of root
        var root_children = self.account_children.getPtr(0).?;
        try root_children.append(account_index);

        // Make root the parent of this account
        var child = &self.accounts.items[account_index];
        child.parent = 0;
    }

    return account_index;
}

/// Returned pointer will become invalid when the backing Arraylist is resized.
pub fn getAccount(self: *Self, account_path: []const u8) ?*Account {
    if (self.accounts_map.get(account_path)) |index| return &self.accounts.items[index];
    return null;
}

pub fn toString(self: *Self) void {
    const unbuffered_out = std.io.getStdOut().writer();
    var buffer = std.io.bufferedWriter(unbuffered_out);
    var out = buffer.writer();

    self.printChildren(0, 0, out);

    buffer.flush() catch unreachable;
}

fn printChildren(self: *Self, account: usize, indent: u8, writer: anytype) void {
    // TODO: consider moving this to self
    var buf = [_]u8{0} ** 64;

    var children = self.account_children.getPtr(account);
    if (children == null) return;
    for (children.?.items) |index| {
        const child = self.accounts.items[index];

        const out = child.amount.quantity.*.write(&buf);
        writer.print("{s: >22}  ", .{out}) catch unreachable;

        var i = indent;
        while (i > 0) : (i -= 1) {
            writer.print("  ", .{}) catch unreachable;
        }

        writer.print("{s}\n", .{child.name}) catch unreachable;

        self.printChildren(index, indent + 1, writer);
    }
}

test "adds and gets accounts" {
    std.testing.log_level = .debug;
    std.log.info("", .{});

    var tree = try Self.init(std.testing.allocator);
    defer tree.deinit();

    const abc_index = try tree.addAccount("a:b:c");
    _ = try tree.addAccount("a:d");

    // We expect 5 because of the root
    try std.testing.expectEqual(@as(usize, 5), std.mem.len(tree.accounts.items));

    const account_a = tree.getAccount("a");
    try std.testing.expectEqualSlices(u8, "a", account_a.?.name);
    try std.testing.expectEqual(@as(usize, 0), account_a.?.parent);

    try std.testing.expectEqual(@as(usize, 2), tree.accounts.items[abc_index].parent);

    const a_index = tree.accounts_map.get("a").?;
    const children = tree.account_children.get(a_index).?;
    try std.testing.expectEqual(@as(usize, 2), std.mem.len(children.items));
}

test "prints tree" {
    std.testing.log_level = .debug;
    std.log.info("", .{});

    var tree = try Self.init(std.testing.allocator);
    defer tree.deinit();

    _ = try tree.addAccount("a:b:c");
    _ = try tree.addAccount("a:d");

    tree.toString();
}
