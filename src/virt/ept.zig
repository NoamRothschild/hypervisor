const std = @import("std");
const hhdm = @import("../mem/hhdm.zig");
const mem_allocator = @import("../mem/allocator.zig");
const vmx = @import("vmx.zig");
const msr = @import("msr.zig");
const paging = @import("../arch/x86_64/paging.zig");
const GuestAllocator = @import("../mem/guest_allocator.zig");
const kalloc = &@import("../mem/allocator.zig").kalloc;
// EPT tables map guest-physical addresses to host-physical addresses.

const address = @import("../mem/address.zig");

pub const HostPhys = address.HostPhys;
pub const GuestPhys = address.GuestPhys;
pub const GuestVirt = address.GuestVirt;

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

    pub fn makeEntry(phys_addr: HostPhys) @This() {
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

    pub inline fn physAddr(self: *const @This()) HostPhys {
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

        pub inline fn physAddr(self: *const @This()) HostPhys {
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

        pub inline fn physAddr(self: *const @This()) HostPhys {
            return @as(u64, self.phys_addr) << 30;
        }
    },

    pub fn makeEntry(comptime tag: enum { PD, @"1 GB" }, phys_addr: HostPhys) @This() {
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

    pub inline fn physAddr(self: *const @This(), comptime tag: enum { PD, @"1 GB" }) HostPhys {
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

        pub inline fn physAddr(self: *const @This()) HostPhys {
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

        pub inline fn physAddr(self: *const @This()) HostPhys {
            return @as(u64, self.phys_addr) << 21;
        }
    },

    pub fn makeEntry(comptime tag: enum { PT, @"2 MB" }, phys_addr: HostPhys) @This() {
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

    pub inline fn physAddr(self: *const @This(), comptime tag: enum { PT, @"2 MB" }) HostPhys {
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

    pub fn makeEntry(phys_addr: HostPhys) @This() {
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

    pub inline fn physAddr(self: *const @This()) HostPhys {
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

/// Guest physical 3GB-4GB holds no RAM and is left unmapped for device MMIO.
pub const mmio_hole_start: GuestPhys = 3 << 30;
pub const mmio_hole_end: GuestPhys = 4 << 30;
/// the 1GB slot of guest physical memory taken by the hole
const hole_slot = mmio_hole_start >> 30;

comptime {
    // the RAM block <-> slot translation assumes the hole is exactly one 1GB slot
    std.debug.assert(mmio_hole_end - mmio_hole_start == 1 << 30);
}

/// The 1GB slot of guest physical memory RAM block `i` is mapped at.
pub fn blockSlot(i: usize) usize {
    return if (i < hole_slot) i else i + 1;
}

/// The RAM block holding guest physical `addr`, null if `addr` isn't RAM.
fn blockOf(guest_state: *vmx.VMState, addr: u64) ?usize {
    const slot = addr >> 30;
    if (slot == hole_slot) return null;
    const i = if (slot < hole_slot) slot else slot - 1;
    return if (i < guest_state.guest_mem_pages.len) i else null;
}

/// the size of one RAM block, and of the guest physical slot it is mapped at
const block_size: usize = 1 << 30;

pub const GuestMemError = error{
    /// part of the range is outside guest RAM, or inside the MMIO hole
    NotRam,
    /// the address isn't naturally aligned for the type
    Misaligned,
    /// the value is RAM, but split between two RAM blocks, which aren't adjacent in host memory
    CrossesBlock,
};

/// Errors unless all of guest physical `gpa`..`gpa + len` is RAM.
/// Safe for any guest-controlled `gpa` and `len`: the end of the range can't overflow.
pub fn checkRam(guest_state: *vmx.VMState, gpa: GuestPhys, len: usize) GuestMemError!void {
    if (len == 0) return;
    const last = std.math.add(u64, gpa, len - 1) catch return error.NotRam;
    // RAM is a run of slots, so this stops at most one slot past the last block
    var slot = gpa >> 30;
    while (slot <= last >> 30) : (slot += 1) {
        if (blockOf(guest_state, slot << 30) == null) return error.NotRam;
    }
}

/// The host memory behind a range of guest RAM, one slice per RAM block the range touches.
/// Guest RAM that is contiguous in the guest isn't contiguous in the host: every block is
/// its own allocation, so a range crossing a 1GB boundary is two host slices.
pub const GuestChunks = struct {
    guest_state: *vmx.VMState,
    gpa: GuestPhys,
    left: usize,

    pub fn next(self: *GuestChunks) ?[]u8 {
        if (self.left == 0) return null;
        const inner: usize = @intCast(self.gpa & (block_size - 1));
        const n = @min(self.left, block_size - inner);
        // the range was checked by `guestChunks`
        const block = self.guest_state.guest_mem_pages[blockOf(self.guest_state, self.gpa).?];
        self.gpa += n;
        self.left -= n;
        return block[inner..][0..n];
    }
};

/// Iterates the host memory behind guest physical `gpa`..`gpa + len`, which must all be RAM.
pub fn guestChunks(guest_state: *vmx.VMState, gpa: GuestPhys, len: usize) GuestMemError!GuestChunks {
    try checkRam(guest_state, gpa, len);
    return .{ .guest_state = guest_state, .gpa = gpa, .left = len };
}

/// Copies `dst.len` bytes of guest RAM at `gpa` into `dst`.
/// Use it for anything the guest can change under you and that you check before using
/// (descriptors, packet headers): validate the copy, never re-read guest memory.
pub fn readGuestBytes(guest_state: *vmx.VMState, dst: []u8, gpa: GuestPhys) GuestMemError!void {
    var chunks = try guestChunks(guest_state, gpa, dst.len);
    var done: usize = 0;
    while (chunks.next()) |chunk| {
        @memcpy(dst[done..][0..chunk.len], chunk);
        done += chunk.len;
    }
}

/// A pointer to a `T` in guest RAM, for memory the guest shares with a device, like the
/// `idx` fields of a virtqueue. `gpa` must be naturally aligned, which makes the pointer
/// usable with @atomicLoad / @atomicStore. Natural alignment also keeps any `T` no larger
/// than its alignment (u16, u32, u64) inside one block; a bigger `T` may cross one.
pub fn guestPtr(comptime T: type, guest_state: *vmx.VMState, gpa: GuestPhys) GuestMemError!*T {
    if (gpa % @alignOf(T) != 0) return error.Misaligned;
    var chunks = try guestChunks(guest_state, gpa, @sizeOf(T));
    const chunk = chunks.next().?;
    if (chunk.len != @sizeOf(T)) return error.CrossesBlock;
    return @ptrCast(@alignCast(chunk.ptr));
}

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
        const page: HugePagePtr = hhdm.virtOf(HugePagePtr, page_phys);
        pdpt.*[blockSlot(0)] = .makeEntry(.@"1 GB", page_phys);

        guest_state.guest_mem_pages[0] = page;
        break :blk page;
    };
    @memset(first_block[0..4096], hlt_byte);

    for (1..block_count) |i| {
        // out of guest memory handled at the top of the scope.
        const page_phys = guest_allocator.alloc(1) catch unreachable;
        const page: HugePagePtr = hhdm.virtOf(HugePagePtr, page_phys);

        // note: we can clear memory, but it would be very expensive.
        // this will fix a possible attack vector where a user gets hold
        // of a memory block previously owned by another user, and read his
        // old RAM data.

        guest_state.guest_mem_pages[i] = page;
        pdpt.*[blockSlot(i)] = .makeEntry(.@"1 GB", page_phys);
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

/// translates a guest-physical address to a pointer into the guest's RAM.
pub fn guestPhysToHostVirt(guest_state: *vmx.VMState, guest_phys: GuestPhys, must_4k_align: bool) !*u8 {
    const inner_offset: usize = @rem(guest_phys, (1 << 30));
    if (must_4k_align and inner_offset & ((1 << 12) - 1) != 0)
        return error.Non4KAlignedPageTableEntry;
    const huge_page_idx = blockOf(guest_state, guest_phys) orelse
        return error.OOBRamAddr;

    const page_ptr = guest_state.guest_mem_pages[huge_page_idx];
    return &page_ptr.*[inner_offset];
}

/// walks the guest's current 4-level page tables
pub fn guestVirtToHostVirt(guest_state: *vmx.VMState, guest_cr3: GuestPhys, va: GuestVirt) !*u8 {
    const pml4_idx: usize = (va >> 39) & 0x1ff;
    const pdpt_idx: usize = (va >> 30) & 0x1ff;
    const pd_idx: usize = (va >> 21) & 0x1ff;
    const pt_idx: usize = (va >> 12) & 0x1ff;

    // the low 12 bits hold the PCID when CR4.PCIDE=1, and bit 63 is the no-flush flag
    const cr3_masked: GuestPhys = guest_cr3 & 0x000f_ffff_ffff_f000;
    const pml4: *[512]paging.PML4E = @ptrCast(@alignCast(try guestPhysToHostVirt(guest_state, cr3_masked, true)));
    const pml4e: *paging.PML4E = &pml4.*[pml4_idx];
    if (!pml4e.present()) return error.AddressUnmapped;

    const pdpt: *[512]paging.PDPTE = @ptrCast(@alignCast(try guestPhysToHostVirt(guest_state, pml4e.physAddr(), true)));
    const pdpte: *paging.PDPTE = &pdpt.*[pdpt_idx];
    if (!pdpte.present()) return error.AddressUnmapped;

    if (pdpte.@"1 GB".ps == 1)
        return guestPhysToHostVirt(guest_state, pdpte.physAddr(.@"1 GB") | (va & 0x3fff_ffff), false);

    const pd: *[512]paging.PDE = @ptrCast(@alignCast(try guestPhysToHostVirt(guest_state, pdpte.physAddr(.PD), true)));
    const pde: *paging.PDE = &pd.*[pd_idx];
    if (!pde.present()) return error.AddressUnmapped;

    if (pde.@"2 MB".ps == 1)
        return guestPhysToHostVirt(guest_state, pde.physAddr(.@"2 MB") | (va & 0x1f_ffff), false);

    const pt: *[512]paging.PTE = @ptrCast(@alignCast(try guestPhysToHostVirt(guest_state, pde.physAddr(.PT), true)));
    const pte: *paging.PTE = &pt.*[pt_idx];
    if (!pte.present()) return error.AddressUnmapped;

    return guestPhysToHostVirt(guest_state, pte.physAddr() | (va & 0xfff), false);
}

pub const InvEptDescriptor = packed struct(u128) {
    eptp: EPTP,
    rsvd: u64 = 0,
};

pub const InvEptType = enum(u64) {
    /// Invalidates EPT-derived TLB mappings and paging-structure caches
    /// associated only with the specific EPTP address provided in the descriptor.
    single_context = 1,

    /// Invalidates EPT-derived TLB mappings and paging-structure caches
    /// across ALL EPTP contexts globally.
    global_context = 2,
};

pub fn invept(invept_type: InvEptType, eptp: EPTP) void {
    const desc: InvEptDescriptor = .{ .eptp = eptp };
    asm volatile ("invept (%[desc]), %[type]"
        :
        : [type] "r" (@intFromEnum(invept_type)),
          [desc] "r" (&desc),
        : .{ .memory = true });
}

/// copies a `T` out of guest-physical memory.
/// handles unaligned addresses and values that straddle a block boundary.
pub fn readGuestPhys(comptime T: type, guest_state: *vmx.VMState, gpa: GuestPhys) GuestMemError!T {
    var val: T = undefined;
    try readGuestBytes(guest_state, std.mem.asBytes(&val), gpa);
    return val;
}

/// copies a `T` out of guest-virtual memory, walking the page tables at `guest_cr3`.
/// handles unaligned addresses and values that straddle a page boundary.
pub fn readGuestVirt(comptime T: type, guest_state: *vmx.VMState, guest_cr3: GuestPhys, gva: GuestVirt) !T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    var done: usize = 0;
    while (done < bytes.len) {
        const addr = gva +% done;
        const n = @min(bytes.len - done, 0x1000 - (addr & 0xfff));
        const src: [*]const u8 = @ptrCast(try guestVirtToHostVirt(guest_state, guest_cr3, addr));
        @memcpy(bytes[done..][0..n], src[0..n]);
        done += n;
    }
    return @bitCast(bytes);
}

/// loads an image into the guest mem at addr `base_addr`
/// `base_addr` range is [0, total_mem_available]
pub fn writeGuest(guest_state: *vmx.VMState, image: []const u8, base_addr: GuestPhys) error{OutOfMemory}!void {
    var chunks = guestChunks(guest_state, base_addr, image.len) catch return error.OutOfMemory;
    var done: usize = 0;
    while (chunks.next()) |chunk| {
        @memcpy(chunk, image[done..][0..chunk.len]);
        done += chunk.len;
    }
}

/// `base_addr` range is [0, total_mem_available]
pub fn memsetGuest(guest_state: *vmx.VMState, value: u8, base_addr: GuestPhys, len: usize) !void {
    var chunks = guestChunks(guest_state, base_addr, len) catch return error.OutOfMemory;
    while (chunks.next()) |chunk| @memset(chunk, value);
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

    // identity-map guest-physical 0 up to the end of RAM, the MMIO hole included.
    // the 1GB entry stores addr >> 30, so slot i is simply i.
    for (0..blockSlot(block_count - 1) + 1) |i|
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
