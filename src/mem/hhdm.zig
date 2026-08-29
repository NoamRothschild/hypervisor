const std = @import("std");
const paging = @import("../arch/x86_64/paging.zig");

pub const virt_base = 0xffff888000000000;
const pml4_idx = (virt_base >> 39) & 0x1ff;

var PDPTs: [512]paging.PDPTE_1GB align(0x1000) = undefined;

pub fn init() void {
    for (&PDPTs, 0..) |*e, i|
        e.* = .kernel_page(@truncate(i));

    paging.PML4T[pml4_idx] = .kernel_page(paging.physAddrOfKernelVar(&PDPTs[0]));
    paging.refreshCr3();
}
