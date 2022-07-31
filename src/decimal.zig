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

const SliceIterator = struct {
    a: []u8,
    b: []u8,
    i: usize,
    j: usize,
    iComplete: bool,
    jComplete: bool,
    fractionalDifference: i8,

    // The fractionalDifference is a.fractional - b.fractional
    pub fn init(a: []u8, b: []u8, fractionalDifference: i8) SliceIterator {
        return .{
            .a = a,
            .b = b,
            .i = std.mem.len(a) - 1,
            .j = std.mem.len(b) - 1,
            .iComplete = false,
            .jComplete = false,
            .fractionalDifference = fractionalDifference,
        };
    }

    // Given that the slices provided might be of different lengths, this iterator
    // works from back-to-front, setting the passed pointers to the current value
    // of the indices or null if there is no digit in that place value.
    pub fn next(self: *SliceIterator, lhsIndex: *?usize, rhsIndex: *?usize) bool {
        // First, we handle a and b having different numbers of fractional digits.
        // If they are unequal, we only take a digit from the slice that has more.
        if (self.fractionalDifference > 0) {
            // self.a has more fractional digits than self.b
            lhsIndex.* = self.i;
            rhsIndex.* = null;
            self.fractionalDifference -= 1;
        } else if (self.fractionalDifference < 0) {
            // self.b has more fractional digits than self.a
            lhsIndex.* = null;
            rhsIndex.* = self.j;
            self.fractionalDifference += 1;
        } else {
            lhsIndex.* = self.i;
            rhsIndex.* = self.j;
        }

        // If the fractionalDifference is > 0, a has more fractional digits than b.
        // That means we can only advance a.
        if (self.fractionalDifference >= 0) {
            if (self.i > 0) {
                self.i -= 1;
                if (self.a[self.i] < '0' or self.a[self.i] > '9') {
                    self.i -= 1;
                }
            } else {
                if (self.iComplete) {
                    lhsIndex.* = null;
                } else {
                    self.iComplete = true;
                }
            }
        }

        // If the fractionDifference is < 0, b has more fractional digits than a.
        // That means we can only advance b.
        if (self.fractionalDifference <= 0) {
            if (self.j > 0) {
                self.j -= 1;

                // The decimal slices that we are given have been parsed before being seen
                // by this function. That means we can safely assume the final character is not
                // going to be a non-digit character and therefore we can -1 from the index without
                // setting ourselves up for an out of bounds error.
                if (self.b[self.j] < '0' or self.b[self.j] > '9') {
                    self.j -= 1;
                }
            } else {
                if (self.jComplete) {
                    rhsIndex.* = null;
                } else {
                    self.jComplete = true;
                }
            }
        }

        return if (self.iComplete and self.jComplete) false else true;
    }
};

// Adds the value of other into self.
// Both self and other might be reallocated to new memory by this function.
pub fn add(self: *Self, allocator: std.mem.Allocator, other: *Self) void {
    std.log.info("\n>> add {s} to {s}", .{ other.source, self.source });

    var integerDigits = self.digits - self.fractional;
    var otherIntegers = other.digits - other.fractional;
    if (integerDigits < otherIntegers) integerDigits = otherIntegers;

    var fractionalDigits = self.fractional;
    if (fractionalDigits < other.fractional) fractionalDigits = other.fractional;

    const totalDigits = integerDigits + fractionalDigits + 1;

    std.log.info(">> expand self", .{});
    // We +1 here because we might need an additional place value column to overflow into.
    const available = self.expand(allocator, totalDigits, fractionalDigits);
    var otherAvailable = 0;

    // We only expand other if fractional digits are not the same
    if (fractionalDigits > other.fractional) {
        otherAvailable = other.expand(allocator, totalDigits, fractionalDigits);
    }

    if (self.positive == other.positive) {
        var carry: u8 = 0;
        var i = totalDigits - 1;

        var a: ?u8 = null;
        var b: ?u8 = null;
        var iter = SliceIterator.init(self.source[available..], other.source[otherAvailable..]);
        while (iter.next(&a, &b)) {
            std.log.info("Do a thing with {d} and {d}", .{ a, b });
        }

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
    const d = try Self.init(std.testing.allocator, "3,141,592.650", &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 10), d.digits);
    try std.testing.expectEqual(@as(u32, 3), d.fractional);

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

fn do(lhs: u8, rhs: u8) void {
    std.log.info("Do a thing with {d} and {d}", .{ lhs - 48, rhs - 48 });
}

test "loop test" {
    std.testing.log_level = .debug;
    std.log.info("", .{});

    const a = try Self.init(std.testing.allocator, "003,115.9", null);
    defer a.deinit(std.testing.allocator);

    // const b = try Self.init(std.testing.allocator, "115.9", null);
    // defer b.deinit(std.testing.allocator);

    const aAvailable = a.expand(std.testing.allocator, 6 + 1, 2);
    const bAvailable = 0; //b.expand(std.testing.allocator, 6 + 1, 2);

    // loopTest(a.source[aAvailable..], b.source[bAvailable..], do);
    var c = "115.92".*;
    var iter = SliceIterator.init(a.source[aAvailable..], &c, 1 - 2);
    var x: ?usize = null;
    var y: ?usize = null;
    while (iter.next(&x, &y)) {
        const i = if (x) |xP| a.source[xP + aAvailable] else '0';
        const j = if (y) |yP| c[yP + bAvailable] else '0';
        std.log.info("Do a thing with {c} and {c}", .{ i, j });
    }
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

