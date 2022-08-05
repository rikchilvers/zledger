const Date = @import("datetime").Date;
const std = @import("std");

// Transaction holds details about an individual transaction
// type Transaction struct {
// 	Date                    time.Time
// 	State                   TransactionState
// 	Payee                   string
// 	Postings                []*Posting
// 	postingWithElidedAmount *Posting
// 	HeaderNote              string   // note in the header
// 	Notes                   []string // notes under the header
// }
// pub const Transaction = struct {
//     pub const State = enum { pending, cleared };

//     date: Date,
//     state: ?State,
//     payee: []const u8,
//     // posting
// };

pub const Account = struct {
    /// Indexes into the posting array
    postings: Journal.Postings,
};

pub const Posting = struct {};

pub const Amount = struct {};

// Here's my thinking: for most commands, we don't need to create anything other than the account tree.

// For the account tree:
// - https://stackoverflow.com/a/28643465

pub const Journal = struct {
    const Self = @This();

    /// All the postings
    const Postings = std.ArrayList(Posting);

    /// All the accounts
    /// TODO: consider making this a MultiArrayList instead
    const Accounts = std.ArrayList(Account);
    /// Maps the accounts to an index of the accounts ArrayList
    const AccountsMap = std.StringHashMap(usize);
    /// Maps an index of the accounts ArrayList to an ArrayList of indexes to the same ArrayList (children)
    const AccountChildren = std.HashMap(usize, std.ArrayList(usize));

    allocator: std.mem.Allocator,

    accounts: Accounts,
    accountsMap: AccountsMap,
    accountChildren: AccountChildren,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .accounts = Accounts.init(allocator),
            .accountsMap = AccountsMap.init(allocator),
            .accountChildren = AccountChildren.init(allocator),
        };
    }

    /// Add a node to the graph.
    pub fn add(self: *Self, accountPath: [:0]const u8) !void {
        // If we already have this node, then do nothing.
        if (self.accountsMap.contains(accountPath)) return;
    }
};

test "" {}
