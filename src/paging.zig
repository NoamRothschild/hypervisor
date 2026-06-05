// This allows a processor to map 48-bit virtual addresses to 52-bit physical addresses.

pub const PML4E = packed struct(u64) {
    p: u1,
    r_w: u1,
    u_s: u1,
    pwt: u1,
    pcd: u1,
    a: u1,
    avl1: u1 = 0,
    rsvd: u1 = 0,
    avl2: u4 = 0,
    /// this is phys addr truncated (physical >> 12)
    /// to remove page offset
    phys_addr: u40,
    // rsvd: u0 = 0
    avl3: u11 = 0,
    xd: u1,
};

pub const PDPTE = packed struct(u64) {
    p: u1,
    r_w: u1,
    u_s: u1,
    pwt: u1,
    pcd: u1,
    a: u1,
    avl1: u1 = 0,
    ps: u1 = 0,
    avl2: u4 = 0,
    /// this is phys addr truncated (physical >> 12)
    /// to remove page offset
    phys_addr: u40,
    // rsvd: u0 = 0
    avl3: u11 = 0,
    xd: u1,
};

pub const PDE = packed struct(u64) {
    p: u1,
    r_w: u1,
    u_s: u1,
    pwt: u1,
    pcd: u1,
    a: u1,
    avl1: u1 = 0,
    ps: u1 = 0,
    avl2: u4 = 0,
    /// this is phys addr truncated (physical >> 12)
    /// to remove page offset
    phys_addr: u40,
    // rsvd: u0 = 0
    avl3: u11 = 0,
    xd: u1,
};

const PTE = packed struct(u64) {
    p: u1,
    r_w: u1,
    u_s: u1,
    pwt: u1,
    pcd: u1,
    a: u1,
    d: u1,
    pat: u1,
    g: u1,
    avl1: u3 = 0,
    /// this is phys addr truncated (physical >> 12)
    /// to remove page offset
    phys_addr: u40,
    // rsvd: u0 = 0
    avl2: u7 = 0,
    pk: u4,
    xd: u1,
};

/// DONT USE THIS
extern const kernel_physical_start: u8;
/// DONT USE THIS
extern const kernel_size_in_4KIB_pages: u8;

extern var PML4T: [512]PML4E align(0x1000) linksection(".bss.boot");

const N = 8;

var kernelPDPT: [512]PDPTE align(0x1000) linksection(".bss.boot") = undefined;
var kernelPD: [512]PDE align(0x1000) linksection(".bss.boot") = undefined;
var kernelPTs: [N][512]PTE align(0x1000) linksection(".bss.boot") = undefined;

pub fn init() linksection(".text.boot") void {
    // setting up kernel tables
    for (&kernelPDPT) |*e|
        e.* = @bitCast(@as(u64, 0));
    for (&kernelPD) |*e|
        e.* = @bitCast(@as(u64, 0));

    // 63          48 47      39 38      30 29      21 20      12 11       0
    // +-------------+----------+----------+----------+----------+-----------+
    // | Sign Extend | PML4 idx | PDPT idx | PD idx   | PT idx   | Offset    |
    // +-------------+----------+----------+----------+----------+-----------+
    //                   9 bits     9 bits    9 bits    9 bits     12 bits

    const kernel_physical_start_addr: usize = @intFromPtr(&kernel_physical_start);
    const kernel_size_in_4KIB_pages_count: usize = @intFromPtr(&kernel_size_in_4KIB_pages);

    const kernel_pt_count: usize = 1 + kernel_size_in_4KIB_pages_count / 512;

    const higher_half_base = 0xFFFFFFFF80000000;
    const kernel_virtual_start = higher_half_base + kernel_physical_start_addr;
    const kernel_virtual_end = kernel_virtual_start + kernel_size_in_4KIB_pages_count * 0x1000;

    // assumes the kernel is less than 512GiB in memory (wtf)
    const kernel_pml4_idx = @as(u9, @truncate(kernel_virtual_start >> 39));
    // assumes the kernel is less than 512GiB in memory (wtf)
    const kernel_pdpt_idx = @as(u9, @truncate(kernel_virtual_start >> 30));

    const kernel_pd_base_idx = @as(u9, @truncate(kernel_virtual_start >> 21));
    const kernel_pd_end_idx = @as(u9, @truncate((kernel_virtual_end - 1) >> 21)) + 1;
    const kernel_pd_count = kernel_pd_end_idx - kernel_pd_base_idx;

    const kernel_pt_base_idx = 0;
    const kernel_pt_end_idx = kernel_pt_base_idx + kernel_pt_count;

    PML4T[kernel_pml4_idx] = PML4E{
        .p = 1,
        .r_w = 1,
        .phys_addr = @truncate(@intFromPtr(&kernelPDPT) >> 12),
    };

    kernelPDPT[kernel_pdpt_idx] = PDPTE{
        .p = 1,
        .r_w = 1,
        .phys_addr = @truncate(@intFromPtr(&kernelPD) >> 12),
    };

    for (kernelPTs.len) |i| {
        kernelPD[i] = PDE{
            // .p = 1,
            // .r_w = 1,
            // .phys_addr = @truncate(@intFromPtr(&kernelPD) >> 12),
        };
    }

    _ = kernel_pt_end_idx;
    _ = kernel_pd_count;
}
