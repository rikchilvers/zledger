const std = @import("std");

const Error = error{UnexpectedCharacter};

const Self = @This();

/// 0 for positive, 1 for negative
sign: u2,
/// Number of digits to the right of the decimal point
fractional: u32,
/// Total number of digits
digits: u32,
/// Array of digits. Most significant first.
source: [:0]const u8,

pub const RenderingInformation = struct {
    groupSeparator: u8 = 0, // e.g. 24,000
    decimalSeparator: u8 = 0, // e.g. 3.141
    indianNumbering: bool = false, // e.g. 10,00,000
};

pub fn initWithSource(allocator: std.mem.Allocator, source: [:0]const u8, renderingInformation: ?*RenderingInformation) !*Self {
    var decimal = allocator.create(Self) catch unreachable;
    errdefer allocator.destroy(decimal);

    decimal.sign = 0;
    decimal.fractional = 0;
    decimal.digits = 0;
    decimal.source = source;

    var groupSeparator: u8 = 0;
    var decimalSeparator: u8 = 0;
    var indianNumbering = false;

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
            ',', '_' => {
                // treat the first , or _ as the separator
                if (decimalSeparator == 0) {
                    decimal.fractional = decimal.digits + 1;
                    decimalSeparator = c;
                } else {}

                // TODO: handle incorrect thousand separators
                // TODO: handle commas as decimal deliniators
            },
            '.' => {
                decimal.fractional = decimal.digits + 1;
            },
            else => {
                // std.log.info("got a {}", .{c});
                return Error.UnexpectedCharacter;
            },
        }
    }

    if (decimal.fractional > 0) {
        decimal.fractional = decimal.digits - (decimal.fractional - 1);
    }

    if (renderingInformation) |ri| {
        ri.*.groupSeparator = groupSeparator;
        ri.*.decimalSeparator = decimalSeparator;
        ri.*.indianNumbering = indianNumbering;
    }
    return decimal;
}

/// Initialises the
pub fn init(allocator: std.mem.Allocator, number: [:0]const u8, separator: ?*RenderingInformation) !*Self {
    var source = allocator.allocSentinel(u8, std.mem.len(number), 0) catch unreachable;
    std.mem.copy(u8, source, number);
    return initWithSource(allocator, source, separator);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}

test "init allocates for source" {
    std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "3.14159", null);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);

    std.testing.allocator.free(d.source);
    d.deinit(std.testing.allocator);
}

test "parses integers" {
    std.testing.log_level = .debug;

    const s: [:0]const u8 = "314159";
    const d = try Self.initWithSource(std.testing.allocator, s, null);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);

    d.deinit(std.testing.allocator);
}

test "parsing returns error on unexpected character" {
    std.testing.log_level = .debug;

    const s: [:0]const u8 = "314159a";
    const d = Self.initWithSource(std.testing.allocator, s, null);

    try std.testing.expectError(Error.UnexpectedCharacter, d);
}

test "parses decimals with . as decimal separator" {
    std.testing.log_level = .debug;

    const s: [:0]const u8 = "3.14159";
    const d = try Self.initWithSource(std.testing.allocator, s, null);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);

    d.deinit(std.testing.allocator);
}

test "parses decimals with , as decimal separator" {
    std.testing.log_level = .debug;

    const s: [:0]const u8 = "3,14159";
    const d = try Self.initWithSource(std.testing.allocator, s, null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with thousand separators" {
    std.testing.log_level = .debug;

    const s: [:0]const u8 = "3,141,592.65";
    var ri = RenderingInformation{};
    const d = try Self.initWithSource(std.testing.allocator, s, &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 9), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);

    try std.testing.expectEqual(@as(u8, ','), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(false, ri.indianNumbering);
}

test "parses decimals with thousand separators after decimal point" {
    std.testing.log_level = .debug;

    const s: [:0]const u8 = "3_141_592.650_123_430";
    var ri = RenderingInformation{};
    const d = try Self.initWithSource(std.testing.allocator, s, null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 16), d.digits);
    try std.testing.expectEqual(@as(u32, 9), d.fractional);

    try std.testing.expectEqual(@as(u8, '_'), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(false, ri.indianNumbering);
}

test "parse indian notation" {
    std.testing.log_level = .debug;

    const s: [:0]const u8 = "3,14,15,926.501";
    var ri = RenderingInformation{};
    const d = try Self.initWithSource(std.testing.allocator, s, null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 11), d.digits);
    try std.testing.expectEqual(@as(u32, 3), d.fractional);

    try std.testing.expectEqual(@as(u8, ','), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(true, ri.indianNumbering);
}
