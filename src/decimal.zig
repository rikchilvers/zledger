const std = @import("std");

const Self = @This();

/// 0 for positive, 1 for negative
sign: u2,
/// Number of digits to the right of the decimal point
fractional: u32,
/// Total number of digits
digits: u32,
/// Array of digits. Most significant first.
source: [:0]const u8,

pub fn initWithSource(allocator: std.mem.Allocator, source: [:0]const u8) *Self {
    var decimal = allocator.create(Self) catch unreachable;

    decimal.sign = 0;
    decimal.fractional = 0;
    decimal.digits = 0;
    decimal.source = source;

    // TODO: parse the source

    // used to track index into the source
    var i: usize = 0;

    // Skip over spaces at the start of the source
    while (true) : (i += 1) {
        if (source[i] != ' ') break;
    }

    // Find the sign
    if (source[i] == '-') {
        decimal.sign = 1;
        i += 1;
    } else if (source[i] == '+') {
        i += 1;
    }

    // skip over leading zeroes
    while (i < std.mem.len(source)) : (i += 1) {
        if (source[i] != '0') break;
    }

    while (i < std.mem.len(source)) : (i += 1) {
        const c = source[i];

        switch (c) {
            '0'...'9' => {
                decimal.digits += 1;
            },
            ',' => {
                // TODO: handle incorrect thousand separators
                // TODO: handle commas as decimal deliniators
            },
            '.' => {
                decimal.fractional = decimal.digits + 1;
            },
            else => unreachable,
        }
    }

    if (decimal.fractional > 0) {
        decimal.fractional = decimal.digits - (decimal.fractional - 1);
    }

    return decimal;
}

/// Initialises the
pub fn init(allocator: std.mem.Allocator, number: []const u8) *Self {
    _ = allocator;
    _ = number;
    unreachable;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    _ = self;
    _ = allocator;
    unreachable;
}

test "init with source" {
    const s: [:0]const u8 = "3.14159";
    const d = Self.initWithSource(std.testing.allocator, s);
    // defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}
