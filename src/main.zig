const std = @import("std");
const parse = @import("parser.zig").parse;
const Journal = @import("journal.zig");
const BigDecimal = @import("big_decimal.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const fd = try std.os.open(args[1], std.os.O.RDONLY, 0);
    var stats = try std.os.fstat(fd);
    var ptr = try std.os.mmap(
        // ptr
        null,
        //  length
        @intCast(usize, stats.size),
        // prot
        std.os.PROT.READ,
        // flags
        std.os.MAP.PRIVATE,
        // fd
        fd,
        // offset
        0,
    );

    var ast = try parse(allocator, ptr);
    defer ast.deinit(allocator);
    var journal = try Journal.init(allocator);
    defer journal.deinit();
    try journal.read(ast);

    const unbuffered_out = std.io.getStdOut().writer();
    var buffer = std.io.bufferedWriter(unbuffered_out);
    defer buffer.flush() catch unreachable;
    var out = buffer.writer();
    journal.account_tree.print(out);

    try BigDecimal.cleanUpMemory();
}
