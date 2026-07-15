const std = @import("std");
const paging = @import("../arch/x86_64/paging.zig");
const ept = @import("ept.zig");
const msr = @import("msr.zig");
const debug = @import("../debug.zig");
const rdmsr = msr.rdmsr;
const wrmsr = msr.wrmsr;

pub inline fn supportsVirtualization() bool {
    if (!std.mem.eql(u8, &debug.getVendor(), "GenuineIntel"))
        return false;

    if (debug.getFeatures().vmx != 1)
        return false;

    var fc_msr: msr.IA32_FEATURE_CONTROL = @bitCast(rdmsr(msr.msr.IA32_FEATURE_CONTROL));
    if (fc_msr.lock == 0) {
        fc_msr.lock = 1;
        fc_msr.enable_vmxon = 1;
        wrmsr(msr.msr.IA32_FEATURE_CONTROL, @bitCast(fc_msr));
    } else if (fc_msr.enable_vmxon == 0) {
        std.log.err("VMX locked off in BIOS", .{});
        return false;
    }

    return true;
}

/// Sets CR0/CR4 to values required for VMX operation (including VMXE).
pub fn enableOperation() void {
    var cr0: u64 = undefined;
    var cr4: u64 = undefined;

    asm volatile ("mov %%cr0, %[cr0]"
        : [cr0] "=r" (cr0),
    );
    asm volatile ("mov %%cr4, %[cr4]"
        : [cr4] "=r" (cr4),
    );

    const cr0_fixed0 = rdmsr(msr.vt_msrs.IA32_VMX_CR0_FIXED0);
    const cr0_fixed1 = rdmsr(msr.vt_msrs.IA32_VMX_CR0_FIXED1);
    const cr4_fixed0 = rdmsr(msr.vt_msrs.IA32_VMX_CR4_FIXED0);
    const cr4_fixed1 = rdmsr(msr.vt_msrs.IA32_VMX_CR4_FIXED1);

    cr0 |= cr0_fixed0;
    cr0 &= cr0_fixed1;
    cr4 |= cr4_fixed0;
    cr4 &= cr4_fixed1;

    asm volatile ("mov %[cr0], %%cr0"
        :
        : [cr0] "r" (cr0),
        : .{ .memory = true });
    asm volatile ("mov %[cr4], %%cr4"
        :
        : [cr4] "r" (cr4),
        : .{ .memory = true });
}

pub const VMState = extern struct {
    /// phys addr
    vmxon_region: u64,
    /// phys addr
    vmcs_region: u64,
    /// virt addr
    eptp: ept.EPTP,
    /// phys addr
    eptp_phys: u64,
    /// virt addr, stack for vmm in VM-Exit state
    vmm_stack: *[4096]u8,
    /// msr bitmap virt addr
    msr_bitmap: *[4096]u8,
    /// msr bitmap phys addr
    msr_bitmap_phys: u64,
};

/// holds the address of where our guest code starts
var guest_mem_addr: u64 = 0;

const hlt_byte: comptime_int = 0xf4;

/// Prepares the VMXON region and executes VMXON.
pub fn allocVmxonRegion(guest_state: *VMState) !void {
    const vmxon_page = try paging.alloc4KAligned();
    const vmxon_virt = @intFromPtr(vmxon_page);
    const vmxon_region_phys = paging.physAddr(vmxon_virt) orelse return error.vmxon_region_not_mapped;

    std.log.info("virtual buff addr for VMXON at 0x{x}\n", .{vmxon_virt});
    std.log.info("physical buff addr for VMXON at 0x{x}\n", .{vmxon_region_phys});

    @memset(vmxon_page, 0);

    const basic = rdmsr(msr.vt_msrs.IA32_VMX_BASIC);
    const revision_identifier: u32 = @truncate(basic);
    std.log.info("IA32_VMX_BASIC revision identifier: 0x{x}\n", .{revision_identifier});

    @as(*volatile u32, @ptrCast(vmxon_page)).* = revision_identifier;

    // carry flag result
    var failed: u8 = undefined;
    // zero flag result
    var valid_fail: u8 = undefined;

    asm volatile (
        \\ vmxon (%[vmxon_phys_ptr])
        \\ setc %[failed]
        \\ setz %[valid_fail]
        : [failed] "=qm" (failed),
          [valid_fail] "=qm" (valid_fail),
        : [vmxon_phys_ptr] "r" (&vmxon_region_phys),
    );

    if (failed != 0)
        return error.vmxon_failed_cf;

    if (valid_fail != 0) {
        debug.printf("vmxon failed with {d}\n", .{vmerr()});
        return error.vmxon_failed_with_code;
    }

    guest_state.vmxon_region = vmxon_region_phys;
}

pub fn vmxoff() void {
    std.log.info("terminating vmx...\n", .{});
    asm volatile ("vmxoff");
}

/// calls vmlaunch.
/// ret val indicates success of operation
///
/// returns either if vmlaunch failed
/// or when after the VM caused an exit (will block)
pub fn vmlaunch() bool {
    var ret: u8 = 69;
    asm volatile ("call __vmlaunch"
        : [ret] "={al}" (ret),
    );

    return ret != 0;
}

var old_rbp: u64 = 0;
var old_rsp: u64 = 0;

export fn __vmlaunch() callconv(.naked) u8 {
    asm volatile (
        \\ push %rbp
        \\ mov %rsp, %rbp
    );

    asm volatile (
        \\ mov %rbp, %[old_rbp]
        \\ mov %rsp, %[old_rsp]
        \\
        \\ vmlaunch
        \\
        \\ call __vmlaunchFailed
        \\ mov $0, %rax
        \\ pop %rbp
        \\ ret
        : [old_rbp] "=m" (old_rbp),
          [old_rsp] "=m" (old_rsp),
        :
        : .{ .rax = true });
}

export fn __vmlaunchFailed() callconv(.c) void {
    std.log.err("vmlaunch failed with error code: {d}\n", .{vmerr()});
}

/// the back point from a vm exit
fn __vmlaunchSucceed() callconv(.naked) u8 {
    asm volatile (
        \\ mov %[old_rbp], %rbp
        \\ mov %[old_rsp], %rsp
        \\
        \\ mov $1, %rax
        \\ pop %rbp
        \\ ret
        :
        : [old_rbp] "m" (old_rbp),
          [old_rsp] "m" (old_rsp),
    );
}

/// reads the instruction error field to get the error code
pub fn vmerr() u64 {
    var ret: u64 = 0;
    asm volatile ("vmread %[field], %[ret]"
        : [ret] "=rm" (ret),
        : [field] "r" (0x00004400),
    );
    return ret;
}
