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

    pub inline fn initNotPresent() linksection(".text.boot") @This() {
        var entry: @This() = @bitCast(@as(u64, undefined));
        entry.setPresent(false);
        return entry;
    }

    // NOTE: idk if I like this or not yet
    pub inline fn present(self: *const @This()) linksection(".text.boot") bool {
        return self.p != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) linksection(".text.boot") void {
        self.p = @intFromBool(is_present);
    }

    pub inline fn physAddr(self: *const @This()) linksection(".text.boot") u64 {
        return @as(u64, self.phys_addr) << 12;
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

        pub fn kernel_page(phys_addr: u40) linksection(".text.boot") @This() {
            return .{
                .p = 1,
                .r_w = 1,
                .u_s = 0,
                .pwt = 0,
                .pcd = 0,
                .phys_addr = phys_addr,
                .xd = 0,
            };
        }

        pub inline fn physAddr(self: *const @This()) linksection(".text.boot") u64 {
            return @as(u64, self.phys_addr) << 12;
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
                .phys_addr = phys_addr,
                .xd = 0,
            };
        }

        pub inline fn physAddr(self: *const @This()) linksection(".text.boot") u64 {
            return @as(u64, self.phys_addr) << 30;
        }
    },

    pub fn kernel_page(comptime tag: enum { PD, @"1 GB" }, phys_addr: u64) linksection(".text.boot") @This() {
        return switch (tag) {
            .PD => .{ .PD = .kernel_page(@truncate(phys_addr >> 12)) },
            .@"1 GB" => .{ .@"1 GB" = .kernel_page(@truncate(phys_addr >> 30)) },
        };
    }

    pub inline fn initNotPresent() linksection(".text.boot") @This() {
        var entry: @This() = @bitCast(@as(u64, undefined));
        entry.setPresent(false);
        return entry;
    }

    // NOTE: idk if I like this or not yet
    pub inline fn present(self: *const @This()) linksection(".text.boot") bool {
        return self.PD.p != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) linksection(".text.boot") void {
        self.PD.p = @intFromBool(is_present);
    }

    pub inline fn physAddr(self: *const @This(), comptime tag: enum { PD, @"1 GB" }) linksection(".text.boot") u64 {
        return switch (tag) {
            .PD => self.PD.physAddr(),
            .@"1 GB" => self.@"1 GB".physAddr(),
        };
    }
};

pub const PDE = packed union(u64) {
    PT: packed struct(u64) {
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

        pub fn kernel_page(phys_addr: u40) linksection(".text.boot") @This() {
            return .{
                .p = 1,
                .r_w = 1,
                .u_s = 0,
                .pwt = 0,
                .pcd = 0,
                .phys_addr = phys_addr,
                .xd = 0,
            };
        }

        pub inline fn physAddr(self: *const @This()) linksection(".text.boot") u64 {
            return @as(u64, self.phys_addr) << 12;
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

        pub inline fn physAddr(self: *const @This()) linksection(".text.boot") u64 {
            return @as(u64, self.phys_addr) << 21;
        }
    },

    pub fn kernel_page(comptime tag: enum { PT, @"2 MB" }, phys_addr: u64) linksection(".text.boot") @This() {
        return switch (tag) {
            .PT => .{ .PT = .kernel_page(@truncate(phys_addr >> 12)) },
            .@"2 MB" => .{ .@"2 MB" = .kernel_page(@truncate(phys_addr >> 21)) },
        };
    }

    pub inline fn initNotPresent() linksection(".text.boot") @This() {
        var entry: @This() = @bitCast(@as(u64, undefined));
        entry.setPresent(false);
        return entry;
    }

    // NOTE: idk if I like this or not yet
    pub inline fn present(self: *const @This()) linksection(".text.boot") bool {
        return self.PT.p != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) linksection(".text.boot") void {
        self.PT.p = @intFromBool(is_present);
    }

    pub inline fn physAddr(self: *const @This(), comptime tag: enum { PT, @"2 MB" }) linksection(".text.boot") u64 {
        return switch (tag) {
            .PT => self.PT.physAddr(),
            .@"2 MB" => self.@"2 MB".physAddr(),
        };
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

    pub inline fn initNotPresent() linksection(".text.boot") @This() {
        var entry: @This() = @bitCast(@as(u64, undefined));
        entry.setPresent(false);
        return entry;
    }

    // NOTE: idk if I like this or not yet
    pub inline fn present(self: *const @This()) linksection(".text.boot") bool {
        return self.p != 0;
    }

    pub inline fn setPresent(self: *@This(), is_present: bool) linksection(".text.boot") void {
        self.p = @intFromBool(is_present);
    }

    pub inline fn physAddr(self: *const @This()) linksection(".text.boot") u64 {
        return @as(u64, self.phys_addr) << 12;
    }
};

pub const PDPTE_PD = @TypeOf(@as(PDPTE, @bitCast(@as(u64, 0))).PD);
pub const PDPTE_1GB = @TypeOf(@as(PDPTE, @bitCast(@as(u64, 0))).@"1 GB");
pub const PDE_4KB = @TypeOf(@as(PDE, @bitCast(@as(u64, 0))).PT);
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
        e.* = .initNotPresent();
    for (&kernelPD) |*e|
        e.* = @bitCast(PDE.initNotPresent());

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

pub fn bumpBoundary() u64 {
    return (last_allocated_kernel_directory_page + 1) << 21;
}
