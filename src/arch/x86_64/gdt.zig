const std = @import("std");
pub const GDTP = packed struct(u80) {
    limit: u16,
    base: u64,
};

pub const SegmentDescriptor = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    attributes: u16,
    base_high: u8,

    pub fn base(self: *const @This()) u64 {
        var res: u64 = @as(u32, self.base_low) | (@as(u32, self.base_mid) << 16) | (@as(u32, self.base_high) << 24);
        if (!self.isNull() and self.isSystem()) {
            // must be called on a descriptor that lives in the GDT (next 8 bytes = high base)
            const next_entry = @as([*]const @This(), @ptrCast(self))[1];
            const high: u32 = @truncate(@as(u64, @bitCast(next_entry)));
            res |= @as(u64, high) << 32;
        }
        return res;
    }

    pub fn limit(self: *const @This()) u20 {
        const limit_high: u4 = @truncate(self.attributes >> 8);
        return self.limit_low | (@as(u20, limit_high) << 16);
    }

    /// true when the descriptor is a system segment (TSS/LDT/gate), which is 16 bytes in long mode
    pub fn isSystem(self: *const @This()) bool {
        return self.attributes & 0x10 == 0;
    }

    pub inline fn isNull(self: *const @This()) bool {
        return self.* == @as(SegmentDescriptor, @bitCast(@as(u64, 0)));
    }
};

pub const gdt_offsets = struct {
    nulld: usize = 0,
    kernel_codeseg: usize = 1,
    kernel_dataseg: usize = 2,
    tss: usize = 3,
}{};

pub fn initTss() void {
    const entries: [*]SegmentDescriptor = @ptrFromInt(gdtInfo().base);
    const base = @intFromPtr(&tss_entry);
    const limit = @sizeOf(Tss) - 1;
    const task_state_access: Access = .{ .p = 1, .dpl = 0, .s = 0, .e = 1, .dc = 0, .rw = 0, .a = 1 };

    entries[gdt_offsets.tss] = SegmentDescriptor{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .attributes = @as(u16, @as(u8, @bitCast(task_state_access))) |
            (@as(u16, @as(u4, @truncate(limit >> 16))) << 8),
        .base_high = @truncate(base >> 24),
    };
    // top part of the entry
    entries[gdt_offsets.tss + 1] = @bitCast(@as(u64, @as(u32, @truncate(base >> 32))));

    asm volatile ("ltr %[selector]"
        :
        : [selector] "r" (@as(u16, @truncate(gdt_offsets.tss << 3))),
        : .{ .memory = true });
}

pub fn gdtInfo() *align(1) GDTP {
    const sym = @extern([*]align(1) const u8, .{ .name = "GDT.Pointer" });
    return @ptrFromInt(@intFromPtr(sym));
}

/// Returns a pointer into the live GDT so `base()` can read the high half of system descriptors.
pub fn getSegmentDescriptor(selector: u16, gdt_base: usize) *const SegmentDescriptor {
    // selector's index into the GDT
    const index = selector >> 3;
    const table: [*]const SegmentDescriptor = @ptrFromInt(gdt_base);
    return &table[index];
}

var tss_entry: Tss = .{};
pub const Tss = extern struct {
    rsvd: u32 align(16) = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    rsvd1: u64 = 0,
    ist: [7]u64 = .{0} ** 7,
    rsvd2: u64 = 0,
    rsvd3: u16 = 0,
    iomap_base: u16 = @sizeOf(Tss),
};

const Access = packed struct(u8) {
    a: u1 = 0,
    rw: u1 = 0,
    dc: u1 = 0,
    e: u1 = 0,
    s: u1 = 0,
    dpl: u2 = 0,
    p: u1 = 0,
};
