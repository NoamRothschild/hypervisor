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

    var fc_msr: msr.IA32_FEATURE_CONTROL = @bitCast(rdmsr(.IA32_FEATURE_CONTROL));
    if (fc_msr.lock == 0) {
        fc_msr.lock = 1;
        fc_msr.enable_vmxon = 1;
        wrmsr(.IA32_FEATURE_CONTROL, @bitCast(fc_msr));
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

    const cr0_fixed0 = rdmsr(.IA32_VMX_CR0_FIXED0);
    const cr0_fixed1 = rdmsr(.IA32_VMX_CR0_FIXED1);
    const cr4_fixed0 = rdmsr(.IA32_VMX_CR4_FIXED0);
    const cr4_fixed1 = rdmsr(.IA32_VMX_CR4_FIXED1);

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
    vmm_stack: *align(1) []u8,
    vmm_stack_size: usize,
    /// msr bitmap virt addr
    msr_bitmap: *[4096]u8,
    /// msr bitmap phys addr
    msr_bitmap_phys: u64,
    /// holds the host virt address of the page allocated to the guest
    /// NOTE: VMState is special for every CPU for every host. This field is shared between all cpus for the same guest
    guest_mem_addr: u64 = 0,
};

/// Prepares the VMXON region and executes VMXON.
pub fn allocVmxonRegion(guest_state: *VMState) !void {
    const vmxon_page = try paging.alloc4KAligned();
    const vmxon_virt = @intFromPtr(vmxon_page);
    const vmxon_region_phys = paging.physAddr(vmxon_virt) orelse return error.vmxon_region_not_mapped;

    std.log.info("virtual buff addr for VMXON at 0x{x}\n", .{vmxon_virt});
    std.log.info("physical buff addr for VMXON at 0x{x}\n", .{vmxon_region_phys});

    @memset(vmxon_page, 0);

    const basic = rdmsr(.IA32_VMX_BASIC);
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
    const ret = asm volatile ("call __vmlaunch"
        : [ret] "={al}" (-> u8),
        :
        : .{
          .rcx = true,
          .rdx = true,
          .rsi = true,
          .rdi = true,
          .r8 = true,
          .r9 = true,
          .r10 = true,
          .r11 = true,
          .memory = true,
        });
    return ret != 0;
}

export var old_rbp: u64 = 0;
export var old_rsp: u64 = 0;

export fn __vmlaunch() callconv(.naked) void {
    asm volatile (
        \\ push %rbp
        \\ mov %rsp, %rbp
        \\ mov %rbp, old_rbp(%rip)
        \\ mov %rsp, old_rsp(%rip)
        \\
        \\ vmlaunch
        \\
        \\ call __vmlaunchFailed
        \\ mov $0, %rax
        \\ pop %rbp
        \\ ret
        ::: .{ .rax = true, .memory = true });
}

export fn __vmlaunchFailed() callconv(.c) void {
    std.log.err("vmlaunch failed with error code: {d}\n", .{vmerr()});
}

/// Return to the `call __vmlaunch` site after a handled VM-exit.
/// must be naked and entered with `jmp` (not `call`) so there is no C prologue.
export fn __vmReturnSucceed() callconv(.naked) void {
    asm volatile (
        \\ mov old_rbp(%rip), %rbp
        \\ mov old_rsp(%rip), %rsp
        \\ mov $1, %rax
        \\ pop %rbp
        \\ ret
        ::: .{ .rax = true, .rbp = true, .rsp = true });
}

pub fn vmExitHandler() callconv(.naked) void {
    asm volatile (
        \\ push %r15
        \\ push %r14
        \\ push %r13
        \\ push %r12
        \\ push %r11
        \\ push %r10
        \\ push %r9
        \\ push %r8
        \\ push %rdi
        \\ push %rsi
        \\ push %rbp
        \\ push %rbp
        \\ push %rbx
        \\ push %rdx
        \\ push %rcx
        \\ push %rax
        \\
        \\ mov %rsp, %rcx
        \\ sub $0x28, %rsp
        \\ call mainVmExitHandler
        \\ add $0x28, %rsp
        \\
        \\ // al=1 => stop and return to kmain; al=0 => resume guest
        \\ test %al, %al
        \\ jnz __vmReturnSucceed
        \\
        \\ pop %rcx
        \\ pop %rdx
        \\ pop %rbx
        \\ pop %rbp
        \\ pop %rbp
        \\ pop %rsi
        \\ pop %rdi
        \\ pop %r8
        \\ pop %r9
        \\ pop %r10
        \\ pop %r11
        \\ pop %r12
        \\ pop %r13
        \\ pop %r14
        \\ pop %r15
        \\
        \\ call resumeToNextInstruction
        \\ vmresume
        \\
        \\ call vmResumeInstructionFailed
    );
}

/// Returns true when the VMM should leave the guest and return to kmain.
export fn mainVmExitHandler(guest_regs: *CpuState) callconv(.c) bool {
    const exit_reason: ExitReason = @enumFromInt(vmread(.VM_EXIT_REASON) & 0xffff);
    const exit_qualification = vmread(.EXIT_QUALIFICATION);
    _ = guest_regs;

    debug.printf("VM EXIT REASON: {s}\n", .{@tagName(exit_reason)});
    debug.printf("EXIT QUALIFICATION: 0x{x}\n", .{exit_qualification});

    switch (exit_reason) {
        .vmclear,
        .vmptrld,
        .vmptrst,
        .vmread,
        .vmresume,
        .vmwrite,
        .vmxoff,
        .vmxon,
        .vmlaunch,
        => {},

        .hlt => {
            std.log.info("user executed hlt\n", .{});
            return true;
        },
        .invalid_guest_state => {
            std.log.err("invalid guest state; not resuming\n", .{});
            return true;
        },
        else => return false,
    }
    return false;
}

export fn resumeToNextInstruction() callconv(.c) void {
    const current_rip = vmread(.GUEST_RIP);
    const exit_instr_len = vmread(.VM_EXIT_INSTRUCTION_LEN);
    vmwrite(.GUEST_RIP, current_rip +% exit_instr_len);
}

export fn vmResumeInstructionFailed() callconv(.c) noreturn {
    std.log.err("vmresume failed with error code: {d}\n", .{vmerr()});

    while (true)
        asm volatile ("hlt");
}

/// reads the instruction error field to get the error code
pub fn vmerr() u64 {
    return vmread(.VM_INSTRUCTION_ERROR);
}

pub fn vmread(field: SelectorField) u64 {
    var ret: u64 = 0;
    asm volatile ("vmread %[field], %[ret]"
        : [ret] "=rm" (ret),
        : [field] "r" (@intFromEnum(field)),
    );
    return ret;
}

/// calls vmwrite for the given selector with the given value
pub inline fn vmwrite(selector: SelectorField, value: u64) void {
    asm volatile ("vmwrite %rbx, %rax"
        :
        : [value] "{rbx}" (value),
          [selector] "{rax}" (@intFromEnum(selector)),
        : .{ .rbx = true, .rax = true });
}

pub const CpuState = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,
};

pub const ExitReason = enum(u64) {
    exception_nmi = 0,
    external_interrupt = 1,
    triple_fault = 2,
    init = 3,
    sipi = 4,
    io_smi = 5,
    other_smi = 6,
    pending_virt_intr = 7,
    pending_virt_nmi = 8,
    task_switch = 9,
    cpuid = 10,
    getsec = 11,
    hlt = 12,
    invd = 13,
    invlpg = 14,
    rdpmc = 15,
    rdtsc = 16,
    rsm = 17,
    vmcall = 18,
    vmclear = 19,
    vmlaunch = 20,
    vmptrld = 21,
    vmptrst = 22,
    vmread = 23,
    vmresume = 24,
    vmwrite = 25,
    vmxoff = 26,
    vmxon = 27,
    cr_access = 28,
    dr_access = 29,
    io_instruction = 30,
    msr_read = 31,
    msr_write = 32,
    invalid_guest_state = 33,
    msr_loading = 34,
    mwait_instruction = 36,
    monitor_trap_flag = 37,
    monitor_instruction = 39,
    pause_instruction = 40,
    mce_during_vmentry = 41,
    tpr_below_threshold = 43,
    apic_access = 44,
    access_gdtr_or_idtr = 46,
    access_ldtr_or_tr = 47,
    ept_violation = 48,
    ept_misconfig = 49,
    invept = 50,
    rdtscp = 51,
    vmx_preemption_timer_expired = 52,
    invvpid = 53,
    wbinvd = 54,
    xsetbv = 55,
    apic_write = 56,
    rdrand = 57,
    invpcid = 58,
    rdseed = 61,
    pml_full = 62,
    xsaves = 63,
    xrstors = 64,
    pcommit = 65,
};

pub const SelectorField = enum(u64) {
    GUEST_ES_SELECTOR = 0x00000800,
    GUEST_CS_SELECTOR = 0x00000802,
    GUEST_SS_SELECTOR = 0x00000804,
    GUEST_DS_SELECTOR = 0x00000806,
    GUEST_FS_SELECTOR = 0x00000808,
    GUEST_GS_SELECTOR = 0x0000080a,
    GUEST_LDTR_SELECTOR = 0x0000080c,
    GUEST_TR_SELECTOR = 0x0000080e,
    HOST_ES_SELECTOR = 0x00000c00,
    HOST_CS_SELECTOR = 0x00000c02,
    HOST_SS_SELECTOR = 0x00000c04,
    HOST_DS_SELECTOR = 0x00000c06,
    HOST_FS_SELECTOR = 0x00000c08,
    HOST_GS_SELECTOR = 0x00000c0a,
    HOST_TR_SELECTOR = 0x00000c0c,
    IO_BITMAP_A = 0x00002000,
    IO_BITMAP_A_HIGH = 0x00002001,
    IO_BITMAP_B = 0x00002002,
    IO_BITMAP_B_HIGH = 0x00002003,
    MSR_BITMAP = 0x00002004,
    MSR_BITMAP_HIGH = 0x00002005,
    VM_EXIT_MSR_STORE_ADDR = 0x00002006,
    VM_EXIT_MSR_STORE_ADDR_HIGH = 0x00002007,
    VM_EXIT_MSR_LOAD_ADDR = 0x00002008,
    VM_EXIT_MSR_LOAD_ADDR_HIGH = 0x00002009,
    VM_ENTRY_MSR_LOAD_ADDR = 0x0000200a,
    VM_ENTRY_MSR_LOAD_ADDR_HIGH = 0x0000200b,
    TSC_OFFSET = 0x00002010,
    TSC_OFFSET_HIGH = 0x00002011,
    VIRTUAL_APIC_PAGE_ADDR = 0x00002012,
    VIRTUAL_APIC_PAGE_ADDR_HIGH = 0x00002013,
    VMFUNC_CONTROLS = 0x00002018,
    VMFUNC_CONTROLS_HIGH = 0x00002019,
    EPT_POINTER = 0x0000201A,
    EPT_POINTER_HIGH = 0x0000201B,
    EPTP_LIST = 0x00002024,
    EPTP_LIST_HIGH = 0x00002025,
    GUEST_PHYSICAL_ADDRESS = 0x2400,
    GUEST_PHYSICAL_ADDRESS_HIGH = 0x2401,
    VMCS_LINK_POINTER = 0x00002800,
    VMCS_LINK_POINTER_HIGH = 0x00002801,
    GUEST_IA32_DEBUGCTL = 0x00002802,
    GUEST_IA32_DEBUGCTL_HIGH = 0x00002803,
    PIN_BASED_VM_EXEC_CONTROL = 0x00004000,
    CPU_BASED_VM_EXEC_CONTROL = 0x00004002,
    EXCEPTION_BITMAP = 0x00004004,
    PAGE_FAULT_ERROR_CODE_MASK = 0x00004006,
    PAGE_FAULT_ERROR_CODE_MATCH = 0x00004008,
    CR3_TARGET_COUNT = 0x0000400a,
    VM_EXIT_CONTROLS = 0x0000400c,
    VM_EXIT_MSR_STORE_COUNT = 0x0000400e,
    VM_EXIT_MSR_LOAD_COUNT = 0x00004010,
    VM_ENTRY_CONTROLS = 0x00004012,
    VM_ENTRY_MSR_LOAD_COUNT = 0x00004014,
    VM_ENTRY_INTR_INFO_FIELD = 0x00004016,
    VM_ENTRY_EXCEPTION_ERROR_CODE = 0x00004018,
    VM_ENTRY_INSTRUCTION_LEN = 0x0000401a,
    TPR_THRESHOLD = 0x0000401c,
    SECONDARY_VM_EXEC_CONTROL = 0x0000401e,
    VM_INSTRUCTION_ERROR = 0x00004400,
    VM_EXIT_REASON = 0x00004402,
    VM_EXIT_INTR_INFO = 0x00004404,
    VM_EXIT_INTR_ERROR_CODE = 0x00004406,
    IDT_VECTORING_INFO_FIELD = 0x00004408,
    IDT_VECTORING_ERROR_CODE = 0x0000440a,
    VM_EXIT_INSTRUCTION_LEN = 0x0000440c,
    VMX_INSTRUCTION_INFO = 0x0000440e,
    GUEST_ES_LIMIT = 0x00004800,
    GUEST_CS_LIMIT = 0x00004802,
    GUEST_SS_LIMIT = 0x00004804,
    GUEST_DS_LIMIT = 0x00004806,
    GUEST_FS_LIMIT = 0x00004808,
    GUEST_GS_LIMIT = 0x0000480a,
    GUEST_LDTR_LIMIT = 0x0000480c,
    GUEST_TR_LIMIT = 0x0000480e,
    GUEST_GDTR_LIMIT = 0x00004810,
    GUEST_IDTR_LIMIT = 0x00004812,
    GUEST_ES_AR_BYTES = 0x00004814,
    GUEST_CS_AR_BYTES = 0x00004816,
    GUEST_SS_AR_BYTES = 0x00004818,
    GUEST_DS_AR_BYTES = 0x0000481a,
    GUEST_FS_AR_BYTES = 0x0000481c,
    GUEST_GS_AR_BYTES = 0x0000481e,
    GUEST_LDTR_AR_BYTES = 0x00004820,
    GUEST_TR_AR_BYTES = 0x00004822,
    GUEST_INTERRUPTIBILITY_INFO = 0x00004824,
    GUEST_ACTIVITY_STATE = 0x00004826,
    GUEST_SM_BASE = 0x00004828,
    GUEST_SYSENTER_CS = 0x0000482A,
    HOST_IA32_SYSENTER_CS = 0x00004c00,
    CR0_GUEST_HOST_MASK = 0x00006000,
    CR4_GUEST_HOST_MASK = 0x00006002,
    CR0_READ_SHADOW = 0x00006004,
    CR4_READ_SHADOW = 0x00006006,
    CR3_TARGET_VALUE0 = 0x00006008,
    CR3_TARGET_VALUE1 = 0x0000600a,
    CR3_TARGET_VALUE2 = 0x0000600c,
    CR3_TARGET_VALUE3 = 0x0000600e,
    EXIT_QUALIFICATION = 0x00006400,
    GUEST_LINEAR_ADDRESS = 0x0000640a,
    GUEST_CR0 = 0x00006800,
    GUEST_CR3 = 0x00006802,
    GUEST_CR4 = 0x00006804,
    GUEST_ES_BASE = 0x00006806,
    GUEST_CS_BASE = 0x00006808,
    GUEST_SS_BASE = 0x0000680a,
    GUEST_DS_BASE = 0x0000680c,
    GUEST_FS_BASE = 0x0000680e,
    GUEST_GS_BASE = 0x00006810,
    GUEST_LDTR_BASE = 0x00006812,
    GUEST_TR_BASE = 0x00006814,
    GUEST_GDTR_BASE = 0x00006816,
    GUEST_IDTR_BASE = 0x00006818,
    GUEST_DR7 = 0x0000681a,
    GUEST_RSP = 0x0000681c,
    GUEST_RIP = 0x0000681e,
    GUEST_RFLAGS = 0x00006820,
    GUEST_PENDING_DBG_EXCEPTIONS = 0x00006822,
    GUEST_SYSENTER_ESP = 0x00006824,
    GUEST_SYSENTER_EIP = 0x00006826,
    HOST_CR0 = 0x00006c00,
    HOST_CR3 = 0x00006c02,
    HOST_CR4 = 0x00006c04,
    HOST_FS_BASE = 0x00006c06,
    HOST_GS_BASE = 0x00006c08,
    HOST_TR_BASE = 0x00006c0a,
    HOST_GDTR_BASE = 0x00006c0c,
    HOST_IDTR_BASE = 0x00006c0e,
    HOST_IA32_SYSENTER_ESP = 0x00006c10,
    HOST_IA32_SYSENTER_EIP = 0x00006c12,
    HOST_RSP = 0x00006c14,
    HOST_RIP = 0x00006c16,
};
