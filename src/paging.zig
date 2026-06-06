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
};

pub const PDPTE = packed struct(u64) {
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
        return PDPTE{
            .p = 1,
            .r_w = 1,
            .u_s = 0,
            .pwt = 0,
            .pcd = 0,
            .phys_addr = @truncate(phys_addr >> 12),
            .xd = 0,
        };
    }
};

pub const PDE = packed struct(u64) {
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
};

extern var kernel_physical_start: u8;
extern var kernel_size_in_4KIB_pages: u8;

extern var PML4T: [512]PML4E align(0x1000) linksection(".bss.boot");

var kernelPDPT: [512]PDPTE align(0x1000) linksection(".bss.boot") = undefined;
var kernelPD: [512]PDE align(0x1000) linksection(".bss.boot") = undefined;

pub fn init() linksection(".text.boot") void {
    // setting up kernel tables
    for (&kernelPDPT) |*e|
        e.* = @bitCast(@as(u64, 0));
    for (&kernelPD) |*e|
        e.* = @bitCast(@as(u64, 0));

    const kernel_physical_start_addr: u64 = @intFromPtr(&kernel_physical_start);
    const kernel_size_in_4KIB_pages_count: usize = @intFromPtr(&kernel_size_in_4KIB_pages);
    const kernel_size_2MIB_pages: usize = @divFloor(kernel_size_in_4KIB_pages_count - 1, 512) + 1;

    const higher_half_base = 0xFFFFFFFF80000000;
    const kernel_virtual_start = higher_half_base + kernel_physical_start_addr;

    // the first index of the PDE corresponding to the kernel
    const kernel_physical_start_pde_idx = (kernel_physical_start_addr >> 21) & 0x1ff;

    const kernel_pml4_idx = @as(u9, @truncate(kernel_virtual_start >> 39));
    const kernel_pdpt_idx = @as(u9, @truncate(kernel_virtual_start >> 30));

    for (0..kernel_size_2MIB_pages) |i| {
        const pdei = i + kernel_physical_start_pde_idx;

        kernelPD[pdei] = PDE{
            .p = 1,
            .r_w = 1,
            .u_s = 0,
            .pwt = 0,
            .pcd = 0,
            .g = 0,
            .pat = 0,
            .phys_addr = @truncate(pdei),
            .pk = 0,
            .xd = 0,
        };
    }

    kernelPDPT[kernel_pdpt_idx] = PDPTE.kernel_page(@intFromPtr(&kernelPD));
    // only update PML4 once everything is set up
    PML4T[kernel_pml4_idx] = PML4E.kernel_page(@intFromPtr(&kernelPDPT));
}
