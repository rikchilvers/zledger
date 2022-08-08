// include all files with tests
comptime {
    _ = @import("tokenizer.zig");
    _ = @import("parse.zig");
    _ = @import("tree.zig");
    _ = @import("bigdecimal.zig");
    _ = @import("journal.zig");
}
