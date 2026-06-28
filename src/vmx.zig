const std = @import("std");
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

/// enables VMXE (bit 13 of cr4)
pub fn enableOperation() void {
    asm volatile (
        \\ xor %rax, %rax
        \\ mov %cr4, %rax
        \\ or $0x2000, %rax
        \\ mov %rax, %cr4
        ::: .{ .rax = true });
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
