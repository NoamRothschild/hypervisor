const std = @import("std");
const paging = @import("arch/x86_64/paging.zig");
const debug = @import("debug.zig");

pub inline fn supportsVirtualization() bool {
    if (!std.mem.eql(u8, &debug.getVendor(), "GenuineIntel"))
        return false;

    if (debug.getFeatures().vmx != 1)
        return false;

    var fc_msr: IA32_FEATURE_CONTROL = @bitCast(rdmsr(msr.IA32_FEATURE_CONTROL));
    if (fc_msr.lock == 0) {
        fc_msr.lock = 1;
        fc_msr.enable_vmxon = 1;
        wrmsr(msr.IA32_FEATURE_CONTROL, @bitCast(fc_msr));
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

    const cr0_fixed0 = rdmsr(vt_msrs.IA32_VMX_CR0_FIXED0);
    const cr0_fixed1 = rdmsr(vt_msrs.IA32_VMX_CR0_FIXED1);
    const cr4_fixed0 = rdmsr(vt_msrs.IA32_VMX_CR4_FIXED0);
    const cr4_fixed1 = rdmsr(vt_msrs.IA32_VMX_CR4_FIXED1);

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
    vmxon_region: u64,
    vmcs_region: u64,
};

var guest_state: VMState = .{ .vmxon_region = 0, .vmcs_region = 0 };

/// Prepares the VMXON region and executes VMXON.
pub fn allocVmxonRegion() !void {
    const vmxon_page = try paging.alloc4KAligned();
    const vmxon_virt = @intFromPtr(vmxon_page);
    const vmxon_region_phys = paging.physAddr(vmxon_virt) orelse return error.vmxon_region_not_mapped;

    std.log.info("virtual buff addr for VMXON at 0x{x}\n", .{vmxon_virt});
    std.log.info("physical buff addr for VMXON at 0x{x}\n", .{vmxon_region_phys});

    @memset(vmxon_page, 0);

    const basic = rdmsr(vt_msrs.IA32_VMX_BASIC);
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
        // read the instruction error field to get the error code
        var ret: u64 = 0;
        asm volatile ("vmread %[field], %[ret]"
            : [ret] "=rm" (ret),
            : [field] "r" (0x00004400),
        );

        debug.printf("vmxon failed with {d}\n", .{ret});
        return error.vmxon_failed_with_code;
    }

    guest_state.vmxon_region = vmxon_region_phys;
}

/// Prepares the VMCS region and executes VMPTRLD.
pub fn allocVmcsRegion() !void {
    const vmcs_page = try paging.alloc4KAligned();
    const vmcs_virt = @intFromPtr(vmcs_page);
    const vmcs_region_phys = paging.physAddr(vmcs_virt) orelse return error.vmcs_region_not_mapped;

    std.log.info("virtual buff addr for VMCS at 0x{x}\n", .{vmcs_virt});
    std.log.info("physical buff addr for VMCS at 0x{x}\n", .{vmcs_region_phys});

    @memset(vmcs_page, 0);

    const basic = rdmsr(vt_msrs.IA32_VMX_BASIC);
    const revision_identifier: u32 = @truncate(basic);
    std.log.info("IA32_VMX_BASIC revision identifier: 0x{x}\n", .{revision_identifier});

    @as(*volatile u32, @ptrCast(vmcs_page)).* = revision_identifier;

    var cf: u8 = undefined;
    var zf: u8 = undefined;

    asm volatile (
        \\ vmptrld (%[vmcs_phys_ptr])
        \\ setc %[cf]
        \\ setz %[zf]
        : [cf] "=qm" (cf),
          [zf] "=qm" (zf),
        : [vmcs_phys_ptr] "r" (&vmcs_region_phys),
    );

    if (cf != 0) {
        std.log.err("vmptrld failed with {s} (zf={d})\n", .{ if (zf == 0) "VMFailInvalid" else "VMFailValid", @intFromBool(zf != 0) });
        if (zf != 0) {
            // read the instruction error field to get the error code
            var ret: u64 = 0;
            asm volatile ("vmread %[field], %[ret]"
                : [ret] "=rm" (ret),
                : [field] "r" (0x00004400),
            );
            debug.printf("vmptrld failiure error code: {d}", .{ret});
        }
        return error.vmtprld_failed;
    }

    guest_state.vmcs_region = vmcs_region_phys;
}

pub fn terminateVmx() void {
    std.log.info("terminating vmx...\n", .{});
    asm volatile ("vmxoff");
}

pub inline fn rdmsr(msr_id: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr_id),
    );
    return (@as(u64, high) << 32) | low;
}

pub inline fn wrmsr(msr_id: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);

    asm volatile ("wrmsr"
        :
        : [low] "{eax}" (low),
          [high] "{edx}" (high),
          [msr] "{ecx}" (msr_id),
        : .{ .memory = true });
}

/// Intel defined MSRs.
/// source: https://elixir.bootlin.com/linux/v4.2/source/arch/x86/include/asm/msr-index.h#L375
pub const msr = struct {
    pub const IA32_P5_MC_ADDR = 0x00000000;
    pub const IA32_P5_MC_TYPE = 0x00000001;
    pub const IA32_TSC = 0x00000010;
    pub const IA32_PLATFORM_ID = 0x00000017;
    pub const IA32_EBL_CR_POWERON = 0x0000002a;
    pub const EBC_FREQUENCY_ID = 0x0000002c;
    pub const SMI_COUNT = 0x00000034;
    pub const IA32_FEATURE_CONTROL = 0x0000003a;
    pub const IA32_TSC_ADJUST = 0x0000003b;
    pub const IA32_BNDCFGS = 0x00000d90;
};

pub const vt_msrs = struct {
    pub const IA32_VMX_BASIC = 0x00000480;
    pub const IA32_VMX_PINBASED_CTLS = 0x00000481;
    pub const IA32_VMX_PROCBASED_CTLS = 0x00000482;
    pub const IA32_VMX_EXIT_CTLS = 0x00000483;
    pub const IA32_VMX_ENTRY_CTLS = 0x00000484;
    pub const IA32_VMX_MISC = 0x00000485;
    pub const IA32_VMX_CR0_FIXED0 = 0x00000486;
    pub const IA32_VMX_CR0_FIXED1 = 0x00000487;
    pub const IA32_VMX_CR4_FIXED0 = 0x00000488;
    pub const IA32_VMX_CR4_FIXED1 = 0x00000489;
    pub const IA32_VMX_VMCS_ENUM = 0x0000048a;
    pub const IA32_VMX_PROCBASED_CTLS2 = 0x0000048b;
    pub const IA32_VMX_EPT_VPID_CAP = 0x0000048c;
    pub const IA32_VMX_TRUE_PINBASED_CTLS = 0x0000048d;
    pub const IA32_VMX_TRUE_PROCBASED_CTLS = 0x0000048e;
    pub const IA32_VMX_TRUE_EXIT_CTLS = 0x0000048f;
    pub const IA32_VMX_TRUE_ENTRY_CTLS = 0x00000490;
    pub const IA32_VMX_VMFUNC = 0x00000491;
};

pub const IA32_FEATURE_CONTROL = packed struct(u64) {
    /// Once set, the register is read-only until power cycle.
    lock: u1,
    /// Enables VMXON in SMX operation.
    enable_smx: u1,
    /// Enables VMXON outside SMX operation (Standard VT-x).
    enable_vmxon: u1,
    reserved1: u5,
    /// Bits 8-14: SENTER local function parameter control options.
    senter_parameter_controls: u7,
    /// SENTER global enable bit.
    senter_global_enable: u1,
    reserved2: u1,
    /// SGX Launch Control Enable.
    sgx_launch_control: u1,
    reserved3: u2,
    /// Local Machine Check Exception (LMCE) Enable.
    lmce_on: u1,
    reserved4: u43,
};
