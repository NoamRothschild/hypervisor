const std = @import("std");
const paging = @import("paging.zig");
// set the 7th bit of PDPTE to map a 1 GB page
// set the 7th bit of PDE to maps a 2 MB page
// note that in both scenarios the structure of the entry will differ. look in the intel manual for it.

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
    phys_addr: u36,
    rsvd4: u16 = 0,
};

pub const EPT_PDPTE = EPT_PML4E;
pub const EPT_PDE = EPT_PML4E;

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
    phys_addr: u36,
    rsvd3: u15 = 0,
    supress_ve: u1,
};

pub fn makeEntry(comptime T: type, phys_addr: u64) T {
    return T{
        .accessed = 0,
        .execute = 1,
        .exec_for_usermode = 0,
        .phys_addr = @truncate(phys_addr >> 12),
        .read = 1,
        .write = 1,
    };
}

inline fn zeroMem(ptr: anytype, comptime elem_t: type) void {
    const ZeroType = @Int(.unsigned, @bitSizeOf(elem_t));
    @memset(ptr.*[0..], @bitCast(@as(ZeroType, 0)));
}

pub fn init() !*EPTP {
    // FIXME: we allocate a whole 4KiB region for 8 bytes (ept_ptr).
    const shared_buf = try paging.alloc4KAligned();
    // errdefer free(shared_buf)
    zeroMem(shared_buf, u8);

    const ept_ptr: *EPTP = @ptrCast(&shared_buf[0]);

    const pml4: *align(4096) [512]EPT_PML4E = @ptrCast(try paging.alloc4KAligned());
    // errdefer free(pml4)
    zeroMem(pml4, EPT_PML4E);

    const pdpt: *align(4096) [512]EPT_PDPTE = @ptrCast(try paging.alloc4KAligned());
    // errdefer free(pdpt)
    zeroMem(pdpt, EPT_PDPTE);

    const pd: *align(4096) [512]EPT_PDE = @ptrCast(try paging.alloc4KAligned());
    // errdefer free(pd)
    zeroMem(pd, EPT_PDE);

    const pt: *align(4096) [512]EPT_PTE = @ptrCast(try paging.alloc4KAligned());
    // errdefer free(pt)
    zeroMem(pt, EPT_PTE);

    pd.*[0] = makeEntry(EPT_PDE, paging.physAddr(@intFromPtr(pt)).?);
    pdpt.*[0] = makeEntry(EPT_PDPTE, paging.physAddr(@intFromPtr(pd)).?);
    pml4.*[0] = makeEntry(EPT_PML4E, paging.physAddr(@intFromPtr(pdpt)).?);
    ept_ptr.* = EPTP{
        .dirty_access_enabled = 1,
        .memory_type = 6, // Write Back
        .page_walk_length = 4 - 1, // 4 tables walked
        .pml4_addr = @truncate(paging.physAddr(@intFromPtr(pml4)).? >> 12),
    };

    // NOTE: we allocated 10 pages for the guest to use
    // the number 10 is arbitrary. should be dynamic in the future.
    for (0..10) |i| {
        const guest_mem_sect = try paging.alloc4KAligned();
        zeroMem(guest_mem_sect, u8);
        const phys_addr: u64 = paging.physAddr(@intFromPtr(guest_mem_sect)).?;

        pt.*[i] = EPT_PTE{
            .accessed = 0,
            .dirty = 0,
            .ept_mem_type = 6,
            .execute = 1,
            .exec_for_usermode = 0,
            .ignore_pat = 0,
            .phys_addr = @truncate(phys_addr >> 12),
            .read = 1,
            .supress_ve = 0,
            .write = 1,
        };
    }

    std.log.info("EPT ptr allocated at 0x{x}\n", .{@intFromPtr(ept_ptr)});
    return ept_ptr;
}
