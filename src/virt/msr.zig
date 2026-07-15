pub inline fn rdmsr(msr_id: All) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (@intFromEnum(msr_id)),
    );
    return (@as(u64, high) << 32) | low;
}

pub inline fn wrmsr(msr_id: All, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);

    asm volatile ("wrmsr"
        :
        : [low] "{eax}" (low),
          [high] "{edx}" (high),
          [msr] "{ecx}" (@intFromEnum(msr_id)),
        : .{ .memory = true });
}

/// Intel defined MSRs.
/// source: https://elixir.bootlin.com/linux/v4.2/source/arch/x86/include/asm/msr-index.h#L375
pub const All = enum(u32) {
    IA32_P5_MC_ADDR = 0x00000000,
    IA32_P5_MC_TYPE = 0x00000001,
    IA32_TSC = 0x00000010,
    IA32_PLATFORM_ID = 0x00000017,
    IA32_EBL_CR_POWERON = 0x0000002a,
    EBC_FREQUENCY_ID = 0x0000002c,
    SMI_COUNT = 0x00000034,
    IA32_FEATURE_CONTROL = 0x0000003a,
    IA32_TSC_ADJUST = 0x0000003b,
    IA32_BNDCFGS = 0x00000d90,
    IA32_DEBUGCTLMSR = 0x000001d9,
    IA32_LASTBRANCHFROMIP = 0x000001db,
    IA32_LASTBRANCHTOIP = 0x000001dc,
    IA32_LASTINTFROMIP = 0x000001dd,
    IA32_LASTINTTOIP = 0x000001de,
    IA32_VMX_BASIC = 0x00000480,
    IA32_VMX_PINBASED_CTLS = 0x00000481,
    IA32_VMX_PROCBASED_CTLS = 0x00000482,
    IA32_VMX_EXIT_CTLS = 0x00000483,
    IA32_VMX_ENTRY_CTLS = 0x00000484,
    IA32_VMX_MISC = 0x00000485,
    IA32_VMX_CR0_FIXED0 = 0x00000486,
    IA32_VMX_CR0_FIXED1 = 0x00000487,
    IA32_VMX_CR4_FIXED0 = 0x00000488,
    IA32_VMX_CR4_FIXED1 = 0x00000489,
    IA32_VMX_VMCS_ENUM = 0x0000048a,
    IA32_VMX_PROCBASED_CTLS2 = 0x0000048b,
    IA32_VMX_EPT_VPID_CAP = 0x0000048c,
    IA32_VMX_TRUE_PINBASED_CTLS = 0x0000048d,
    IA32_VMX_TRUE_PROCBASED_CTLS = 0x0000048e,
    IA32_VMX_TRUE_EXIT_CTLS = 0x0000048f,
    IA32_VMX_TRUE_ENTRY_CTLS = 0x00000490,
    IA32_VMX_VMFUNC = 0x00000491,
    EFER = 0xc0000080, // extended feature register
    STAR = 0xc0000081, // legacy mode SYSCALL target
    LSTAR = 0xc0000082, // long mode SYSCALL target
    CSTAR = 0xc0000083, // compat mode SYSCALL target
    SYSCALL_MASK = 0xc0000084, // EFLAGS mask for syscall
    FS_BASE = 0xc0000100, // 64bit FS base
    GS_BASE = 0xc0000101, // 64bit GS base
    KERNEL_GS_BASE = 0xc0000102, // SwapGS GS shadow
    TSC_AUX = 0xc0000103, // Auxiliary TSC
    IA32_SYSENTER_CS = 0x00000174,
    IA32_SYSENTER_ESP = 0x00000175,
    IA32_SYSENTER_EIP = 0x00000176,

    pub fn read(self: @This()) u64 {
        return rdmsr(self);
    }
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
