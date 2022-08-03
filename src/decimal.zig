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

pub const Style = struct {
    thousandMark: u8 = 0, // e.g. 24,000
    decimalSeparator: u8 = 0, // e.g. 3.141
};

/// Initialises the Decimal along with space for its source
pub fn initAlloc(allocator: std.mem.Allocator, number: []const u8, style: ?*Style) !*Self {
    var self = allocator.create(Self) catch unreachable;
    errdefer allocator.destroy(self);

    var source = allocator.alloc(u8, std.mem.len(number)) catch unreachable;
    std.mem.copy(u8, source, number);
    errdefer allocator.free(source);

    self.positive = true;
    self.fractional = 0;
    self.digits = 0;
    self.source = source;
    self.ownedSource = true;

    const renderingStyle = try self.parse(true);
    if (style) |s| s.* = renderingStyle;

    return self;
}

pub fn init(source: []u8, style: ?*Style) !Self {
    var self: Self = .{
        .positive = true,
        .fractional = 0,
        .digits = 0,
        .source = source,
        .ownedSource = false,
    };

    const renderingStyle = try self.parse(false);
    if (style) |s| s.* = renderingStyle;

    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    if (self.ownedSource) allocator.free(self.source);
    allocator.destroy(self);
}

// This function does 3 things:
//     1. Parse the sign of the decimal and how many total and fractional digits it has.
//     2. Identify how to render back if printed.
//     3. Remove all non-digit characters from the source.
fn parse(self: *Self, format: bool) !Style {
    // Rendering style
    var style: Style = .{
        .thousandMark = 0,
        .decimalSeparator = 0,
    };

    // Index into the source
    var i: usize = 0;
    // Position of last thousand-mark
    var j: usize = 0;
    // Whether we've seen a significant figure
    var seenSignificant = false;

    // We use two 32 byte arrays to temporarily hold digits either side of the decimal separator.
    // These will be later copied back into the source to remove grouping characters.
    std.debug.assert(std.mem.len(self.source) <= MaxCharacters);
    var tempInteger = [_]u8{0} ** (MaxCharacters / 2);
    var tempFractional = [_]u8{0} ** (MaxCharacters / 2);
    var tempIntegerIndex: usize = 0;
    var tempFractionalIndex: usize = 0;

    // Find the sign
    if (self.source[i] == '-') {
        self.positive = false;
        i += 1;
    } else if (self.source[i] == '+') {
        i += 1;
    }

    var precedingZeroes: u8 = 0;
    while (i < std.mem.len(self.source)) : (i += 1) {
        const c = self.source[i];
        switch (c) {
            '0'...'9' => {
                // Skip over leading zeroes
                if (c > '0') seenSignificant = true;
                if (!seenSignificant) {
                    precedingZeroes += 1;
                    continue;
                }

                self.digits += 1;

                if (style.decimalSeparator == 0) {
                    if (format) tempInteger[tempIntegerIndex] = self.source[i];
                    tempIntegerIndex += 1;
                } else {
                    if (format) tempFractional[tempFractionalIndex] = self.source[i];
                    tempFractionalIndex += 1;
                }
            },
            ',' => {
                if (!seenSignificant) return Error.IncorrectThousandMark;

                switch (style.decimalSeparator) {
                    0 => {
                        // treat the first comma as a decimal separator
                        style.decimalSeparator = c;
                        self.fractional = self.digits + 1;
                    },
                    '.' => {
                        // if we've seen a period, we shouldn't be seeing commas
                        return Error.UnexpectedCharacter;
                    },
                    else => {},
                }

                if (style.thousandMark == '_') return Error.UnexpectedCharacter;

                if (j > 0 and i - j != 4) return Error.IncorrectThousandMark;

                j = i;
            },
            '_' => {
                if (!seenSignificant) return Error.IncorrectThousandMark;
                if (style.thousandMark == ',') return Error.UnexpectedCharacter;
                if (j > 0 and i - j != 4) return Error.IncorrectThousandMark;

                style.thousandMark = '_';
                j = i;
            },
            '.' => {
                if (!seenSignificant) return Error.UnexpectedCharacter;

                if (j > 0 and i - j != 4) return Error.IncorrectThousandMark;

                if (style.decimalSeparator == ',') {
                    style.thousandMark = ',';
                    // Because we previously treated a comma as the decimal separator,
                    // all the fraction digits should now be moved to the integer digits
                    if (tempFractionalIndex > 0 and format) {
                        std.mem.copy(
                            u8,
                            tempInteger[tempIntegerIndex .. tempIntegerIndex + tempFractionalIndex],
                            tempFractional[0..tempFractionalIndex],
                        );
                        std.mem.set(u8, tempFractional[0..tempFractionalIndex], 0);
                    }
                    tempIntegerIndex += tempFractionalIndex;
                    tempFractionalIndex = 0;
                }
                style.decimalSeparator = '.';

                self.fractional = self.digits + 1;
            },
            else => {
                return Error.UnexpectedCharacter;
            },
        }
    }

    // Until now, decimal.fractional has been storing the index of the first digit after the decimalSeparator.
    // We need to change this now to reflect the actual number of fractional digits.
    if (self.fractional > 0) {
        self.fractional = self.digits - (self.fractional - 1);
    }

    // Replace the source with the formatted version.
    if (format) {
        // Pad with preceding zeroes.
        const padding = std.mem.len(self.source) - tempIntegerIndex - tempFractionalIndex;
        std.mem.set(u8, self.source[0..padding], '0');

        // Copy the integer part
        std.mem.copy(u8, self.source[padding .. tempIntegerIndex + padding], tempInteger[0..tempIntegerIndex]);

        // Copy the fractional part
        // We don't need a decimal separator because we know how many fractional digits are in the number.
        std.mem.copy(
            u8,
            self.source[padding + tempIntegerIndex .. padding + tempIntegerIndex + tempFractionalIndex],
            tempFractional[0..tempFractionalIndex],
        );
    }

    // If we don't own the source (i.e. it's from a text file), we want to trim out any preceding zeroes
    if (!self.ownedSource) self.source = self.source[precedingZeroes..];

    return style;
}

// Expand the Decimal so that it has at least nDigit digits and nFractional digits.
// This function expects that the decimal has been formatted to remove all non-digit characters.
// Returns the number of unused characters at the start of the source.
pub fn expand(self: *Self, allocator: std.mem.Allocator, nDigits: u32, nFractional: u32) u32 {
    std.log.info("expand to {d}.{d}", .{ nDigits, nFractional });

    const available = @intCast(u32, std.mem.len(self.source) - self.digits);

    if (self.digits >= nDigits and self.fractional >= nFractional) return available;

    const addDigits = nDigits - self.digits;
    const addFrac = if (self.fractional >= nFractional) 0 else nFractional - self.fractional;
    const addInt = addDigits - addFrac;

    if (available >= addDigits) {
        if (addFrac == 0) {
            // If there are no additional decimal digits, we don't need to move anything around:
            // we can just tell self that some of the available space is now used.
            self.digits += addInt;
            return available - addInt;
        }

        // TODO: check we won't overflow this
        var scratch = [_]u8{'0'} ** MaxCharacters;

        // Copy all significant digits (i.e. not any preceding unused characters) from source into scratch,
        // making space for additional fractional.
        std.mem.copy(u8, scratch[available - addFrac ..], self.source[available..]);

        // Update self.source
        std.mem.copy(u8, self.source[0..], scratch[0..std.mem.len(self.source)]);
        self.digits += addInt + addFrac;
        self.fractional += addFrac;

        return available - addDigits;
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
    fractionalDifference: i64,

    // The fractionalDifference is a.fractional - b.fractional
    pub fn init(a: []u8, b: []u8, fractionalDifference: i64) SliceIterator {
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
pub fn add(self: *Self, allocator: std.mem.Allocator, other: *const Self) void {
    std.log.info("\n>> add {s} to {s}", .{ other.source, self.source });

    defer {
        // Skip over zeroes
        var available: u32 = 0;
        while (available < std.mem.len(self.source)) : (available += 1) {
            if (self.source[available] != '0') break;
        }

        // We do this calculation because the number of digits might have drifted out
        self.digits = @intCast(u32, std.mem.len(self.source)) - available;
    }

    var integerDigits = self.digits - self.fractional;
    var otherIntegers = other.digits - other.fractional;
    if (integerDigits < otherIntegers) integerDigits = otherIntegers;

    var fractionalDigits = self.fractional;
    if (fractionalDigits < other.fractional) fractionalDigits = other.fractional;

    // We +1 here because we might need an additional place value column to overflow into.
    const totalDigits = integerDigits + fractionalDigits + 1;

    const available = self.expand(allocator, totalDigits, fractionalDigits);

    if (self.positive == other.positive) {
        var carry: u8 = 0;
        // var i = totalDigits - 1;

        var a: ?usize = null;
        var b: ?usize = null;
        const fractionalDifference: i64 = @as(i64, self.fractional) - @as(i64, other.fractional);
        var iter = SliceIterator.init(self.source[available..], other.source, fractionalDifference);
        while (iter.next(&a, &b)) {
            _ = carry;
            const i = if (a) |x| self.source[x + available] else '0';
            const j = if (b) |y| other.source[y] else '0';

            std.log.info("Do a thing with {c} and {c}", .{ i, j });

            const sum = i + j + carry - 48 * 2;
            if (sum >= 10) {
                carry = 1;
                std.log.info("index = {d}", .{a.?});
                std.log.info("setting {d} of {c} to {d}", .{ a.?, self.source, sum - 10 + 48 });
                self.source[a.?] = sum - 10 + 48;
            } else {
                carry = 0;
                self.source[a.?] = sum + 48;
            }
        }

        // Handle left over carry
        std.log.info("setting {d} of {c} to {d}", .{ a.?, self.source, carry + 48 });
        self.source[a.?] = carry + 48;

        // We have to shuffle the values around by 48 as this is ASCII for 0.
        // while (i >= 0) {
        //     std.log.info("attempting to index {d} + {d}", .{ available, i });
        //     const x = self.source[available + i] + other.source[i] + carry - 48 * 2;

        //     if (x >= 10) {
        //         carry = 1;
        //         self.source[available + i] = x - 10 + 48;
        //     } else {
        //         carry = 0;
        //         self.source[available + i] = x + 48;
        //     }

        //     if (i == 0) break;
        //     i -= 1;
        // }
    } else {
        var lhs = self.source[available..];
        var rhs = other.source;
        std.debug.assert(std.mem.len(lhs) == std.mem.len(rhs));

        var borrow: u8 = 0;
        var i = totalDigits - 1;

        if (std.mem.lessThan(u8, lhs, rhs)) {
            lhs = other.source;
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

test "init works" {
    std.testing.log_level = .debug;
    var s = "003,141,592.65".*; // dereference the pointer to the array
    const d = try Self.init(&s, null); // pass by reference to get a slice

    try std.testing.expectEqual(@as(u32, 9), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "3,141,592.65", d.source);
}

test "initAlloc works" {
    const d = try Self.initAlloc(std.testing.allocator, "3.14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses integers" {
    const d = try Self.initAlloc(std.testing.allocator, "314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
}

test "parses positive integers" {
    const d = try Self.initAlloc(std.testing.allocator, "+314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
    try std.testing.expect(d.positive);
}

test "parses negative integers" {
    const d = try Self.initAlloc(std.testing.allocator, "-314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
    try std.testing.expect(!d.positive);
}

test "error on unexpected character" {
    const d = Self.initAlloc(std.testing.allocator, "314159a", null);
    try std.testing.expectError(Error.UnexpectedCharacter, d);
}

test "parses decimals with period as decimal separator" {
    const d = try Self.initAlloc(std.testing.allocator, "3.14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with comma as decimal separator" {
    const d = try Self.initAlloc(std.testing.allocator, "3,14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with thousand separators" {
    var ri = Style{};
    const d = try Self.initAlloc(std.testing.allocator, "3,141,592.650", &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 10), d.digits);
    try std.testing.expectEqual(@as(u32, 3), d.fractional);

    try std.testing.expectEqual(@as(u8, ','), ri.thousandMark);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
}

test "errors on thousand-marks after decimal point" {
    const d = Self.initAlloc(std.testing.allocator, "3_141_592.650_123_430", null);
    try std.testing.expectError(Error.IncorrectThousandMark, d);
}

test "error on incorrect thousand-mark placement" {
    const a = Self.initAlloc(std.testing.allocator, "3,14,1592.501", null);
    try std.testing.expectError(Error.IncorrectThousandMark, a);

    const b = Self.initAlloc(std.testing.allocator, "31415,92.501", null);
    try std.testing.expectError(Error.IncorrectThousandMark, b);

    const c = Self.initAlloc(std.testing.allocator, "31415_92.501", null);
    try std.testing.expectError(Error.IncorrectThousandMark, c);
}

test "error on mixed thousand-marks" {
    const d = Self.initAlloc(std.testing.allocator, "3_141,592.01", null);
    try std.testing.expectError(Error.UnexpectedCharacter, d);
}

// Commenting these out because at the moment expand is not expected to be called on
// non-owned sources.
//
// test "expand (local): no change" {
//     var s = "003,141.59".*;
//     var a = try Self.init(&s, null);

//     try std.testing.expectEqual(@as(u32, 6), a.digits);
//     try std.testing.expectEqual(@as(u32, 2), a.fractional);
//     try std.testing.expectEqualSlices(u8, "003,141.59", &s);

//     const available = a.expand(std.testing.allocator, 7, 2);
//     // should be no change to source during this expand
//     try std.testing.expectEqualSlices(u8, "0000314159", &s);
//     try std.testing.expectEqual(@as(u32, 3), available);
// }

// test "expand (local): additional integers" {
//     var s = "0015.92".*;
//     var a = try Self.init(&s, null);

//     try std.testing.expectEqual(@as(u32, 4), a.digits);
//     try std.testing.expectEqual(@as(u32, 2), a.fractional);
//     try std.testing.expectEqualSlices(u8, "0001592", &s);

//     const available = a.expand(std.testing.allocator, 6, 2);
//     // should be no change to source during this expand
//     try std.testing.expectEqualSlices(u8, "0001592", &s);
//     try std.testing.expectEqual(@as(u32, 1), available);
// }

// test "expand (local): additional fractional" {
//     var s = "001.92".*;
//     var a = try Self.init(&s, null);

//     try std.testing.expectEqual(@as(u32, 3), a.digits);
//     try std.testing.expectEqual(@as(u32, 2), a.fractional);
//     try std.testing.expectEqualSlices(u8, "000192", a.source);

//     const available = a.expand(std.testing.allocator, 5, 3);
//     try std.testing.expectEqualSlices(u8, "001920", &s);
//     try std.testing.expectEqual(@as(u32, 1), available);
// }

// test "expand (local): additional integers and additional fractional" {
//     // We dereference the pointer to the array then pass by reference to get a slice
//     var s = "001,215.92".*;

//     var a = try Self.init(&s, null);

//     try std.testing.expectEqual(@as(u32, 6), a.digits);
//     try std.testing.expectEqual(@as(u32, 2), a.fractional);
//     try std.testing.expectEqualSlices(u8, "001,215,92", &s);

//     const available = a.expand(std.testing.allocator, 8, 3);
//     try std.testing.expectEqualSlices(u8, "0001215920", &s);
//     try std.testing.expectEqual(@as(u32, 2), available);
// }

// test "expand (local): multiple expands" {
//     var s = "003".*;
//     var a = try Self.init(&s, null);

//     try std.testing.expectEqual(@as(u32, 1), a.digits);
//     try std.testing.expectEqual(@as(u32, 0), a.fractional);

//     var available = a.expand(std.testing.allocator, 3, 0);

//     try std.testing.expectEqualSlices(u8, "003", a.source);
//     try std.testing.expectEqual(@as(u32, 3), a.digits);
//     try std.testing.expectEqual(@as(u32, 0), a.fractional);
//     try std.testing.expectEqual(@as(u32, 0), available);

//     available = a.expand(std.testing.allocator, 3, 0);

//     try std.testing.expectEqualSlices(u8, "003", a.source);
//     try std.testing.expectEqual(@as(u32, 3), a.digits);
//     try std.testing.expectEqual(@as(u32, 0), a.fractional);
//     try std.testing.expectEqual(@as(u32, 0), available);

//     available = a.expand(std.testing.allocator, 3, 0);

//     try std.testing.expectEqualSlices(u8, "003", a.source);
//     try std.testing.expectEqual(@as(u32, 3), a.digits);
//     try std.testing.expectEqual(@as(u32, 0), a.fractional);
//     try std.testing.expectEqual(@as(u32, 0), available);
// }

test "expand (alloc): no change" {
    const a = try Self.initAlloc(std.testing.allocator, "003,115.92", null);
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
    const a = try Self.initAlloc(std.testing.allocator, "3", null);
    defer a.deinit(std.testing.allocator);

    const available = a.expand(std.testing.allocator, 3, 0);

    try std.testing.expectEqualSlices(u8, "003", a.source);
    try std.testing.expectEqual(@as(u32, 0), available);
}

test "expand (alloc): additional fractional" {
    const a = try Self.initAlloc(std.testing.allocator, "3.1", null);
    defer a.deinit(std.testing.allocator);

    const available = a.expand(std.testing.allocator, 4, 2);

    try std.testing.expectEqualSlices(u8, "0310", a.source);
    try std.testing.expectEqual(@as(u32, 0), available);
}

test "expand (alloc): additional integers and additional fractional" {
    const a = try Self.initAlloc(std.testing.allocator, "5.92", null);
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), a.digits);
    try std.testing.expectEqual(@as(u32, 2), a.fractional);
    try std.testing.expectEqualSlices(u8, "0592", a.source);

    const available = a.expand(std.testing.allocator, 6, 3);

    try std.testing.expectEqualSlices(u8, "005920", a.source);
    try std.testing.expectEqual(@as(u32, 0), available);
}

test "expand (alloc): multiple expands" {
    var a = try Self.initAlloc(std.testing.allocator, "3", null);
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
    // std.testing.log_level = .debug;
    std.log.info("", .{});

    const a = try Self.initAlloc(std.testing.allocator, "003,115.9", null);
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

test "adds two positive integers" {
    const a = try Self.initAlloc(std.testing.allocator, "4", null);
    defer a.deinit(std.testing.allocator);

    var bSource = "6".*;
    const b = try Self.init(&bSource, null);

    a.add(std.testing.allocator, &b);

    try std.testing.expectEqualSlices(u8, "10", a.source);
}

test "adds two positive decimals" {
    const a = try Self.initAlloc(std.testing.allocator, "4.2", null);
    defer a.deinit(std.testing.allocator);

    var bSource = "6.9".*;
    const b = try Self.init(&bSource, null);

    a.add(std.testing.allocator, &b);

    try std.testing.expectEqualSlices(u8, "111", a.source);
}

// test "adds two negative integers" {
//     const a = try Self.initAlloc(std.testing.allocator, "-8", null);
//     defer a.deinit(std.testing.allocator);

//     var bSource = "-3".*;
//     const b = try Self.init(&bSource, null);

//     a.add(std.testing.allocator, &b);

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

test "adding multiple times" {
    std.testing.log_level = .debug;
    std.log.info("", .{});

    var sum = try Self.initAlloc(std.testing.allocator, "0", null);
    defer sum.deinit(std.testing.allocator);

    var aSource = "1".*;
    const a = try Self.init(&aSource, null);

    sum.add(std.testing.allocator, &a);
    try std.testing.expectEqual(@as(u32, 1), sum.digits);

    sum.add(std.testing.allocator, &a);
    try std.testing.expectEqual(@as(u32, 1), sum.digits);

    sum.add(std.testing.allocator, &a);
    try std.testing.expectEqual(@as(u32, 1), sum.digits);

    std.log.info("source = {d}", .{sum.source});
    try std.testing.expectEqualSlices(u8, "03", sum.source);
}
