const std = @import("std");
const hhdm = @import("../mem/hhdm.zig");
const mem_allocator = @import("../mem/allocator.zig");
const vmx = @import("vmx.zig");
// EPT tables map guest-physical addresses to host-physical addresses.

/// EPT pointer
pub const EPTP = packed struct(u64) {
    /// (0 = Uncacheable (UC) - 6 = Write - back(WB))
    memory_type: u3,
    /// This value is 1 less than the EPT page-walk length
    page_walk_length: u3,
    /// Setting this control to 1 enables accessed and dirty flags for EPT
    dirty_access_enabled: u1,
    rsvd1: u5 = 0,
    pml4_addr: u36,
    rsvd2: u16 = 0,
};

pub const EPT_PML4E = packed struct(u64) {
    read: u1,
    write: u1,
    execute: u1,
    rsvd1: u5 = 0,
    accessed: u1,
    rsvd2: u1 = 0,
    exec_for_usermode: u1,
    rsvd3: u1 = 0,
    /// this is phys addr truncated (physical >> 12)
    /// stores the addr of an EPT_PDPTE table
    phys_addr: u36,
    rsvd4: u16 = 0,

    pub fn makeEntry(phys_addr: u64) @This() {
        return .{
            .read = 1,
            .write = 1,
            .execute = 1,
            .accessed = 0,
            .exec_for_usermode = 0,
            .phys_addr = @truncate(phys_addr >> 12),
        };
    }

    pub inline fn initNotPresent() @This() {
        var entry: @This() = @bitCast(@as(u64, undefined));
        entry.setPresent(false);
        return entry;
    }

    pub inline fn present(self: *const @This()) bool {
        return self.read != 0 or self.write != 0 or self.execute != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) void {
        const bit: u1 = @intFromBool(is_present);
        self.read = bit;
        self.write = bit;
        self.execute = bit;
    }

    pub inline fn physAddr(self: *const @This()) u64 {
        return @as(u64, self.phys_addr) << 12;
    }
};

pub const EPT_PDPTE = packed union(u64) {
    PD: packed struct(u64) {
        read: u1,
        write: u1,
        execute: u1,
        rsvd1: u4 = 0,
        page_size: u1 = 0,
        accessed: u1,
        rsvd2: u1 = 0,
        exec_for_usermode: u1,
        rsvd3: u1 = 0,
        /// this is phys addr truncated (physical >> 12)
        /// stores the addr of an EPT_PDE table
        phys_addr: u36,
        rsvd4: u16 = 0,

        pub fn makeEntry(phys_addr: u36) @This() {
            return .{
                .read = 1,
                .write = 1,
                .execute = 1,
                .accessed = 0,
                .exec_for_usermode = 0,
                .phys_addr = phys_addr,
            };
        }

        pub inline fn physAddr(self: *const @This()) u64 {
            return @as(u64, self.phys_addr) << 12;
        }
    },
    @"1 GB": packed struct(u64) {
        read: u1,
        write: u1,
        execute: u1,
        ept_mem_type: u3,
        ignore_pat: u1,
        page_size: u1 = 1,
        accessed: u1,
        dirty: u1,
        exec_for_usermode: u1,
        rsvd1: u1 = 0,
        rsvd2: u18 = 0,
        /// this is phys addr truncated (physical >> 30)
        /// stores the physical addr in guest RAM
        phys_addr: u22,
        rsvd3: u11 = 0,
        supress_ve: u1,

        pub fn makeEntry(phys_addr: u22) @This() {
            return .{
                .read = 1,
                .write = 1,
                .execute = 1,
                .ept_mem_type = 6, // Write Back
                .ignore_pat = 0,
                .accessed = 0,
                .dirty = 0,
                .exec_for_usermode = 0,
                .phys_addr = phys_addr,
                .supress_ve = 0,
            };
        }

        pub inline fn physAddr(self: *const @This()) u64 {
            return @as(u64, self.phys_addr) << 30;
        }
    },

    pub fn makeEntry(comptime tag: enum { PD, @"1 GB" }, phys_addr: u64) @This() {
        return switch (tag) {
            .PD => .{ .PD = .makeEntry(@truncate(phys_addr >> 12)) },
            .@"1 GB" => .{ .@"1 GB" = .makeEntry(@truncate(phys_addr >> 30)) },
        };
    }

    pub inline fn initNotPresent() @This() {
        var entry: @This() = @bitCast(@as(u64, undefined));
        entry.setPresent(false);
        return entry;
    }

    pub inline fn present(self: *const @This()) bool {
        return self.PD.read != 0 or self.PD.write != 0 or self.PD.execute != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) void {
        const bit: u1 = @intFromBool(is_present);
        self.PD.read = bit;
        self.PD.write = bit;
        self.PD.execute = bit;
    }

    pub inline fn physAddr(self: *const @This(), comptime tag: enum { PD, @"1 GB" }) u64 {
        return switch (tag) {
            .PD => self.PD.physAddr(),
            .@"1 GB" => self.@"1 GB".physAddr(),
        };
    }
};

pub const EPT_PDE = packed union(u64) {
    PT: packed struct(u64) {
        read: u1,
        write: u1,
        execute: u1,
        rsvd1: u4 = 0,
        page_size: u1 = 0,
        accessed: u1,
        rsvd2: u1 = 0,
        exec_for_usermode: u1,
        rsvd3: u1 = 0,
        /// this is phys addr truncated (physical >> 12)
        /// stores the addr of an EPT_PTE table
        phys_addr: u36,
        rsvd4: u16 = 0,

        pub fn makeEntry(phys_addr: u36) @This() {
            return .{
                .read = 1,
                .write = 1,
                .execute = 1,
                .accessed = 0,
                .exec_for_usermode = 0,
                .phys_addr = phys_addr,
            };
        }

        pub inline fn physAddr(self: *const @This()) u64 {
            return @as(u64, self.phys_addr) << 12;
        }
    },
    @"2 MB": packed struct(u64) {
        read: u1,
        write: u1,
        execute: u1,
        ept_mem_type: u3,
        ignore_pat: u1,
        page_size: u1 = 1,
        accessed: u1,
        dirty: u1,
        exec_for_usermode: u1,
        rsvd1: u1 = 0,
        rsvd2: u9 = 0,
        /// this is phys addr truncated (physical >> 21)
        /// stores the physical addr in guest RAM
        phys_addr: u31,
        rsvd3: u11 = 0,
        supress_ve: u1,

        pub fn makeEntry(phys_addr: u31) @This() {
            return .{
                .read = 1,
                .write = 1,
                .execute = 1,
                .ept_mem_type = 6, // Write Back
                .ignore_pat = 0,
                .accessed = 0,
                .dirty = 0,
                .exec_for_usermode = 0,
                .phys_addr = phys_addr,
                .supress_ve = 0,
            };
        }

        pub inline fn physAddr(self: *const @This()) u64 {
            return @as(u64, self.phys_addr) << 21;
        }
    },

    pub fn makeEntry(comptime tag: enum { PT, @"2 MB" }, phys_addr: u64) @This() {
        return switch (tag) {
            .PT => .{ .PT = .makeEntry(@truncate(phys_addr >> 12)) },
            .@"2 MB" => .{ .@"2 MB" = .makeEntry(@truncate(phys_addr >> 21)) },
        };
    }

    pub inline fn initNotPresent() @This() {
        var entry: @This() = @bitCast(@as(u64, undefined));
        entry.setPresent(false);
        return entry;
    }

    pub inline fn present(self: *const @This()) bool {
        return self.PT.read != 0 or self.PT.write != 0 or self.PT.execute != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) void {
        const bit: u1 = @intFromBool(is_present);
        self.PT.read = bit;
        self.PT.write = bit;
        self.PT.execute = bit;
    }

    pub inline fn physAddr(self: *const @This(), comptime tag: enum { PT, @"2 MB" }) u64 {
        return switch (tag) {
            .PT => self.PT.physAddr(),
            .@"2 MB" => self.@"2 MB".physAddr(),
        };
    }
};

pub const EPT_PTE = packed struct(u64) {
    read: u1,
    write: u1,
    execute: u1,
    ept_mem_type: u3,
    ignore_pat: u1,
    rsvd1: u1 = 0,
    accessed: u1,
    dirty: u1,
    exec_for_usermode: u1,
    rsvd2: u1 = 0,
    /// this is phys addr truncated (physical >> 12)
    /// stores the physical addr in guest RAM
    phys_addr: u36,
    rsvd3: u15 = 0,
    supress_ve: u1,

    pub fn makeEntry(phys_addr: u64) @This() {
        return .{
            .read = 1,
            .write = 1,
            .execute = 1,
            .ept_mem_type = 6, // Write Back
            .ignore_pat = 0,
            .accessed = 0,
            .dirty = 0,
            .exec_for_usermode = 0,
            .phys_addr = @truncate(phys_addr >> 12),
            .supress_ve = 0,
        };
    }

    pub inline fn initNotPresent() @This() {
        var entry: @This() = @bitCast(@as(u64, undefined));
        entry.setPresent(false);
        return entry;
    }

    pub inline fn present(self: *const @This()) bool {
        return self.read != 0 or self.write != 0 or self.execute != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) void {
        const bit: u1 = @intFromBool(is_present);
        self.read = bit;
        self.write = bit;
        self.execute = bit;
    }

    pub inline fn physAddr(self: *const @This()) u64 {
        return @as(u64, self.phys_addr) << 12;
    }
};

inline fn zeroMem(ptr: anytype, comptime elem_t: type) void {
    const ZeroType = @Int(.unsigned, @bitSizeOf(elem_t));
    @memset(ptr.*[0..], @bitCast(@as(ZeroType, 0)));
}

/// creates a basic page table and populates `eptp`, `eptp_phys` and `guest_mem_addr` fields of guest_state
/// assumes guest_state is a hhdm mapped ptr
pub fn init(guest_state: *vmx.VMState) !void {
    const pml4: *align(4096) [512]EPT_PML4E = @ptrCast(try mem_allocator.kalloc.allocPage());
    // errdefer free(pml4)
    zeroMem(pml4, EPT_PML4E);

    const pdpt: *align(4096) [512]EPT_PDPTE = @ptrCast(try mem_allocator.kalloc.allocPage());
    // errdefer free(pdpt)
    zeroMem(pdpt, EPT_PDPTE);

    const pd: *align(4096) [512]EPT_PDE = @ptrCast(try mem_allocator.kalloc.allocPage());
    // errdefer free(pd)
    zeroMem(pd, EPT_PDE);

    const pt: *align(4096) [512]EPT_PTE = @ptrCast(try mem_allocator.kalloc.allocPage());
    // errdefer free(pt)
    zeroMem(pt, EPT_PTE);

    pd.*[0] = .makeEntry(.PT, hhdm.physOf(pt));
    pdpt.*[0] = .makeEntry(.PD, hhdm.physOf(pd));
    pml4.*[0] = .makeEntry(hhdm.physOf(pdpt));
    guest_state.eptp = .{
        .dirty_access_enabled = 1,
        .memory_type = 6, // Write Back
        .page_walk_length = 4 - 1, // 4 tables walked
        .pml4_addr = @truncate(hhdm.physOf(pml4) >> 12),
    };
    guest_state.eptp_phys = hhdm.physOf(&guest_state.eptp);

    const hlt_byte: u8 = 0xf4;

    // NOTE: we allocated 10 pages for the guest to use
    // the number 10 is arbitrary. should be dynamic in the future.
    var first: bool = true;
    for (0..10) |i| {
        const guest_mem_sect = try mem_allocator.kalloc.allocPage();
        @memset(guest_mem_sect.*[0..], hlt_byte);
        const phys_addr: u64 = hhdm.physOf(guest_mem_sect);
        if (first) {
            first = false;
            guest_state.guest_mem_addr = @intFromPtr(guest_mem_sect);
        }

        pt.*[i] = .makeEntry(phys_addr);
    }

    std.log.info("EPT ptr stored inside guest_state\n", .{});
}
