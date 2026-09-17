const std = @import("std");
const hhdm = @import("../mem/hhdm.zig");
const mem_allocator = @import("../mem/allocator.zig");
const vmx = @import("vmx.zig");
const msr = @import("msr.zig");
const paging = @import("../arch/x86_64/paging.zig");
const GuestAllocator = @import("../mem/guest_allocator.zig");
const kalloc = &@import("../mem/allocator.zig").kalloc;
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
    /// this is phys addr truncated (physical >> 12)
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

/// for guests starting in x86-64 (requires paging to already be enabled)
const guest_pml4_gpa = 0x1000;
const guest_pdpt_gpa = 0x2000;

const HugePage = [1 << 30]u8;
const HugePagePtr = *align(0x1000) HugePage;

/// creates a basic page table and populates `guest_cr3` and `guest_pml4` fields of guest_state
/// assumes guest_state is a hhdm mapped ptr
pub fn init(guest_state: *vmx.VMState, guest_allocator: *GuestAllocator, block_count: usize) !EPTP {
    if (block_count == 0)
        return error.NoGuestMemProvided;
    if (guest_allocator.availBlocks() < block_count)
        return error.OutOfGuestMemory;

    // IA32_VMX_EPT_VPID_CAP bits this EPT layout relies on.
    const caps: msr.IA32_VMX_EPT_VPID_CAP = @bitCast(msr.rdmsr(.IA32_VMX_EPT_VPID_CAP));
    if (caps.page_walk_length_4 == 0) return error.EptNoPageWalkLength4;
    if (caps.memory_type_wb == 0) return error.EptNoWriteBack;
    if (caps.pages_1gb == 0) return error.EptNo1GbPages;

    guest_state.guest_mem_pages = try kalloc.alloc(HugePagePtr, block_count);
    errdefer kalloc.free(guest_state.guest_mem_pages);

    const pml4: *align(4096) [512]EPT_PML4E = @ptrCast(try mem_allocator.kalloc.allocPage());
    guest_state.guest_pml4 = pml4;
    errdefer mem_allocator.kalloc.freePage(@ptrCast(pml4));
    zeroMem(pml4, EPT_PML4E);

    const pdpt: *align(4096) [512]EPT_PDPTE = @ptrCast(try mem_allocator.kalloc.allocPage());
    errdefer mem_allocator.kalloc.freePage(@ptrCast(pdpt));
    zeroMem(pdpt, EPT_PDPTE);

    pml4.*[0] = .makeEntry(hhdm.physOf(pdpt));

    const hlt_byte: u8 = 0xf4;

    const first_block: HugePagePtr = blk: {
        // out of guest memory handled at the top of the scope.
        const page_phys = guest_allocator.alloc(1) catch unreachable;
        const page: HugePagePtr = @ptrFromInt(hhdm.virtOf(page_phys));
        pdpt.*[0] = .makeEntry(.@"1 GB", page_phys);

        guest_state.guest_mem_pages[0] = page;
        break :blk page;
    };
    @memset(first_block[0..4096], hlt_byte);

    for (1..block_count) |i| {
        // out of guest memory handled at the top of the scope.
        const page_phys = guest_allocator.alloc(1) catch unreachable;
        const page: HugePagePtr = @ptrFromInt(hhdm.virtOf(page_phys));

        // note: we can clear memory, but it would be very expensive.
        // this will fix a possible attack vector where a user gets hold
        // of a memory block previously owned by another user, and read his
        // old RAM data.

        guest_state.guest_mem_pages[i] = page;
        pdpt.*[i] = .makeEntry(.@"1 GB", page_phys);
    }

    initGuestPageTables(first_block, block_count);
    guest_state.guest_cr3 = guest_pml4_gpa;
    std.log.info("EPT ptr stored inside guest_state\n", .{});

    return EPTP{
        .dirty_access_enabled = caps.dirty_access_flags,
        .memory_type = 6, // Write Back
        .page_walk_length = 4 - 1, // 4 tables walked
        .pml4_addr = @truncate(hhdm.physOf(pml4) >> 12),
    };
}

pub fn guestPhysToHostVirt(guest_state: *vmx.VMState, guest_phys: u64, must_4k_align: bool) !u64 {
    const huge_page_idx: usize = @divFloor(guest_phys, (1 << 30));
    const inner_offset: usize = @rem(guest_phys, (1 << 30));
    if (must_4k_align and inner_offset & ((1 << 12) - 1) != 0)
        return error.Non4KAlignedPageTableEntry;
    if (huge_page_idx >= guest_state.guest_mem_pages.len)
        return error.OOBRamAddr;

    const page_ptr = guest_state.guest_mem_pages[huge_page_idx];
    return @intFromPtr(&page_ptr.*[inner_offset]);
}

/// walks the guest's current 4-level page tables
pub fn guestVirtToHostVirt(guest_state: *vmx.VMState, guest_cr3: u64, vaddr: u64) !u64 {
    const pml4_idx: usize = (vaddr >> 39) & 0x1ff;
    const pdpt_idx: usize = (vaddr >> 30) & 0x1ff;
    const pd_idx: usize = (vaddr >> 21) & 0x1ff;
    const pt_idx: usize = (vaddr >> 12) & 0x1ff;

    // the low 12 bits hold the PCID when CR4.PCIDE=1, and bit 63 is the no-flush flag
    const cr3_masked = guest_cr3 & 0x000f_ffff_ffff_f000;
    const pml4: *[512]paging.PML4E = @ptrFromInt(try guestPhysToHostVirt(guest_state, cr3_masked, true));
    const pml4e: *paging.PML4E = &pml4.*[pml4_idx];
    if (!pml4e.present()) return error.AddressUnmapped;

    const pdpt: *[512]paging.PDPTE = @ptrFromInt(try guestPhysToHostVirt(guest_state, pml4e.physAddr(), true));
    const pdpte: *paging.PDPTE = &pdpt.*[pdpt_idx];
    if (!pdpte.present()) return error.AddressUnmapped;

    if (pdpte.@"1 GB".ps == 1)
        return guestPhysToHostVirt(guest_state, pdpte.physAddr(.@"1 GB") | (vaddr & 0x3fff_ffff), false);

    const pd: *[512]paging.PDE = @ptrFromInt(try guestPhysToHostVirt(guest_state, pdpte.physAddr(.PD), true));
    const pde: *paging.PDE = &pd.*[pd_idx];
    if (!pde.present()) return error.AddressUnmapped;

    if (pde.@"2 MB".ps == 1)
        return guestPhysToHostVirt(guest_state, pde.physAddr(.@"2 MB") | (vaddr & 0x1f_ffff), false);

    const pt: *[512]paging.PTE = @ptrFromInt(try guestPhysToHostVirt(guest_state, pde.physAddr(.PT), true));
    const pte: *paging.PTE = &pt.*[pt_idx];
    if (!pte.present()) return error.AddressUnmapped;

    return guestPhysToHostVirt(guest_state, pte.physAddr() | (vaddr & 0xfff), false);
}

/// copies a `T` out of guest-virtual memory.
/// handles unaligned addresses and values that straddle a page boundary.
pub fn readGuest(comptime T: type, guest_state: *vmx.VMState, base_addr: u64, cr3_if_virt: ?u64) !T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    var done: usize = 0;
    while (done < bytes.len) {
        const addr = base_addr +% done;
        const n = @min(bytes.len - done, 0x1000 - (addr & 0xfff));
        const src: [*]const u8 = @ptrFromInt(if (cr3_if_virt) |cr3|
            try guestVirtToHostVirt(guest_state, cr3, addr)
        else
            try guestPhysToHostVirt(guest_state, addr, false));
        @memcpy(bytes[done..][0..n], src[0..n]);
        done += n;
    }
    return @bitCast(bytes);
}

/// loads an image into the guest mem at addr `base_addr`
/// `base_addr` range is [0, total_mem_available]
pub fn writeGuest(guest_state: *vmx.VMState, image: []const u8, base_addr: usize) error{OutOfMemory}!void {
    if ((base_addr + image.len) >> 30 > guest_state.guest_mem_pages.len)
        return error.OutOfMemory;

    var done: usize = 0;
    while (done < image.len) {
        const addr = base_addr +% done;
        const addr_in_page = addr & ((1 << 30) - 1);
        const n = @min(image.len - done, (1 << 30) - addr_in_page);
        const page_idx = (addr - addr_in_page) >> 30;
        @memcpy(guest_state.guest_mem_pages[page_idx].*[addr_in_page .. addr_in_page + n], image[done .. done + n]);
        done += n;
    }
}

/// FIXME: edgecases of OOB not properly tested
/// `base_addr` range is [0, total_mem_available]
pub fn memsetGuest(guest_state: *vmx.VMState, value: u8, base_addr: usize, len: usize) !void {
    var done: usize = 0;
    while (done < len) {
        const addr = base_addr +% done;
        const addr_in_page = addr & ((1 << 30) - 1);
        const n = @min(len - done, (1 << 30) - addr_in_page);
        const page_idx = (addr - addr_in_page) >> 30;
        @memset(guest_state.guest_mem_pages[page_idx].*[addr_in_page .. addr_in_page + n], value);
        done += n;
    }
}

/// Builds an x86-64 identity map page table for the guest, inside the guest RAM
/// this is required because we cannot launch a guest in x86-64 without paging enabled.
/// when booting up guests from real mode, this will not be used, but built by the guest.
fn initGuestPageTables(first_block: *align(0x1000) [GuestAllocator.block_size]u8, block_count: usize) void {
    const pml4: *align(0x1000) [512]paging.PML4E = @ptrFromInt(@intFromPtr(first_block) + guest_pml4_gpa);
    const pdpt: *align(0x1000) [512]paging.PDPTE = @ptrFromInt(@intFromPtr(first_block) + guest_pdpt_gpa);
    zeroMem(pml4, paging.PML4E);
    zeroMem(pdpt, paging.PDPTE);

    pml4.*[0] = .{
        .p = 1,
        .r_w = 1,
        .u_s = 0,
        .pwt = 0,
        .pcd = 0,
        .phys_addr = @intCast(guest_pdpt_gpa >> 12),
        .xd = 0,
    };

    // identity-map guest-physical 0 .. block_count GB.
    // the 1GB entry stores addr >> 30, so block i is simply i.
    for (0..block_count) |i|
        pdpt.*[i] = .{ .@"1 GB" = .{
            .p = 1,
            .r_w = 1,
            .u_s = 0,
            .pwt = 0,
            .pcd = 0,
            .pat = 0,
            .g = 0,
            .pk = 0,
            .phys_addr = @intCast(i),
            .xd = 0,
        } };
}
