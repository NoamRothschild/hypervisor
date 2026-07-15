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

    pub fn base(self: *const @This()) u32 {
        return @as(u32, self.base_low) | (@as(u32, self.base_mid) << 16) | (@as(u32, self.base_high) << 24);
    }

    pub fn limit(self: *const @This()) u20 {
        const limit_high: u4 = @truncate(self.attributes >> 8);
        return self.limit_low | limit_high;
    }
};

pub fn gdtInfo() *align(1) GDTP {
    const sym = @extern([*]align(1) const u8, .{ .name = "GDT.Pointer" });
    return @ptrFromInt(@intFromPtr(sym));
}

pub fn getSegmentDescriptor(selector: u16, gdt_base: usize) SegmentDescriptor {
    // selector's index into the GDT
    const index = selector >> 3;
    const table: [*]const SegmentDescriptor = @ptrFromInt(gdt_base);
    // const table: [3]const SegmentDescriptor = @ptrFromInt(gdt_base);
    return table[index];
}
