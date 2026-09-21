const std = @import("std");
const paging = @import("../arch/x86_64/paging.zig");
const PhysAddr = @import("address.zig").HostPhys;

pub const virt_base = 0xffff888000000000;
const pml4_idx = (virt_base >> 39) & 0x1ff;

var PDPTs: [512]paging.PDPTE_1GB align(0x1000) = undefined;

/// reverse of the HHDM mapping.
pub inline fn physOf(ptr: *const anyopaque) PhysAddr {
    return .from(@intFromPtr(ptr) & ~@as(u64, virt_base));
}

/// the pointer of type `P` through which `phys_addr` is reachable in the HHDM.
pub inline fn virtOf(comptime P: type, phys_addr: PhysAddr) P {
    return @ptrFromInt(phys_addr.raw() | virt_base);
}

pub fn init() void {
    for (&PDPTs, 0..) |*e, i|
        e.* = .kernel_page(@truncate(i));

    paging.PML4T[pml4_idx] = .kernel_page(paging.physAddrOfKernelVar(&PDPTs[0]));
    paging.refreshCr3();
}
