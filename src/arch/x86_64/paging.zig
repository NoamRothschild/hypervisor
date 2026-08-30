const std = @import("std");
const assert = std.debug.assert;
// This allows a processor to map 48-bit virtual addresses to 52-bit physical addresses.

pub const PML4E = packed struct(u64) {
    p: u1,
    r_w: u1,
    u_s: u1,
    pwt: u1,
    pcd: u1,
    a: u1 = 0,
    avl1: u1 = 0,
    rsvd: u1 = 0,
    avl2: u4 = 0,
    /// this is phys addr truncated (physical >> 12)
    /// stores the addr of a PDPT
    phys_addr: u40,
    // rsvd: u0 = 0
    avl3: u11 = 0,
    xd: u1,

    pub fn kernel_page(phys_addr: u64) linksection(".text.boot") @This() {
        return PML4E{
            .p = 1,
            .r_w = 1,
            .u_s = 0,
            .pwt = 0,
            .pcd = 0,
            .phys_addr = @truncate(phys_addr >> 12),
            .xd = 0,
        };
    }

    // NOTE: idk if I like this or not yet
    pub inline fn present(self: *const @This()) linksection(".text.boot") bool {
        return self.p != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) linksection(".text.boot") void {
        self.p = @intFromBool(is_present);
    }
};

pub const PDPTE = packed union(u64) {
    PD: packed struct(u64) {
        p: u1,
        r_w: u1,
        u_s: u1,
        pwt: u1,
        pcd: u1,
        a: u1 = 0,
        avl1: u1 = 0,
        ps: u1 = 0,
        avl2: u4 = 0,
        /// this is phys addr truncated (physical >> 12)
        /// stores the addr of a PD
        phys_addr: u40,
        // rsvd: u0 = 0
        avl3: u11 = 0,
        xd: u1,

        pub fn kernel_page(phys_addr: u64) linksection(".text.boot") @This() {
            return .{
                .p = 1,
                .r_w = 1,
                .u_s = 0,
                .pwt = 0,
                .pcd = 0,
                .phys_addr = @truncate(phys_addr >> 12),
                .xd = 0,
            };
        }
    },
    @"1 GB": packed struct(u64) {
        p: u1,
        r_w: u1,
        u_s: u1,
        pwt: u1,
        pcd: u1,
        a: u1 = 0,
        d: u1 = 0,
        ps: u1 = 1,
        g: u1,
        avl1: u3 = 0,
        pat: u1,
        rsvd: u17 = 0,
        /// this is phys addr truncated (physical >> 30)
        /// stores the physical addr in RAM
        phys_addr: u22,
        avl2: u7 = 0,
        pk: u4,
        xd: u1,

        pub fn kernel_page(phys_addr: u22) linksection(".text.boot") @This() {
            return .{
                .p = 1,
                .ps = 1,
                .r_w = 1,
                .u_s = 0,
                .pwt = 0,
                .pcd = 0,
                .pat = 0,
                .g = 0,
                .pk = 0,
                .phys_addr = @truncate(phys_addr),
                .xd = 0,
            };
        }
    },

    pub fn kernel_page(comptime tag: enum { PD, @"1 GB" }, phys_addr: u64) linksection(".text.boot") @This() {
        return switch (tag) {
            .PD => .{ .PD = .kernel_page(phys_addr) },
            .@"1 GB" => .{ .@"1 GB" = .kernel_page(@truncate(phys_addr)) },
        };
    }

    // NOTE: idk if I like this or not yet
    pub inline fn present(self: *const @This()) linksection(".text.boot") bool {
        return self.PD.p != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) linksection(".text.boot") void {
        self.PD.p = @intFromBool(is_present);
    }
};

pub const PDE = packed union(u64) {
    @"4 KB": packed struct(u64) {
        p: u1,
        r_w: u1,
        u_s: u1,
        pwt: u1,
        pcd: u1,
        a: u1 = 0,
        avl1: u1 = 0,
        ps: u1 = 0,
        avl2: u4 = 0,
        /// this is phys addr truncated (physical >> 12)
        /// stores the addr of a PT
        phys_addr: u40,
        // rsvd: u0 = 0
        avl3: u11 = 0,
        xd: u1,

        pub fn kernel_page(phys_addr: u64) linksection(".text.boot") @This() {
            return .{
                .p = 1,
                .r_w = 1,
                .u_s = 0,
                .pwt = 0,
                .pcd = 0,
                .phys_addr = @truncate(phys_addr >> 12),
                .xd = 0,
            };
        }
    },
    @"2 MB": packed struct(u64) {
        p: u1,
        r_w: u1,
        u_s: u1,
        pwt: u1,
        pcd: u1,
        a: u1 = 0,
        d: u1 = 0,
        ps: u1 = 1,
        g: u1,
        avl1: u3 = 0,
        pat: u1,
        rsvd: u8 = 0,
        /// this is phys addr truncated (physical >> 21)
        /// stores the physical addr in RAM
        phys_addr: u31,
        // rsvd: u0 = 0
        avl2: u7 = 0,
        pk: u4,
        xd: u1,

        pub fn kernel_page(phys_addr: u31) linksection(".text.boot") @This() {
            return .{
                .p = 1,
                .r_w = 1,
                .u_s = 0,
                .pwt = 0,
                .pcd = 0,
                .g = 0,
                .pat = 0,
                .phys_addr = phys_addr,
                .pk = 0,
                .xd = 0,
            };
        }
    },

    pub fn kernel_page(comptime page_size: enum { @"4 KB", @"2 MB" }, phys_addr: u64) linksection(".text.boot") @This() {
        return switch (page_size) {
            .@"4 KB" => .{ .@"4 KB" = .kernel_page(phys_addr) },
            .@"2 MB" => .{ .@"2 MB" = .kernel_page(@truncate(phys_addr)) },
        };
    }

    // NOTE: idk if I like this or not yet
    pub inline fn present(self: *const @This()) linksection(".text.boot") bool {
        return self.@"4 KB".p != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) linksection(".text.boot") void {
        self.@"4 KB".p = @intFromBool(is_present);
    }
};

pub const PTE = packed struct(u64) {
    p: u1,
    r_w: u1,
    u_s: u1,
    pwt: u1,
    pcd: u1,
    a: u1 = 0,
    d: u1 = 0,
    pat: u1,
    g: u1,
    avl1: u3 = 0,
    /// this is phys addr truncated (physical >> 12)
    /// stores the physical addr in RAM
    phys_addr: u40,
    avl2: u7 = 0,
    pk: u4,
    xd: u1,

    pub fn kernel_page(phys_addr: u64) linksection(".text.boot") @This() {
        return PTE{
            .p = 1,
            .r_w = 1,
            .u_s = 0,
            .pwt = 0,
            .pcd = 0,
            .pat = 0,
            .g = 0,
            .phys_addr = @truncate(phys_addr >> 12),
            .pk = 0,
            .xd = 0,
        };
    }

    // NOTE: idk if I like this or not yet
    pub inline fn present(self: *const @This()) linksection(".text.boot") bool {
        return self.p != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) linksection(".text.boot") void {
        self.p = @intFromBool(is_present);
    }
};

pub const PDPTE_PD = @TypeOf(@as(PDPTE, @bitCast(@as(u64, 0))).PD);
pub const PDPTE_1GB = @TypeOf(@as(PDPTE, @bitCast(@as(u64, 0))).@"1 GB");
pub const PDE_4KB = @TypeOf(@as(PDE, @bitCast(@as(u64, 0))).@"4 KB");
pub const PDE_2MB = @TypeOf(@as(PDE, @bitCast(@as(u64, 0))).@"2 MB");

extern var kernel_physical_start: u8;
extern var kernel_size_in_4KIB_pages: u8;

pub extern var PML4T: [512]PML4E align(0x1000) linksection(".bss.boot");

var kernelPDPT: [512]PDPTE align(0x1000) linksection(".bss.boot") = undefined;
var kernelPD: [512]PDE_2MB align(0x1000) linksection(".bss.boot") = undefined;
var last_allocated_kernel_directory_page: usize linksection(".bss.boot") = 0;

pub const higher_half_base: comptime_int = 0xFFFFFFFF80000000;

// initialized after .init()
var kernel_pml4_idx: usize linksection(".data.boot") = 0;
var kernel_pdpt_idx: usize linksection(".data.boot") = 0;

comptime {
    @export(&init, .{ .name = "paging_init" });
}
pub fn init() linksection(".text.boot") callconv(.c) void {
    // if an integer overflow happens here, calling @panic would just cause a page fault because the page did not get created
    // it is best to disable it here.
    @setRuntimeSafety(false);

    // setting up kernel tables
    for (&kernelPDPT) |*e|
        e.* = @bitCast(@as(u64, 0));
    for (&kernelPD) |*e|
        e.* = @bitCast(@as(u64, 0));

    const kernel_physical_start_addr: u64 = @intFromPtr(&kernel_physical_start);
    const kernel_size_in_4KIB_pages_count: usize = @intFromPtr(&kernel_size_in_4KIB_pages);
    const kernel_size_2MIB_pages: usize = @divFloor(kernel_size_in_4KIB_pages_count - 1, 512) + 1;

    const kernel_virtual_start = higher_half_base + kernel_physical_start_addr;

    // the first index of the PDE corresponding to the kernel
    const kernel_physical_start_pde_idx = (kernel_physical_start_addr >> 21) & 0x1ff;

    kernel_pml4_idx = @as(u9, @truncate(kernel_virtual_start >> 39));
    kernel_pdpt_idx = @as(u9, @truncate(kernel_virtual_start >> 30));

    for (0..kernel_size_2MIB_pages) |i| {
        const pdei = i + kernel_physical_start_pde_idx;

        kernelPD[pdei] = .kernel_page(@truncate(pdei));
    }
    // last pdei value
    last_allocated_kernel_directory_page = kernel_size_2MIB_pages - 1 + kernel_physical_start_pde_idx;

    kernelPDPT[kernel_pdpt_idx] = PDPTE.kernel_page(.PD, @intFromPtr(&kernelPD));
    // only update PML4 once everything is set up
    PML4T[kernel_pml4_idx] = PML4E.kernel_page(@intFromPtr(&kernelPDPT));

    refreshCr3();
}

pub inline fn refreshCr3() linksection(".text.boot") void {
    asm volatile (
        \\ mov %%cr3, %%rax
        \\ mov %%rax, %%cr3
        ::: .{ .rax = true, .memory = true });
}

/// reverse the effect of |'ing with the higher half base
pub fn physAddrOfKernelVar(ptr: *anyopaque) u64 {
    return @intFromPtr(ptr) & ~@as(u64, higher_half_base);
}

/// allocates and returns an aligned virtual addr of a free 2MiB page.
///  virtual addr lives inside the higher half mapping
///
/// TODO: move page allocation into a different pml4e / pdpte,
/// use a StaticBitSet instead of the last allocated mechanism
pub fn allocPage() !u64 {
    if (last_allocated_kernel_directory_page + 1 >= kernelPD.len)
        return error.PageDirectoryFull;

    const last_allocated_phys = kernelPD[last_allocated_kernel_directory_page].phys_addr;
    last_allocated_kernel_directory_page +%= 1;

    const new_pd_idx = last_allocated_kernel_directory_page;
    kernelPD[new_pd_idx] = .kernel_page(last_allocated_phys +% 1);

    return (new_pd_idx << 21) | (kernel_pdpt_idx << 30) | (kernel_pml4_idx << 39) | (0xffff << 48);
}

pub fn unmapPage(virt_addr: u64) void {
    const pml4_idx: usize = (virt_addr >> 39) & 0x1ff;
    const pdpt_idx: usize = (virt_addr >> 30) & 0x1ff;
    const pd_idx: usize = (virt_addr >> 21) & 0x1ff;

    if (pml4_idx != kernel_pml4_idx)
        @panic("tried to unmap a page inside a pml4e that is not the kernel pml4e");

    if (pdpt_idx != kernel_pdpt_idx)
        @panic("tried to unmap a page inside a pdpte that is not the kernel pdpte");

    if (kernelPD[pd_idx].p == 0)
        @panic("tried to unmap a page with present already set to false");

    kernelPD[pd_idx].p = 0;
}

/// returns the physical addr of virt_addr if found, else null.
/// only looks up from addesses received from alloc_page()
/// assumes inside a 2 MiB page.
pub fn physAddr(virt_addr: u64) ?u64 {
    const pml4_idx: usize = (virt_addr >> 39) & 0x1ff;
    const pdpt_idx: usize = (virt_addr >> 30) & 0x1ff;
    const pd_idx: usize = (virt_addr >> 21) & 0x1ff;

    if (pml4_idx != kernel_pml4_idx)
        return null;

    if (pdpt_idx != kernel_pdpt_idx)
        return null;

    // if (kernelPD[pd_idx].ps = 0) // PT with 4KiB entries
    return (kernelPD[pd_idx].phys_addr << 21) | (virt_addr & 0x1f_ffff);
}

pub const Allocator4K = struct {
    curr_page: ?u64 = null,
    offset: u16 = 0,

    pub const empty = Allocator4K{};

    pub fn init(self: *@This()) !void {
        self.curr_page = try allocPage();
        self.offset = 0;
    }

    pub fn curr(self: *@This()) u64 {
        assert(self.offset < 512);
        assert(self.curr_page != null);

        return self.curr_page.? + (@as(u64, self.offset) << 12);
    }

    pub fn next(self: *@This()) !u64 {
        defer self.offset += 1;
        if (self.offset == 512 or self.curr_page == null)
            try self.init();

        return self.curr();
    }
};

var alloc_4k_aligned_state: Allocator4K = .empty;

/// allocates and returns an aligned virtual addr of a free 4KiB page.
///  virtual addr lives inside the higher half mapping
pub fn alloc4KAligned() !*align(4096) [4096]u8 {
    return @ptrFromInt(try alloc_4k_aligned_state.next());
}
