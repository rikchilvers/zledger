const std = @import("std");

const Error = error{UnexpectedCharacter};
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
    groupSeparator: u8 = 0, // e.g. 24,000
    decimalSeparator: u8 = 0, // e.g. 3.141
    indianNumbering: bool = false, // e.g. 10,00,000
};

// This function does 3 different jobs.
//     1. Parse whether the sign of the decimal and how many total digits and fractional digits it has.
//     2. Identify how to render back if printed.
//     3. Remove all non-digit characters from the source.
pub fn initAndFormat(allocator: std.mem.Allocator, source: []u8, renderingInformation: ?*RenderingInformation) !*Self {
    var decimal = allocator.create(Self) catch unreachable;
    errdefer allocator.destroy(decimal);

    // Initialize the decimal to some sensible defaults.
    decimal.positive = true;
    decimal.fractional = 0;
    decimal.digits = 0;
    decimal.source = source;
    decimal.ownedSource = false;

    // Temporary storage of rendering information.
    var groupSeparator: u8 = 0;
    var decimalSeparator: u8 = 0;
    var indianNumbering = false;

    // Index into the source
    var i: usize = 0;
    // Position of last comma (used to guess if the source is formatted using Indian notation)
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

                // If we've detected the number might be formated to match indian numbering,
                // the previous , should be 3 digits prior to the decimal point
                if (indianNumbering) {
                    indianNumbering = i - j == 4;
                }
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
        ri.*.groupSeparator = groupSeparator;
        ri.*.decimalSeparator = decimalSeparator;
        ri.*.indianNumbering = indianNumbering;
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

pub fn initWithSource(allocator: std.mem.Allocator, source: []u8, renderingInformation: ?*RenderingInformation) !*Self {
    var decimal = allocator.create(Self) catch unreachable;
    errdefer allocator.destroy(decimal);

    decimal.positive = true;
    decimal.fractional = 0;
    decimal.digits = 0;
    decimal.source = source;
    decimal.ownedSource = false;

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
pub fn init(allocator: std.mem.Allocator, number: []const u8, separator: ?*RenderingInformation) !*Self {
    var source = allocator.allocSentinel(u8, std.mem.len(number), 0) catch unreachable;
    std.mem.copy(u8, source, number);
    errdefer allocator.free(source);
    var result = try initWithSource(allocator, source, separator);
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

    std.log.info("expanding {d}:{d} to {d}:{d}", .{
        self.digits - self.fractional,
        self.fractional,
        nDigit - nFractional,
        nFractional,
    });
    std.log.info("addInt = {d} | addFrac = {d}", .{ additionalInteger, additionalFractional });
    std.log.info("\n\t source = {s}", .{self.source});

    // NOTE: During reallocation, sqlite3 adds 1 to how many chars are required in source. Why?
    //       See sqlite/ext/misc/decimal.c:381
    if (available >= additionalDigits) {
        std.log.info("have enough in available ({d})", .{available});

        // If we have space and there are no additional fractional digits, we can return now
        if (additionalFractional == 0) {
            return @intCast(u32, available - additionalDigits);
        }

        var scratch = [_]u8{'0'} ** 15;

        if (additionalInteger > 0) {
            std.log.info("{d} additional integers", .{additionalInteger});
            // Copy source digits to scratch, leaving space for additional integers
            // [---314159]
            //     ^^^^^
            std.mem.copy(u8, scratch[additionalInteger - 1 ..], self.source[available..]);
            std.log.info("copied source digits to scratch\n\tscratch =  {d}", .{scratch[0 .. nDigit + 1]});

            // Fill in additional integer space with zeroes
            // [00031459]
            //  ^^^
            // std.mem.set(u8, scratch[0..additionalInteger], '0');
            // std.log.info("addInt done\n\tscratch =  {d}", .{scratch[0 .. nDigit + 1]});

            self.digits += additionalInteger;
        } else {
            std.log.info("no additional integers", .{});
            // Copy source digits to scratch
            // [314159--]
            //  ^^^^^
            std.mem.copy(u8, scratch[available - additionalDigits ..], self.source[available..]);
            std.log.info("copied source digits to scratch\n\tscratch = {s}", .{scratch});
        }

        // Handle fractional part
        // We know there must be one because we've checked above

        // Set fractional part to zeroes
        // [314159000]
        //       ^^^
        // std.mem.set(u8, scratch[available - additionalInteger ..], '0');
        // std.log.info("addFrac\n\tscratch = {s}", .{scratch});

        self.digits += additionalInteger;
        self.fractional += additionalFractional;

        // Update self.source
        // TODO: this should probably start at available
        std.mem.copy(u8, self.source[0..], scratch[0..std.mem.len(self.source)]);
        std.log.info("copied scratch to scratch\n\t source = {s}", .{self.source});

        return @intCast(u32, available - 1);
    } else {
        var scratch = allocator.alloc(u8, nDigit + 1) catch unreachable;

        if (additionalInteger > 0) {
            // [---314159]
            std.mem.copy(u8, scratch[additionalInteger .. additionalInteger + nDigit], self.source);
            // [00031459]
            std.mem.set(u8, scratch[0..additionalInteger], 0);

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
        self.source = scratch[0..nDigit];
        self.ownedSource = true;

        return 0;
    }
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

test "ignores space at the start" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "   314159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 0), d.fractional);
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

test "parsing returns error on unexpected character" {
    // std.testing.log_level = .debug;

    const d = Self.init(std.testing.allocator, "314159a", null);

    try std.testing.expectError(Error.UnexpectedCharacter, d);
}

test "parses decimals with . as decimal separator" {
    // std.testing.log_level = .debug;

    const d = try Self.init(std.testing.allocator, "3.14159", null);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 6), d.digits);
    try std.testing.expectEqual(@as(u32, 5), d.fractional);
}

test "parses decimals with , as decimal separator" {
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

    try std.testing.expectEqual(@as(u8, ','), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(false, ri.indianNumbering);
}

test "parses decimals with thousand separators after decimal point" {
    // std.testing.log_level = .debug;

    var ri = RenderingInformation{};
    const d = try Self.init(std.testing.allocator, "3_141_592.650_123_430", &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 16), d.digits);
    try std.testing.expectEqual(@as(u32, 9), d.fractional);

    try std.testing.expectEqual(@as(u8, '_'), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(false, ri.indianNumbering);
}

test "parses indian notation" {
    // std.testing.log_level = .debug;

    var ri = RenderingInformation{};
    const d = try Self.init(std.testing.allocator, "3,14,15,926.501123", &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 14), d.digits);
    try std.testing.expectEqual(@as(u32, 6), d.fractional);

    try std.testing.expectEqual(@as(u8, ','), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(true, ri.indianNumbering);
}

test "parses random notation" {
    // std.testing.log_level = .debug;

    var ri = RenderingInformation{};
    const d = try Self.init(std.testing.allocator, "3,14,15,92,6.501", &ri);
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 11), d.digits);
    try std.testing.expectEqual(@as(u32, 3), d.fractional);

    try std.testing.expectEqual(@as(u8, ','), ri.groupSeparator);
    try std.testing.expectEqual(@as(u8, '.'), ri.decimalSeparator);
    try std.testing.expectEqual(false, ri.indianNumbering);
}

test "expand returns early if no new digits required" {
    // std.testing.log_level = .debug;
    // std.log.info("", .{});

    var s = "03,141,5.92".*; // dereference the pointer to the array
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

test "expand returns early if no additional fractional and enough available space" {
    // std.testing.log_level = .debug;
    // std.log.info("", .{});

    var s = "03,141,5.92".*; // dereference the pointer to the array
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

test "expands fractional" {
    std.testing.log_level = .debug;
    std.log.info("", .{});

    var s = "03,141,5.92".*; // dereference the pointer to the array
    //       00003141592
    // 11 digits
    const d = try Self.initAndFormat(std.testing.allocator, &s, null); // pass by reference to get a slice
    defer d.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), d.digits);
    try std.testing.expectEqual(@as(u32, 2), d.fractional);
    try std.testing.expectEqualSlices(u8, "00003141592", &s);

    const spare = d.expand(std.testing.allocator, 8, 3);
    try std.testing.expectEqualSlices(u8, "00031415920", &s);
    try std.testing.expectEqual(@as(u32, 3), spare);
}

// test "adds integers" {
//     const a: []u8 = "4";
//     const b: []u8 = "6";
//     const aD = try Self.initWithSource(std.testing.allocator, a, null);
//     const bD = try Self.initWithSource(std.testing.allocator, b, null);
//     defer aD.deinit(std.testing.allocator);
//     defer bD.deinit(std.testing.allocator);

//     a.add(b);

//     try std.testing.expectEqualSentinel(u8, 0, "10", a.source);
// }
