const std = @import("std");
const BigDecimal = @import("big_decimal.zig");
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

pub fn set(self: *Self, value: []const u8) !void {
    try self.quantity.set(value);
}

pub fn add(self: *Self, value: *Self) void {
    self.quantity.add(value.quantity);
}
