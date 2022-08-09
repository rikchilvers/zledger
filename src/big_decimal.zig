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

pub fn set(self: *Self, value: []const u8) !void {
    const v = @ptrCast([*c]const u8, value);
    // std.log.info("setting to {s}", .{v});
    if (c.mpfr_set_str(&self.internal, v, 10, c.MPFR_RNDD) != 0) return Error.mpfr;
}

pub fn add(self: *Self, addend: *Self) void {
    _ = c.mpfr_add(&self.internal, &self.internal, &addend.internal, c.MPFR_RNDN);
}

pub fn print(self: *Self) void {
    _ = c.mpfr_printf("%.2Rf", &self.internal);
}
