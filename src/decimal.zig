const std = @import("std");

const Error = error{UnexpectedCharacter};

const Self = @This();

positive: bool,
/// Number of digits to the right of the decimal point
fractional: u32,
/// Total number of digits
digits: u32,
/// Array of digits. Most significant first.
source: [:0]const u8,
/// Whether the source can be freed during expand et al
safeToDeallocSource: bool,

pub const RenderingInformation = struct {
    groupSeparator: u8 = 0, // e.g. 24,000
    decimalSeparator: u8 = 0, // e.g. 3.141
    indianNumbering: bool = false, // e.g. 10,00,000
};

pub fn initWithSource(allocator: std.mem.Allocator, source: [:0]const u8, renderingInformation: ?*RenderingInformation) !*Self {
    var decimal = allocator.create(Self) catch unreachable;
    errdefer allocator.destroy(decimal);

    decimal.positive = true;
    decimal.fractional = 0;
    decimal.digits = 0;
    decimal.source = source;
    decimal.immutableSource = true;

    var groupSeparator: u8 = 0;
    var decimalSeparator: u8 = 0;
    var indianNumbering = false;

    // used to track index into the source
    var i: usize = 0;
    // used to track position of , in the source
    var j: usize = 0;

    // Skip over spaces at the start of the source
    while (true) : (i += 1) {
        if (source[i] != ' ') break;
    }

    // Find the sign
    if (source[i] == '-') {
        decimal.positive = false;
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
                switch (decimalSeparator) {
                    0 => {
                        // treat the first , as a decimal separator
                        decimalSeparator = c;
                        decimal.fractional = decimal.digits + 1;
                    },
                    '.' => {
                        // afterwards, treat it as a group separator
                        groupSeparator = ',';
                    },
                    else => {},
                }

                if (i - j == 3) {
                    // speculative at this point
                    indianNumbering = true;
                }
                j = i;
            },
            '_' => {
                groupSeparator = '_';
            },
            '.' => {
                if (decimalSeparator == ',') {
                    groupSeparator = ',';
                }
                decimalSeparator = '.';

                decimal.fractional = decimal.digits + 1;

                // If we've detected the number might be formated to match indian numbering,
                // the previous , should be 3 digits prior to the decimal point
                if (indianNumbering) {
                    indianNumbering = i - j == 4;
                }
            },
            else => {
                std.log.info("got a {}", .{c});
                return Error.UnexpectedCharacter;
            },
        }
    }

    // Up to now, decimal.fractional has been storing the index of the first digit after the decimalSeparator
    // We need to change this now to reflect the actual number of fractional digits
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

/// Initialises the Decimal along with space for its source
pub fn init(allocator: std.mem.Allocator, number: [:0]const u8, separator: ?*RenderingInformation) !*Self {
    var source = allocator.allocSentinel(u8, std.mem.len(number), 0) catch unreachable;
    std.mem.copy(u8, source, number);
    var result = initWithSource(allocator, source, separator);
    result.immutableSource = false;
    return result;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}

// Expand the Decimal so that it has at least nDigit digits and nFractional digits to the right of the decimal point.
pub fn expand(self: *Self, allocator: std.mem.Allocator, nDigit: u32, nFractional: u32) void {
    const additionalFractional = nFractional - self.fractional;
    const additionalInteger = (nDigit - self.digits) - additionalFractional;

    if (additionalFractional == 0 and additionalInteger == 0) return;

    // How many separators / decimal points there are
    const otherCharCount = std.mem.len(self.source) - self.digits;

    var newSource = allocator.allocSentinel(u8, std.mem.len(nDigit + otherCharCount + 1), 0) catch unreachable;

    if (additionalInteger > 0) {
        std.mem.copy(u8, newSource[additionalInteger..], self.source);
        std.mem.set(u8, newSource[0..additionalInteger], 0);

        self.digits += additionalInteger;
    } else {
        std.mem.copy(u8, newSource[0..std.mem.len(self.source)], self.source);
    }

    if (additionalFractional > 0) {
        self.digits += additionalInteger;
        self.fractional += additionalFractional;
    }

    if (self.safeToDeallocSource) allocator.free(self.source);
    self.source = newSource;
    self.safeToDeallocSource = true;
}

// Adds the value of other into self.
// Both self and other might be reallocated to new memory by this function.
// Both self and other might lose their original formatting.
pub fn add(self: *Self, allocator: std.mem.Allocator, other: *Self) void {
    if (other == null) return;

    var integerDigits = self.digits - self.fractional;
    if (integerDigits > 0 and self.source[0] == 0) integerDigits -= 1;
    if (integerDigits < other.digits - other.fractional) {
        integerDigits = other.digits - other.fractional;
    }

    var fractionalDigits = self.fractional;
    if (fractionalDigits < other.fractional) fractionalDigits = other.fractional;

    var totalDigits = integerDigits + fractionalDigits + 1;

    self.expand(allocator, totalDigits, fractionalDigits);
    other.expand(allocator, totalDigits, fractionalDigits);
}

test "init allocates for source" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "3.14159", null);
    defer d.deinit(std.testing.allocator);
    defer std.testing.allocator.free(d.source);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "ignores space at the start" {
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "   314159";
    const d = try Self.initWithSource(std.testing.allocator, s, null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
}

test "parses integers" {
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "314159";
    const d = try Self.initWithSource(std.testing.allocator, s, null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
}

test "parses positive integers" {
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "+314159";
    const d = try Self.initWithSource(std.testing.allocator, s, null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
    try std.testing.expect(d.positive);
}

test "parses negative integers" {
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "-314159";
    const d = try Self.initWithSource(std.testing.allocator, s, null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
    try std.testing.expect(!d.positive);
}

test "parsing returns error on unexpected character" {
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "314159a";
    const d = Self.initWithSource(std.testing.allocator, s, null);

    try std.testing.expectError(Error.UnexpectedCharacter, d);
}

test "parses decimals with . as decimal separator" {
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "3.14159";
    const d = try Self.initWithSource(std.testing.allocator, s, null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with , as decimal separator" {
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "3,14159";
    const d = try Self.initWithSource(std.testing.allocator, s, null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with thousand separators" {
    // std.testing.log_level = .debug;

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
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "3_141_592.650_123_430";
    var ri = RenderingInformation{};
    const d = try Self.initWithSource(std.testing.allocator, s, &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 16), d.digits);
    try std.testing.expectEqual(@as(u32, 9), d.fractional);

    try std.testing.expectEqual(@as(u8, '_'), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(false, ri.indianNumbering);
}

test "parses indian notation" {
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "3,14,15,926.501123";
    var ri = RenderingInformation{};
    const d = try Self.initWithSource(std.testing.allocator, s, &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 14), d.digits);
    try std.testing.expectEqual(@as(u32, 6), d.fractional);

    try std.testing.expectEqual(@as(u8, ','), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(true, ri.indianNumbering);
}

test "parses random notation" {
    // std.testing.log_level = .debug;

    const s: [:0]const u8 = "3,14,15,92,6.501";
    var ri = RenderingInformation{};
    const d = try Self.initWithSource(std.testing.allocator, s, &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 11), d.digits);
    try std.testing.expectEqual(@as(u32, 3), d.fractional);

    try std.testing.expectEqual(@as(u8, ','), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(false, ri.indianNumbering);
}

test "adds integers" {
    const a: [:0]const u8 = "4";
    const b: [:0]const u8 = "6";
    const aD = try Self.initWithSource(std.testing.allocator, a, null);
    const bD = try Self.initWithSource(std.testing.allocator, b, null);
    defer aD.deinit(std.testing.allocator);
    defer bD.deinit(std.testing.allocator);

    a.add(b);

    try std.testing.expectEqualSentinel(u8, 0, "10", a.source);
}
