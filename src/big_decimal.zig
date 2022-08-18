const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("gmp.h");
    @cInclude("mpfr.h");
});

const Error = error{mpfr};
const Precision: c_int = 150;

const Self = @This();

// The MPFR value that backs BigDecimal
internal: c.mpfr_t,

pub fn setAllocator(allocator: std.mem.Allocator) void {
    _ = allocator;
    // TODO: implement this
}

pub fn cleanUpMemory() !void {
    if (c.mpfr_mp_memory_cleanup() != 0) return Error.mpfr;
}

pub fn initAlloc(allocator: std.mem.Allocator) *Self {
    var self = allocator.create(Self) catch unreachable;
    errdefer allocator.destroy(self);

    self.internal = undefined;

    c.mpfr_init2(&self.internal, Precision);
    _ = c.mpfr_strtofr(&self.internal, "0.0", null, 10, c.MPFR_RNDN);

    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    c.mpfr_clear(&self.internal);
    allocator.destroy(self);
}

// If self is 0, returns true.
pub fn sign(self: Self) i1 {
    if (c.mpfr_sgn(&self.internal) >= 0) return 1;
    return -1;
}

pub fn setNegative(self: *Self) void {
    _ = c.mpfr_neg(&self.internal, &self.internal, c.MPFR_RNDN);
}

pub fn setPositive(self: *Self) void {
    _ = c.mpfr_abs(&self.internal, &self.internal, c.MPFR_RNDN);
}

pub fn set(self: *Self, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .Pointer => {
            // NOTE: We're ignoring the error reporting mpfr offers us here
            // by passing null as the third parameter.
            _ = c.mpfr_strtofr(&self.internal, value.ptr, null, 10, c.MPFR_RNDN);
        },
        .Int => _ = c.mpfr_set_ui(&self.internal, value, c.MPFR_RNDN),
        .Float => _ = c.mpfr_set_flt(&self.internal, value, c.MPFR_RNDN),
        else => @compileError("unknown type for setting BigDecimal"),
    }
}

pub fn add(self: *Self, addend: *Self) void {
    _ = c.mpfr_add(&self.internal, &self.internal, &addend.internal, c.MPFR_RNDN);
}

pub fn print(self: *Self) void {
    _ = c.mpfr_printf("%.2Rf", &self.internal);
}

pub fn write(self: *Self, buffer: []u8) []u8 {
    // TODO: this needs to construct the format string in line with the precision of the parsed value
    const written_chars = c.mpfr_sprintf(buffer.ptr, "%.2Rf", &self.internal);
    return buffer[0..@intCast(usize, written_chars)];
}
