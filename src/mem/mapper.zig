const std = @import("std");
const debug = @import("../debug.zig");
const assert = std.debug.assert;
const hhdm = @import("hhdm.zig");
const paging = @import("../arch/x86_64/paging.zig");
const page_allocator = @import("page_allocator.zig");

const PhysAddr = page_allocator.PhysAddr;
const VirtAddr = page_allocator.VirtAddr;
const PageSize = page_allocator.PageSize;

/// TEMPORARY. will be replaced by page_allocator.PageAllocator when it will be done.
pub const DumbAllocator = struct {
    pub fn alloc(_: *DumbAllocator, ps: PageSize) PhysAddr {
        if (ps != .@"4 KB")
            @panic("unimplemented");

        return paging.physAddrOfKernelVar(
            paging.alloc4KAligned() catch @panic("OOM"),
        );
    }

    pub fn reserve(_: *DumbAllocator, start: PhysAddr, end: PhysAddr) void {
        _ = start;
        _ = end;
    }

    pub fn free(_: *DumbAllocator, _: PhysAddr, _: PageSize) void {
        @panic("unimplemented");
    }
};

pub const Error = error{};

pub const Mapper = struct {
    /// responsible for marking regions in memory as "used" in its internal datastrucutre.
    allocator: *DumbAllocator,

    pub fn map(self: *Mapper, vaddr: VirtAddr, paddr: PhysAddr, ps: PageSize, flags: anytype) Error!void {
        _ = flags;

        const pml4_idx: usize = (vaddr >> 39) & 0x1ff;
        const pdpt_idx: usize = (vaddr >> 30) & 0x1ff;
        const pd_idx: usize = (vaddr >> 21) & 0x1ff;
        const pt_idx: usize = (vaddr >> 12) & 0x1ff;

        defer paging.refreshCr3();

        const pdpt: *[512]paging.PDPTE = if (!paging.PML4T[pml4_idx].present()) create_new: {
            const pdpt_phys = self.allocator.alloc(.@"4 KB");
            const pdpt: *[512]paging.PDPTE = @ptrFromInt(pdpt_phys | hhdm.virt_base);
            for (pdpt) |*e|
                e.* = .initNotPresent();

            paging.PML4T[pml4_idx] = .kernel_page(pdpt_phys);
            break :create_new pdpt;
        } else exists: {
            const pdpt_hhdm_addr = paging.PML4T[pml4_idx].physAddr() | hhdm.virt_base;
            break :exists @ptrFromInt(pdpt_hhdm_addr);
        };

        if (ps == .@"1 GB") {
            const entry = &pdpt.*[pdpt_idx];
            if (!entry.present())
                entry.* = .kernel_page(.@"1 GB", paddr);
            return;
        }

        const pd: *[512]paging.PDE = if (!pdpt.*[pdpt_idx].present()) create_new: {
            const pd_phys = self.allocator.alloc(.@"4 KB");
            const pd: *[512]paging.PDE = @ptrFromInt(pd_phys | hhdm.virt_base);
            for (pd) |*e|
                e.* = .initNotPresent();

            pdpt.*[pdpt_idx] = .kernel_page(.PD, pd_phys);
            break :create_new pd;
        } else exists: {
            const pd_hhdm_addr = pdpt.*[pdpt_idx].physAddr(.PD) | hhdm.virt_base;
            break :exists @ptrFromInt(pd_hhdm_addr);
        };

        if (ps == .@"2 MB") {
            const entry = &pd.*[pd_idx];
            if (!entry.present())
                entry.* = .kernel_page(.@"2 MB", paddr);
            return;
        }

        const pt: *[512]paging.PTE = if (!pd.*[pd_idx].present()) create_new: {
            const pt_phys = self.allocator.alloc(.@"4 KB");
            const pt: *[512]paging.PTE = @ptrFromInt(pt_phys | hhdm.virt_base);
            for (pt) |*e|
                e.* = .initNotPresent();

            pd.*[pd_idx] = .kernel_page(.PT, pt_phys);
            break :create_new pt;
        } else exists: {
            const pt_hhdm_addr = pd.*[pd_idx].physAddr(.PT) | hhdm.virt_base;
            break :exists @ptrFromInt(pt_hhdm_addr);
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

    pub fn translate(self: *Mapper, vaddr: VirtAddr) ?struct { paddr: PhysAddr, ps: PageSize } {
        _ = self;
        const pml4_idx: usize = (vaddr >> 39) & 0x1ff;
        const pdpt_idx: usize = (vaddr >> 30) & 0x1ff;
        const pd_idx: usize = (vaddr >> 21) & 0x1ff;
        const pt_idx: usize = (vaddr >> 12) & 0x1ff;

        const pml4e_p = paging.PML4T[pml4_idx].present();
        if (!pml4e_p) return null;

        const pdpt_paddr = paging.PML4T[pml4_idx].physAddr();
        const pdpt: *[512]paging.PDPTE = @ptrFromInt(pdpt_paddr | hhdm.virt_base);

        const pdpte: *paging.PDPTE = &pdpt.*[pdpt_idx];
        if (!pdpte.present()) return null;

        const pdpte_phys_addr: u64 = if (pdpte.PD.ps == 1)
            pdpte.physAddr(.@"1 GB")
        else
            pdpte.physAddr(.PD);

        if (pdpt.*[pdpt_idx].@"1 GB".ps == 1) {
            return .{
                .paddr = pdpte_phys_addr,
                .ps = .@"1 GB",
            };
        }

        const pd_paddr = pdpte_phys_addr;
        const pd: *[512]paging.PDE = @ptrFromInt(pd_paddr | hhdm.virt_base);

        const pde: *paging.PDE = &pd.*[pd_idx];
        if (!pde.present()) return null;
        const pde_phys_addr: u64 = if (pde.PT.ps == 1)
            pde.physAddr(.@"2 MB")
        else
            pde.physAddr(.PT);

        if (pd.*[pd_idx].@"2 MB".ps == 1) {
            return .{
                .paddr = pde_phys_addr,
                .ps = .@"2 MB",
            };
        }

        const pt_paddr = pde_phys_addr;
        const pt: *[512]paging.PTE = @ptrFromInt(pt_paddr | hhdm.virt_base);

        const pte: *paging.PTE = &pt.*[pt_idx];
        if (!pte.present()) return null;

        return .{
            .paddr = pte.physAddr(),
            .ps = .@"4 KB",
        };
    }
};

pub fn test1() void {
    var mapper = Mapper{ .allocator = undefined };
    var my_var: u8 = 69;
    const phys_addr_my_var = paging.physAddrOfKernelVar(&my_var);

    const virt_page_addr = 0xffffCCDD40000000;
    const virt = virt_page_addr | phys_addr_my_var;
    debug.printf("trying to map 0x{x} to 0x{x}\n", .{ virt, phys_addr_my_var });
    mapper.map(virt, phys_addr_my_var, .@"4 KB", .{}) catch {};

    if (mapper.translate(virt)) |info| {
        debug.printf("tranlate -> {}\n", .{info});
    }

    // const my_var_ref: *u8 = @ptrFromInt(phys_addr_my_var | hhdm.virt_base);
    const my_var_ref: *u8 = @ptrFromInt(virt);
    debug.printf("trying to access virt and got: {d}\n", .{my_var_ref.*});
    assert(my_var_ref.* == my_var);
}
