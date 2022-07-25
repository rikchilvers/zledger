const std = @import("std");

const Error = error{
    UnexpectedCharacter,
    IncorrectThousandMark,
};
const MaxCharacters = 64;

const Self = @This();

positive: bool,
/// Number of digits to the right of the decimal point
fractional: u32,
/// Total number of digits
digits: u32,
/// Array of digits. Most significant first.
source: []u8,
/// Whether the source was allocated by Self
ownedSource: bool,

pub const RenderingInformation = struct {
    thousandMark: u8 = 0, // e.g. 24,000
    decimalSeparator: u8 = 0, // e.g. 3.141
};

// This function does 3 different jobs.
//     1. Parse whether the sign of the decimal and how many total digits and fractional digits it has.
//     2. Identify how to render back if printed.
//     3. Remove all non-digit characters from the source.
pub fn initAndFormat(allocator: std.mem.Allocator, source: []u8, renderingInformation: ?*RenderingInformation) !*Self {
    var decimal = allocator.create(Self) catch unreachable;
    errdefer allocator.destroy(decimal);

    decimal.positive = true;
    decimal.fractional = 0;
    decimal.digits = 0;
    decimal.source = source;
    decimal.ownedSource = false;

    // Temporary storage of rendering information.
    var thousandMark: u8 = 0;
    var decimalSeparator: u8 = 0;

    // Index into the source
    var i: usize = 0;
    // Position of last thousand-mark
    var j: usize = 0;

    // We use two 32 byte arrays to temporarily hold digits either side of the decimal separator.
    // These will be later copied back into the source to remove grouping characters.
    std.debug.assert(std.mem.len(source) <= MaxCharacters);
    var tempInteger = [_]u8{0} ** (MaxCharacters / 2);
    var tempFractional = [_]u8{0} ** (MaxCharacters / 2);

    // Indices into the temp(Integer|Fractional) arrays
    var iI: usize = 0;
    var iF: usize = 0;

    // Find the sign
    if (source[i] == '-') {
        decimal.positive = false;
        i += 1;
    } else if (source[i] == '+') {
        i += 1;
    }

    // Skip over leading zeroes
    while (i < std.mem.len(source)) : (i += 1) {
        if (source[i] != '0') break;
    }

    while (i < std.mem.len(source)) : (i += 1) {
        const c = source[i];
        switch (c) {
            '0'...'9' => {
                decimal.digits += 1;

                if (decimalSeparator == 0) {
                    tempInteger[iI] = source[i];
                    iI += 1;
                } else {
                    tempFractional[iF] = source[i];
                    iF += 1;
                }
            },
            ',' => {
                switch (decimalSeparator) {
                    0 => {
                        // treat the first comma as a decimal separator
                        decimalSeparator = c;
                        decimal.fractional = decimal.digits + 1;
                    },
                    '.' => {
                        // if we've seen a period, we shouldn't be seeing commas
                        return Error.UnexpectedCharacter;
                    },
                    else => {},
                }

                if (thousandMark == '_') return Error.UnexpectedCharacter;

                if (j > 0 and i - j != 4) return Error.IncorrectThousandMark;

                j = i;
            },
            '_' => {
                if (thousandMark == ',') return Error.UnexpectedCharacter;
                if (j > 0 and i - j != 4) return Error.IncorrectThousandMark;
                thousandMark = '_';
                j = i;
            },
            '.' => {
                if (j > 0 and i - j != 4) return Error.IncorrectThousandMark;

                if (decimalSeparator == ',') {
                    thousandMark = ',';
                    // Because we previously treated a comma as the decimal separator,
                    // all the fraction digits should now be moved to the integer digits
                    if (iF > 0) {
                        std.mem.copy(u8, tempInteger[iI .. iI + iF], tempFractional[0..iF]);
                        std.mem.set(u8, tempFractional[0..iF], 0);
                    }
                    iI += iF;
                    iF = 0;
                }
                decimalSeparator = '.';

                decimal.fractional = decimal.digits + 1;
            },
            else => {
                return Error.UnexpectedCharacter;
            },
        }
    }

    // Until now, decimal.fractional has been storing the index of the first digit after the decimalSeparator.
    // We need to change this now to reflect the actual number of fractional digits.
    if (decimal.fractional > 0) {
        decimal.fractional = decimal.digits - (decimal.fractional - 1);
    }

    if (renderingInformation) |ri| {
        ri.*.thousandMark = thousandMark;
        ri.*.decimalSeparator = decimalSeparator;
    }

    // Replace the source with the formatted version.

    // Pad with preceding zeroes.
    const padding = std.mem.len(source) - iI - iF;
    std.mem.set(u8, source[0..padding], '0');

    // Copy the integer part
    std.mem.copy(u8, source[padding .. iI + padding], tempInteger[0..iI]);

    // Copy the fractional part
    // We don't need a decimal separator because we know how many fractional digits are in the number.
    std.mem.copy(u8, source[padding + iI .. padding + iI + iF], tempFractional[0..iF]);

    return decimal;
}

/// Initialises the Decimal along with space for its source
pub fn init(allocator: std.mem.Allocator, number: []const u8, separator: ?*RenderingInformation) !*Self {
    var source = allocator.allocSentinel(u8, std.mem.len(number), 0) catch unreachable;
    std.mem.copy(u8, source, number);
    errdefer allocator.free(source);
    var result = try initAndFormat(allocator, source, separator);
    result.ownedSource = true;
    return result;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.ownedSource) allocator.free(self.source);
    allocator.destroy(self);
}

// Expand the Decimal so that it has at least nDigit digits and nFractional digits to the right of the decimal point.
// This function expects that the decimal has been formatted to remove all non-digit characters
// Returns the number of unused characters at the start of the source (i.e. where the source could be sliced from)
pub fn expand(self: *Self, allocator: std.mem.Allocator, nDigit: u32, nFractional: u32) u32 {
    std.debug.assert(nDigit >= self.digits);

    const additionalDigits = nDigit - self.digits;
    const additionalFractional = nFractional - self.fractional;
    const additionalInteger = additionalDigits - additionalFractional;
    const available = std.mem.len(self.source) - self.digits;

    if (additionalDigits == 0) return @intCast(u32, available);

    // NOTE: During reallocation, sqlite3 adds 1 to how many chars are required in source. Why?
    //       See sqlite/ext/misc/decimal.c:381
    if (available >= additionalDigits) {
        // If we have space and there are no additional fractional digits, we can return now
        if (additionalFractional == 0) return @intCast(u32, available - additionalDigits);

        var scratch = [_]u8{'0'} ** 15;

        // Copy all significant digits (i.e. not any preceding unused characters) from source into scratch, making space for additional fractional.
        std.mem.copy(u8, scratch[available - additionalFractional ..], self.source[available..]);

        self.digits += additionalInteger;
        self.fractional += additionalFractional;

        // Update self.source
        std.mem.copy(u8, self.source[0..], scratch[0..std.mem.len(self.source)]);

        return @intCast(u32, available - additionalDigits);
    } else {
        var scratch = allocator.alloc(u8, nDigit) catch unreachable;

        if (additionalInteger > 0) {
            // [---314159]
            std.mem.copy(u8, scratch[additionalInteger..], self.source[available..]);
            // [00031459]
            std.mem.set(u8, scratch[0..additionalInteger], '0');

            self.digits += additionalInteger;
        } else {
            // [314159??]
            std.mem.copy(u8, scratch[0..std.mem.len(self.source)], self.source);
        }

        if (additionalFractional > 0) {
            // [314159000]
            std.mem.set(u8, scratch[nDigit .. nDigit + additionalFractional], '0');

            self.digits += additionalInteger;
            self.fractional += additionalFractional;
        }

        if (self.ownedSource) allocator.free(self.source);
        self.source = scratch;
        self.ownedSource = true;

        return 0;
    }
}

// Adds the value of other into self.
// Both self and other might be reallocated to new memory by this function.
// Both self and other might lose their original formatting.
pub fn add(self: *Self, allocator: std.mem.Allocator, other: *Self) void {
    var integerDigits = self.digits - self.fractional;
    if (integerDigits > 0 and self.source[0] == 0) integerDigits -= 1;
    if (integerDigits < other.digits - other.fractional) {
        integerDigits = other.digits - other.fractional;
    }

    var fractionalDigits = self.fractional;
    if (fractionalDigits < other.fractional) fractionalDigits = other.fractional;

    var totalDigits = integerDigits + fractionalDigits + 1;

    const available = self.expand(allocator, totalDigits, fractionalDigits);
    const otherAvailable = other.expand(allocator, totalDigits, fractionalDigits);

    if (available > otherAvailable) {}
}

test "init and format works" {
    // std.testing.log_level = .debug;

    var s = "03,141,592.65".*; // dereference the pointer to the array
    const d = try Self.initAndFormat(std.testing.allocator, &s, null); // pass by reference to get a slice
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 9), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "0000314159265", &s);
}

test "init allocates for source" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "3.14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses integers" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
}

test "parses positive integers" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "+314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
    try std.testing.expect(d.positive);
}

test "parses negative integers" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "-314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
    try std.testing.expect(!d.positive);
}

test "error on unexpected character" {
    // std.testing.log_level = .debug;

    const d = Self.init(std.testing.allocator, "314159a", null);
    try std.testing.expectError(Error.UnexpectedCharacter, d);
}

test "parses decimals with period as decimal separator" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "3.14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with comma as decimal separator" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "3,14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with thousand separators" {
    // std.testing.log_level = .debug;

    var ri = RenderingInformation{};
    const d = try Self.init(std.testing.allocator, "3,141,592.65", &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 9), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);

    try std.testing.expectEqual(@as(u8, ','), ri.thousandMark);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
}

test "errors on thousand-marks after decimal point" {
    const d = Self.init(std.testing.allocator, "3_141_592.650_123_430", null);
    try std.testing.expectError(Error.IncorrectThousandMark, d);
}

test "error on incorrect thousand-mark placement" {
    // std.testing.log_level = .debug;

    const a = Self.init(std.testing.allocator, "3,14,1592.501", null);
    try std.testing.expectError(Error.IncorrectThousandMark, a);

    const b = Self.init(std.testing.allocator, "31415,92.501", null);
    try std.testing.expectError(Error.IncorrectThousandMark, b);

    const c = Self.init(std.testing.allocator, "31415_92.501", null);
    try std.testing.expectError(Error.IncorrectThousandMark, c);
}

test "error on mixed thousand-marks" {
    const d = Self.init(std.testing.allocator, "3_141,592.01", null);
    try std.testing.expectError(Error.UnexpectedCharacter, d);
}

test "expand (local): no change" {
    std.testing.log_level = .debug;

    var s = "0031,415.92".*; // dereference the pointer to the array
    //       00003141592
    const d = try Self.initAndFormat(std.testing.allocator, &s, null); // pass by reference to get a slice
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "00003141592", &s);

    const spareChars = d.expand(std.testing.allocator, 7, 2);
    // should be no change to source during this expand
    try std.testing.expectEqualSlices(u8, "00003141592", &s);
    try std.testing.expectEqual(@as(u32, 4), spareChars);
}

test "expand (local): additional integers" {
    std.testing.log_level = .debug;

    var s = "0031,415.92".*; // dereference the pointer to the array
    //       00003141592
    const d = try Self.initAndFormat(std.testing.allocator, &s, null); // pass by reference to get a slice
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "00003141592", &s);

    const spareChars = d.expand(std.testing.allocator, 9, 2);
    // should be no change to source during this expand
    try std.testing.expectEqualSlices(u8, "00003141592", &s);
    try std.testing.expectEqual(@as(u32, 2), spareChars);
}

test "expand (local): additional fractional" {
    // std.testing.log_level = .debug;

    var s = "0031,415.92".*; // dereference the pointer to the array
    //       00003141592
    const d = try Self.initAndFormat(std.testing.allocator, &s, null); // pass by reference to get a slice
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "00003141592", &s);

    const spareChars = d.expand(std.testing.allocator, 8, 3);
    try std.testing.expectEqualSlices(u8, "00031415920", &s);
    try std.testing.expectEqual(@as(u32, 3), spareChars);
}

test "expand (local): additional integers and additional fractional" {
    // std.testing.log_level = .debug;

    var s = "0031,415.92".*; // dereference the pointer to the array
    //       00003141592
    const d = try Self.initAndFormat(std.testing.allocator, &s, null); // pass by reference to get a slice
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "00003141592", &s);

    const spareChars = d.expand(std.testing.allocator, 9, 3);
    try std.testing.expectEqualSlices(u8, "00031415920", &s);
    try std.testing.expectEqual(@as(u32, 2), spareChars);
}

test "expand (alloc): no change" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "0031,415.92", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "00003141592", d.source);

    const spareChars = d.expand(std.testing.allocator, 7, 2);
    // should be no change to source during this expand
    try std.testing.expectEqualSlices(u8, "00003141592", d.source);
    try std.testing.expectEqual(@as(u32, 4), spareChars);
}

test "expand (alloc): additional integers" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "3", null);
    defer d.deinit(std.testing.allocator);

    const spareChars = d.expand(std.testing.allocator, 2, 0);
    try std.testing.expectEqual(@as(u32, 0), spareChars);

    try std.testing.expectEqualSlices(u8, "03", d.source);
}

test "expand (alloc): additional fractional" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "3.1", null);
    defer d.deinit(std.testing.allocator);

    const spareChars = d.expand(std.testing.allocator, 3, 2);
    try std.testing.expectEqual(@as(u32, 0), spareChars);

    try std.testing.expectEqualSlices(u8, "310", d.source);
}

test "expand (alloc): additional integers and additional fractional" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "0031,415.92", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "00003141592", d.source);

    const spareChars = d.expand(std.testing.allocator, 9, 3);
    try std.testing.expectEqualSlices(u8, "00031415920", d.source);
    try std.testing.expectEqual(@as(u32, 2), spareChars);
}

// test "adds integers" {
//     const a = try Self.init(std.testing.allocator, "4", null);
//     const b = try Self.init(std.testing.allocator, "6", null);
//     defer a.deinit(std.testing.allocator);
//     defer b.deinit(std.testing.allocator);

//     a.add(std.testing.allocator, b);

//     try std.testing.expectEqualSlices(u8, "10", a.source);
// }
