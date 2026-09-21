const std = @import("std");
const debug = @import("../debug.zig");
const assert = std.debug.assert;
const hhdm = @import("hhdm.zig");
const paging = @import("../arch/x86_64/paging.zig");
const mem_allocator = @import("allocator.zig");
const PhysAddr = @import("address.zig").HostPhys;
const VirtAddr = @import("address.zig").HostVirt;

pub const PageSize = enum {
    @"1 GB",
    @"2 MB",
    @"4 KB",
};

pub const Error = std.mem.Allocator.Error;

pub const Mapper = struct {
    /// hands out the 4KB pages backing every table this mapper creates
    allocator: *mem_allocator.KAlloc,

    pub fn map(self: *Mapper, virt: VirtAddr, paddr: PhysAddr, ps: PageSize, flags: anytype) Error!void {
        _ = flags;

        const vaddr = virt.raw();
        const pml4_idx: usize = (vaddr >> 39) & 0x1ff;
        const pdpt_idx: usize = (vaddr >> 30) & 0x1ff;
        const pd_idx: usize = (vaddr >> 21) & 0x1ff;
        const pt_idx: usize = (vaddr >> 12) & 0x1ff;

        defer paging.refreshCr3();

        const pdpt: *[512]paging.PDPTE = if (!paging.PML4T[pml4_idx].present()) create_new: {
            const pdpt_phys = hhdm.physOf(try self.allocator.allocPage());
            const pdpt = hhdm.virtOf(*[512]paging.PDPTE, pdpt_phys);
            for (pdpt) |*e|
                e.* = .initNotPresent();

            paging.PML4T[pml4_idx] = .kernel_page(pdpt_phys);
            break :create_new pdpt;
        } else exists: {
            break :exists hhdm.virtOf(*[512]paging.PDPTE, .from(paging.PML4T[pml4_idx].physAddr()));
        };

        if (ps == .@"1 GB") {
            const entry = &pdpt.*[pdpt_idx];
            if (!entry.present())
                entry.* = .kernel_page(.@"1 GB", paddr);
            return;
        }

        const pd: *[512]paging.PDE = if (!pdpt.*[pdpt_idx].present()) create_new: {
            const pd_phys = hhdm.physOf(try self.allocator.allocPage());
            const pd = hhdm.virtOf(*[512]paging.PDE, pd_phys);
            for (pd) |*e|
                e.* = .initNotPresent();

            pdpt.*[pdpt_idx] = .kernel_page(.PD, pd_phys);
            break :create_new pd;
        } else exists: {
            break :exists hhdm.virtOf(*[512]paging.PDE, .from(pdpt.*[pdpt_idx].physAddr(.PD)));
        };

        if (ps == .@"2 MB") {
            const entry = &pd.*[pd_idx];
            if (!entry.present())
                entry.* = .kernel_page(.@"2 MB", paddr);
            return;
        }

        const pt: *[512]paging.PTE = if (!pd.*[pd_idx].present()) create_new: {
            const pt_phys = hhdm.physOf(try self.allocator.allocPage());
            const pt = hhdm.virtOf(*[512]paging.PTE, pt_phys);
            for (pt) |*e|
                e.* = .initNotPresent();

            pd.*[pd_idx] = .kernel_page(.PT, pt_phys);
            break :create_new pt;
        } else exists: {
            break :exists hhdm.virtOf(*[512]paging.PTE, .from(pd.*[pd_idx].physAddr(.PT)));
        };

        const entry = &pt.*[pt_idx];
        if (!entry.present())
            entry.* = .kernel_page(paddr);
    }

    pub fn unmap(self: *Mapper, vaddr: VirtAddr, ps: PageSize) void {
        _ = self;
        _ = vaddr;
        _ = ps;
        @panic("unimplemented");
    }

    pub fn translate(pml4: *[512]paging.PML4E, virt: VirtAddr) ?struct { paddr: PhysAddr, ps: PageSize } {
        const vaddr = virt.raw();
        const pml4_idx: usize = (vaddr >> 39) & 0x1ff;
        const pdpt_idx: usize = (vaddr >> 30) & 0x1ff;
        const pd_idx: usize = (vaddr >> 21) & 0x1ff;
        const pt_idx: usize = (vaddr >> 12) & 0x1ff;

        const pml4e_p = pml4.*[pml4_idx].present();
        if (!pml4e_p) return null;

        const pdpt = hhdm.virtOf(*[512]paging.PDPTE, .from(pml4.*[pml4_idx].physAddr()));

        const pdpte: *paging.PDPTE = &pdpt.*[pdpt_idx];
        if (!pdpte.present()) return null;

        const pdpte_phys_addr: PhysAddr = .from(if (pdpte.PD.ps == 1)
            pdpte.physAddr(.@"1 GB")
        else
            pdpte.physAddr(.PD));

        if (pdpt.*[pdpt_idx].@"1 GB".ps == 1) {
            return .{
                .paddr = pdpte_phys_addr,
                .ps = .@"1 GB",
            };
        }

        const pd = hhdm.virtOf(*[512]paging.PDE, pdpte_phys_addr);

        const pde: *paging.PDE = &pd.*[pd_idx];
        if (!pde.present()) return null;
        const pde_phys_addr: PhysAddr = .from(if (pde.PT.ps == 1)
            pde.physAddr(.@"2 MB")
        else
            pde.physAddr(.PT));

        if (pd.*[pd_idx].@"2 MB".ps == 1) {
            return .{
                .paddr = pde_phys_addr,
                .ps = .@"2 MB",
            };
        }

        const pt = hhdm.virtOf(*[512]paging.PTE, pde_phys_addr);

        const pte: *paging.PTE = &pt.*[pt_idx];
        if (!pte.present()) return null;

        return .{
            .paddr = .from(pte.physAddr()),
            .ps = .@"4 KB",
        };
    }
};

pub fn test1() void {
    var mapper = Mapper{ .allocator = &mem_allocator.kalloc };
    var my_var: u8 = 69;
    const phys_addr_my_var = paging.physAddrOfKernelVar(&my_var);

    const virt_page_addr = 0xffffCCDD40000000;
    const virt: VirtAddr = .from(virt_page_addr | phys_addr_my_var.raw());
    debug.printf("trying to map 0x{x} to 0x{x}\n", .{ virt.raw(), phys_addr_my_var.raw() });
    mapper.map(virt, phys_addr_my_var, .@"4 KB", .{}) catch {};

    if (Mapper.translate(&paging.PML4T, virt)) |info| {
        debug.printf("tranlate -> {}\n", .{info});
    }

    // const my_var_ref: *u8 = @ptrFromInt(phys_addr_my_var | hhdm.virt_base);
    const my_var_ref: *u8 = @ptrFromInt(virt.raw());
    debug.printf("trying to access virt and got: {d}\n", .{my_var_ref.*});
    assert(my_var_ref.* == my_var);
}
