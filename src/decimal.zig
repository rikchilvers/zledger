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

// Does not allocate for the source and does not format
pub fn parse(allocator: std.mem.Allocator, source: []u8, renderingInformation: ?*RenderingInformation) !*Self {
    _ = allocator;
    _ = source;
    _ = renderingInformation;
    unreachable;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.ownedSource) allocator.free(self.source);
    allocator.destroy(self);
}

// Expand the Decimal so that it has at least nDigit digits and nFractional digits.
// This function expects that the decimal has been formatted to remove all non-digit characters.
// Returns the number of unused characters at the start of the source.
pub fn expand(self: *Self, allocator: std.mem.Allocator, nDigits: u32, nFractional: u32) u32 {
    // Skip over zeroes
    var available: u32 = 0;
    while (available < std.mem.len(self.source)) : (available += 1) {
        if (self.source[available] != '0') break;
    }

    // We do this calculation because the number of digits might have drifted out
    self.digits = @intCast(u32, std.mem.len(self.source)) - available;

    if (self.digits >= nDigits and self.fractional >= nFractional) return available;

    const addDigits = nDigits - self.digits;
    const addFrac = if (self.fractional >= nFractional) 0 else nFractional - self.fractional;
    const addInt = addDigits - addFrac;

    if (available >= addFrac + addInt) {
        if (addFrac == 0) {
            // If there are no additional decimal digits, we don't need to move anything around:
            // we can just tell self that some of the available space is now used.
            self.digits += addInt;
            return available - addInt;
        }

        // TODO: check we won't overflow this
        var scratch = [_]u8{'0'} ** MaxCharacters;

        // Copy all significant digits (i.e. not any preceding unused characters) from source into scratch, making space for additional fractional.
        std.mem.copy(u8, scratch[available - addFrac ..], self.source[available..]);

        // Update self.source
        std.mem.copy(u8, self.source[0..], scratch[0..std.mem.len(self.source)]);
        self.digits += addInt + addFrac;
        self.fractional += addFrac;

        return available - addInt - addFrac;
    } else {
        const size = self.digits + addInt + addFrac;
        var scratch = allocator.alloc(u8, size) catch unreachable;

        if (addInt > 0) {
            // [---314159]
            std.mem.copy(u8, scratch[addInt..], self.source[available..]);
            // [00031459]
            std.mem.set(u8, scratch[0..addInt], '0');

            self.digits += addInt;
        } else {
            // [314159??]
            std.mem.copy(u8, scratch[0..], self.source);
        }

        if (addFrac > 0) {
            // [314159000]
            std.mem.set(u8, scratch[size - 1 ..], '0');

            self.digits += addFrac;
            self.fractional += addFrac;
        }

        if (self.ownedSource) allocator.free(self.source);
        self.source = scratch;
        self.ownedSource = true;

        return 0;
    }
}

// Expand the Decimal so that it has at least nDigit digits and nFractional digits.
// This function expects that the decimal has been formatted to remove all non-digit characters.
// Returns the number of unused characters at the start of the source.
pub fn oldExpand(self: *Self, allocator: std.mem.Allocator, nDigit: u32, nFractional: u32) u32 {
    std.debug.assert(nDigit >= self.digits);

    std.log.info("expanding {d} to {d}:{d}", .{ self.source, nDigit, nFractional });

    var available: usize = 0;
    while (available < std.mem.len(self.source)) : (available += 1) {
        if (self.source[available] != '0') break;
    }

    std.log.info("\t{d} available", .{available});
    const additionalDigits = nDigit - self.digits;
    const additionalFractional = nFractional - self.fractional;
    const additionalInteger = additionalDigits - additionalFractional;

    std.log.info("+D = {d}\t+F = {d}\t\t+I = {d}", .{
        additionalDigits,
        additionalFractional,
        additionalInteger,
    });

    if (additionalDigits == 0) return @intCast(u32, available);

    // NOTE: During reallocation, sqlite3 adds 1 to how many chars are required in source. Why?
    //       See sqlite/ext/misc/decimal.c:381
    if (available >= additionalDigits) {
        std.log.info("\thave enough available", .{});
        // If we have space and there are no additional fractional digits, we can return now
        if (additionalFractional == 0) {
            self.digits += additionalInteger;
            return @intCast(u32, available - additionalDigits);
        }

        var scratch = [_]u8{'0'} ** MaxCharacters;
        // TODO: add check that we won't go beyond this

        // Copy all significant digits (i.e. not any preceding unused characters) from source into scratch, making space for additional fractional.
        std.mem.copy(u8, scratch[available - additionalFractional ..], self.source[available..]);

        // self.digits += additionalInteger;
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
            std.mem.set(u8, scratch[nDigit - 1 ..], '0');

            self.digits += additionalFractional;
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
pub fn add(self: *Self, allocator: std.mem.Allocator, other: *Self) void {
    std.log.info("\n>> add {s} to {s}", .{ other.source, self.source });

    var integerDigits = self.digits - self.fractional;
    var otherIntegers = other.digits - other.fractional;
    // if (integerDigits > 0 and self.source[0] == 0) integerDigits -= 1;
    // if (otherIntegers > 0 and other.source[0] == 0) otherIntegers -= 1;
    if (integerDigits < otherIntegers) integerDigits = otherIntegers;

    var fractionalDigits = self.fractional;
    if (fractionalDigits < other.fractional) fractionalDigits = other.fractional;

    const totalDigits = integerDigits + fractionalDigits + 1;

    // Self and other might have padding zeroes as a result of formatting while they were being parsed.
    // To compare them later, we need to skip these.
    //
    // FIXME: instead of having expand pass back the space, we could just do len - digits
    std.log.info(">> expand self", .{});
    const available = self.oldExpand(allocator, totalDigits, fractionalDigits);

    // FIXME: I don't think this is the correct adjustment. Maybe just while over the zeroes?
    const otherAvailable = std.mem.len(other.source) - other.digits;

    if (self.positive == other.positive) {
        var carry: u8 = 0;
        var i = totalDigits - 1;

        // We have to shuffle the values around by 48 as this is ASCII for 0.
        while (i >= 0) {
            std.log.info("attempting to index {d} + {d}", .{ available, i });
            const x = self.source[available + i] + other.source[otherAvailable + i] + carry - 48 * 2;

            if (x >= 10) {
                carry = 1;
                self.source[available + i] = x - 10 + 48;
            } else {
                carry = 0;
                self.source[available + i] = x + 48;
            }

            if (i == 0) break;
            i -= 1;
        }
    } else {
        var lhs = self.source[available..];
        var rhs = other.source[otherAvailable..];
        std.debug.assert(std.mem.len(lhs) == std.mem.len(rhs));

        var borrow: u8 = 0;
        var i = totalDigits - 1;

        if (std.mem.lessThan(u8, lhs, rhs)) {
            lhs = other.source[otherAvailable..];
            rhs = self.source[available..];
            self.positive = !self.positive;
        }

        while (i >= 0) {
            // We have to cast here because the subtractions happen before the cast,
            // i.e. lhs[i] is a u8 which could overflow when subtracting rhs[i] (another u8).
            const x: i16 = @as(i16, lhs[i]) - @as(i16, rhs[i]) - borrow;
            if (x < 0) {
                self.source[i] = @intCast(u8, x + 48 + 10);
                borrow = 1;
            } else {
                self.source[i] = @intCast(u8, x + 48);
                borrow = 0;
            }

            if (i == 0) break;
            i -= 1;
        }
    }
}

test "init and format works" {
    var s = "03,141,592.65".*; // dereference the pointer to the array
    const d = try Self.initAndFormat(std.testing.allocator, &s, null); // pass by reference to get a slice
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 9), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "0000314159265", &s);
}

test "init allocates for source" {
    const d = try Self.init(std.testing.allocator, "3.14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses integers" {
    const d = try Self.init(std.testing.allocator, "314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
}

test "parses positive integers" {
    const d = try Self.init(std.testing.allocator, "+314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
    try std.testing.expect(d.positive);
}

test "parses negative integers" {
    const d = try Self.init(std.testing.allocator, "-314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
    try std.testing.expect(!d.positive);
}

test "error on unexpected character" {
    const d = Self.init(std.testing.allocator, "314159a", null);
    try std.testing.expectError(Error.UnexpectedCharacter, d);
}

test "parses decimals with period as decimal separator" {
    const d = try Self.init(std.testing.allocator, "3.14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with comma as decimal separator" {
    const d = try Self.init(std.testing.allocator, "3,14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with thousand separators" {
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
    var s = "003,141.59".*;
    const a = try Self.initAndFormat(std.testing.allocator, &s, null);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), a.digits);
    try std.testing.expectEqual(@as(u32, 2), a.fractional);
    try std.testing.expectEqualSlices(u8, "0000314159", &s);

    const available = a.expand(std.testing.allocator, 7, 2);
    // should be no change to source during this expand
    try std.testing.expectEqualSlices(u8, "0000314159", &s);
    try std.testing.expectEqual(@as(u32, 3), available);
}

test "expand (local): additional integers" {
    var s = "0015.92".*;
    const a = try Self.initAndFormat(std.testing.allocator, &s, null);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4), a.digits);
    try std.testing.expectEqual(@as(u32, 2), a.fractional);
    try std.testing.expectEqualSlices(u8, "0001592", &s);

    const available = a.expand(std.testing.allocator, 6, 2);
    // should be no change to source during this expand
    try std.testing.expectEqualSlices(u8, "0001592", &s);
    try std.testing.expectEqual(@as(u32, 1), available);
}

test "expand (local): additional fractional" {
    var s = "001.92".*;
    const a = try Self.initAndFormat(std.testing.allocator, &s, null);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), a.digits);
    try std.testing.expectEqual(@as(u32, 2), a.fractional);
    try std.testing.expectEqualSlices(u8, "000192", a.source);

    const available = a.expand(std.testing.allocator, 5, 3);
    try std.testing.expectEqualSlices(u8, "001920", &s);
    try std.testing.expectEqual(@as(u32, 1), available);
}

test "expand (local): additional integers and additional fractional" {
    // We dereference the pointer to the array then pass by reference to get a slice
    var s = "001,215.92".*;

    const a = try Self.initAndFormat(std.testing.allocator, &s, null);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), a.digits);
    try std.testing.expectEqual(@as(u32, 2), a.fractional);
    try std.testing.expectEqualSlices(u8, "0000121592", &s);

    const available = a.expand(std.testing.allocator, 8, 3);
    try std.testing.expectEqualSlices(u8, "0001215920", &s);
    try std.testing.expectEqual(@as(u32, 2), available);
}

test "expand (local): multiple expands" {
    var a = try Self.init(std.testing.allocator, "003", null);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), a.digits);
    try std.testing.expectEqual(@as(u32, 0), a.fractional);

    var available = a.expand(std.testing.allocator, 3, 0);

    try std.testing.expectEqualSlices(u8, "003", a.source);
    try std.testing.expectEqual(@as(u32, 3), a.digits);
    try std.testing.expectEqual(@as(u32, 0), a.fractional);
    try std.testing.expectEqual(@as(u32, 0), available);

    available = a.expand(std.testing.allocator, 3, 0);

    try std.testing.expectEqualSlices(u8, "003", a.source);
    try std.testing.expectEqual(@as(u32, 3), a.digits);
    try std.testing.expectEqual(@as(u32, 0), a.fractional);
    try std.testing.expectEqual(@as(u32, 0), available);

    available = a.expand(std.testing.allocator, 3, 0);

    try std.testing.expectEqualSlices(u8, "003", a.source);
    try std.testing.expectEqual(@as(u32, 3), a.digits);
    try std.testing.expectEqual(@as(u32, 0), a.fractional);
    try std.testing.expectEqual(@as(u32, 0), available);
}

test "expand (alloc): no change" {
    const a = try Self.init(std.testing.allocator, "003,115.92", null);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), a.digits);
    try std.testing.expectEqual(@as(u32, 2), a.fractional);
    try std.testing.expectEqualSlices(u8, "0000311592", a.source);

    const available = a.expand(std.testing.allocator, 2, 1);
    // should be no change to source during this expand
    try std.testing.expectEqualSlices(u8, "0000311592", a.source);
    try std.testing.expectEqual(@as(u32, 4), available);
}

test "expand (alloc): additional integers" {
    const a = try Self.init(std.testing.allocator, "3", null);
    defer a.deinit(std.testing.allocator);

    const available = a.expand(std.testing.allocator, 3, 0);

    try std.testing.expectEqualSlices(u8, "003", a.source);
    try std.testing.expectEqual(@as(u32, 0), available);
}

test "expand (alloc): additional fractional" {
    const a = try Self.init(std.testing.allocator, "3.1", null);
    defer a.deinit(std.testing.allocator);

    const available = a.expand(std.testing.allocator, 4, 2);

    try std.testing.expectEqualSlices(u8, "0310", a.source);
    try std.testing.expectEqual(@as(u32, 0), available);
}

test "expand (alloc): additional integers and additional fractional" {
    const a = try Self.init(std.testing.allocator, "5.92", null);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), a.digits);
    try std.testing.expectEqual(@as(u32, 2), a.fractional);
    try std.testing.expectEqualSlices(u8, "0592", a.source);

    const available = a.expand(std.testing.allocator, 6, 3);

    try std.testing.expectEqualSlices(u8, "005920", a.source);
    try std.testing.expectEqual(@as(u32, 0), available);
}

test "expand (alloc): multiple expands" {
    var a = try Self.init(std.testing.allocator, "3", null);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), a.digits);
    try std.testing.expectEqual(@as(u32, 0), a.fractional);

    var available = a.expand(std.testing.allocator, 3, 0);

    try std.testing.expectEqualSlices(u8, "003", a.source);
    try std.testing.expectEqual(@as(u32, 3), a.digits);
    try std.testing.expectEqual(@as(u32, 0), a.fractional);
    try std.testing.expectEqual(@as(u32, 0), available);

    available = a.expand(std.testing.allocator, 3, 0);

    try std.testing.expectEqualSlices(u8, "003", a.source);
    try std.testing.expectEqual(@as(u32, 3), a.digits);
    try std.testing.expectEqual(@as(u32, 0), a.fractional);
    try std.testing.expectEqual(@as(u32, 0), available);

    available = a.expand(std.testing.allocator, 3, 0);

    try std.testing.expectEqualSlices(u8, "003", a.source);
    try std.testing.expectEqual(@as(u32, 3), a.digits);
    try std.testing.expectEqual(@as(u32, 0), a.fractional);
    try std.testing.expectEqual(@as(u32, 0), available);
}

// test "adds two positive integers" {
//     const a = try Self.init(std.testing.allocator, "4", null);
//     const b = try Self.init(std.testing.allocator, "6", null);
//     defer a.deinit(std.testing.allocator);
//     defer b.deinit(std.testing.allocator);

//     a.add(std.testing.allocator, b);

//     try std.testing.expectEqualSlices(u8, "10", a.source);
// }

// test "adds two positive decimals" {
//     const a = try Self.init(std.testing.allocator, "4.2", null);
//     const b = try Self.init(std.testing.allocator, "6.9", null);
//     defer a.deinit(std.testing.allocator);
//     defer b.deinit(std.testing.allocator);

//     a.add(std.testing.allocator, b);

//     try std.testing.expectEqualSlices(u8, "111", a.source);
// }

// test "adds two negative integers" {
//     const a = try Self.init(std.testing.allocator, "-8", null);
//     const b = try Self.init(std.testing.allocator, "-3", null);
//     defer a.deinit(std.testing.allocator);
//     defer b.deinit(std.testing.allocator);

//     a.add(std.testing.allocator, b);

//     try std.testing.expectEqualSlices(u8, "11", a.source);
//     try std.testing.expect(!a.positive);
// }

// test "adds two negative decimals" {
//     const a = try Self.init(std.testing.allocator, "-8.7", null);
//     const b = try Self.init(std.testing.allocator, "-3.2", null);
//     defer a.deinit(std.testing.allocator);
//     defer b.deinit(std.testing.allocator);

//     try std.testing.expectEqual(@as(u32, 2), a.digits);
//     try std.testing.expectEqual(@as(u32, 1), a.fractional);

//     a.add(std.testing.allocator, b);

//     try std.testing.expectEqual(@as(u32, 3), a.digits);
//     try std.testing.expectEqual(@as(u32, 1), a.fractional);
//     try std.testing.expect(!a.positive);
//     try std.testing.expectEqualSlices(u8, "0119", a.source);
// }

// test "adds integers of opposite signs" {
//     const a = try Self.init(std.testing.allocator, "4", null);
//     const b = try Self.init(std.testing.allocator, "-6", null);
//     defer a.deinit(std.testing.allocator);
//     defer b.deinit(std.testing.allocator);

//     a.add(std.testing.allocator, b);

//     try std.testing.expectEqualSlices(u8, "02", a.source);
//     try std.testing.expect(!a.positive);
// }

// test "adds decimals of opposite signs" {
//     const a = try Self.init(std.testing.allocator, "18.2", null);
//     defer a.deinit(std.testing.allocator);
//     try std.testing.expectEqualSlices(u8, "0182", a.source);

//     const b = try Self.init(std.testing.allocator, "-6.38", null);
//     defer b.deinit(std.testing.allocator);
//     try std.testing.expectEqualSlices(u8, "00638", b.source);

//     a.add(std.testing.allocator, b);

//     try std.testing.expectEqualSlices(u8, "01182", a.source);
//     try std.testing.expect(a.positive);
// }

// test "adding multiple times" {
//     std.testing.log_level = .debug;
//     std.log.info("", .{});

//     var sum = try Self.init(std.testing.allocator, "0", null);
//     defer sum.deinit(std.testing.allocator);
//     const a = try Self.init(std.testing.allocator, "1", null);
//     defer a.deinit(std.testing.allocator);

//     sum.add(std.testing.allocator, a);
//     try std.testing.expect(sum.digits == 2);

//     sum.add(std.testing.allocator, a);
//     try std.testing.expect(sum.digits == 2);

//     sum.add(std.testing.allocator, a);
//     try std.testing.expect(sum.digits == 2);

//     std.log.info("source = {d}", .{sum.source});
//     try std.testing.expectEqualSlices(u8, "03", sum.source);
// }

