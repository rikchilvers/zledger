const std = @import("std");

const Error = error{UnexpectedCharacter};

const Self = @This();

positive: bool,
/// Number of digits to the right of the decimal point
fractional: u32,
/// Total number of digits
digits: u32,
/// Array of digits. Most significant first.
source: u128,

pub const RenderingInformation = struct {
    groupSeparator: u8 = 0, // e.g. 24,000
    decimalSeparator: u8 = 0, // e.g. 3.141
    indianNumbering: bool = false, // e.g. 10,00,000
};

pub fn init(source: []const u8, renderingInformation: ?*RenderingInformation) !*Self {
    var decimal = .{
        .positive = true,
        .fractional = 0,
        .digits = 0,
        .source = 0,
    };

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
