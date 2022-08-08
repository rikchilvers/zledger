const std = @import("std");

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

    std.log.info("file:\n{s}", .{ptr});
}
