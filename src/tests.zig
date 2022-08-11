// include all files with tests
comptime {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("ast.zig");
    _ = @import("big_decimal.zig");
    _ = @import("journal.zig");
    _ = @import("account_tree.zig");
    _ = @import("account.zig");
    _ = @import("amount.zig");
    _ = @import("commodity.zig");
    _ = @import("transaction.zig");
}

pub const TestString = @embedFile("../tests/example.txt");
