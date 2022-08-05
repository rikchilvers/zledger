const std = @import("std");
// const datetime = @import("datetime").datetime;
// const Date = datetime.Date;

const Decimal = @import("./decimal.zig");

const repetitions = 1000000;

pub fn main() !void {
    // const d = try Date.create(2020, 01, 01);
    // std.log.info("All your codebase are belong to us. {d}", .{d.year});

    // var number = [_]u8{ '4', '3', '.', '0', '1' };
    var number = [_]u8{ '4', '.', '2' };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var list = std.ArrayList([]u8).init(allocator);
    defer list.deinit();
    var i: usize = 1;
    while (i < repetitions + 1) : (i += 1) {
        try list.append(number[0..]);
    }

    if (std.mem.len(args) > 1) {
        try float(list);
    } else {
        try decimal(allocator, list);
    }
}

fn float(list: std.ArrayList([]u8)) !void {
    var sum: f64 = 0;
    for (list.items) |item| {
        sum += try std.fmt.parseFloat(f64, item);
    }

    std.log.info("sum = {d:.2}", .{sum});
}

fn decimal(allocator: std.mem.Allocator, list: std.ArrayList([]u8)) !void {
    var sum = try Decimal.initAlloc(allocator, "0", null);
    for (list.items) |*item| {
        const a = try Decimal.init(item.*, null);
        sum.add(allocator, &a);
    }

    std.log.info("sum = {s}", .{sum.source});
}
