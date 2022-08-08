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

const Journal = @import("journal.zig");

postings: []Journal.Postings,
