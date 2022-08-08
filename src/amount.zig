const std = @import("std");
const BigDecimal = @import("bigdecimal.zig");
const Commodity = @import("commodity.zig");

const Self = @This();

quantity: *BigDecimal,
commodity: Commodity,

pub fn init(allocator: std.mem.Allocator) Self {
    var self = .{
        .quantity = BigDecimal.initAlloc(allocator),
        .commodity = .{},
    };

    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.quantity.deinit(allocator);
}
