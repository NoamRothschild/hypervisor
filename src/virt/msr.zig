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
