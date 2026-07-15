const std = @import("std");
const vmx = @import("vmx.zig");
const msr = @import("msr.zig");
const debug = @import("../debug.zig");
const paging = @import("../arch/x86_64/paging.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const idt = @import("../arch/x86_64/idt.zig");
const VMState = vmx.VMState;
const rdmsr = msr.rdmsr;
const wrmsr = msr.wrmsr;

/// Prepares the VMCS region and executes VMPTRLD.
pub fn allocRegion(guest_state: *VMState) !void {
    const vmcs_page = try paging.alloc4KAligned();
    const vmcs_virt = @intFromPtr(vmcs_page);
    const vmcs_region_phys = paging.physAddr(vmcs_virt) orelse return error.vmcs_region_not_mapped;

    std.log.info("virtual buff addr for VMCS at 0x{x}\n", .{vmcs_virt});
    std.log.info("physical buff addr for VMCS at 0x{x}\n", .{vmcs_region_phys});

    @memset(vmcs_page, 0);

    const basic = rdmsr(.IA32_VMX_BASIC);
    const revision_identifier: u32 = @truncate(basic);
    std.log.info("IA32_VMX_BASIC revision identifier: 0x{x}\n", .{revision_identifier});

    @as(*volatile u32, @ptrCast(vmcs_page)).* = revision_identifier;

    guest_state.vmcs_region = vmcs_region_phys;
    if (!load(guest_state))
        return error.vmptrload_failed;
}

/// FIXME: I didn't test it acutally works.
///
/// calls vmclear with the vmxon ptr.
///  returns if failed or succeeded
pub fn clear(vmstate: *VMState) bool {
    var cf: u8 = undefined;
    var zf: u8 = undefined;

    asm volatile (
        \\ vmclear (%[vmcs_phys_ptr])
        \\ setc %[cf]
        \\ setz %[zf]
        : [cf] "=qm" (cf),
          [zf] "=qm" (zf),
        : [vmcs_phys_ptr] "r" (&vmstate.*.vmcs_region),
    );

    var failed = false;
    if (cf != 0) {
        std.log.err("vmclear failed (cf=1)\n", .{});
        failed = true;
    }

    if (zf != 0) {
        std.log.err("vmclear failiure error code: {d}\n", .{vmx.vmerr()});
        failed = true;
    }

    return !failed;
}

/// sets the current VMCS to vmstate.vmcs_region
pub fn load(vmstate: *VMState) bool {
    var cf: u8 = undefined;
    var zf: u8 = undefined;

    asm volatile (
        \\ vmptrld (%[vmcs_phys_ptr])
        \\ setc %[cf]
        \\ setz %[zf]
        : [cf] "=qm" (cf),
          [zf] "=qm" (zf),
        : [vmcs_phys_ptr] "r" (&vmstate.vmcs_region),
    );

    if ((cf != 0) or (zf != 0)) {
        std.log.err("vmptrld failed with {s} (zf={d})\n", .{ if (zf == 0) "VMFailInvalid" else "VMFailValid", @intFromBool(zf != 0) });
        if (zf != 0) {
            debug.printf("vmptrld failiure error code: {d}\n", .{vmx.vmerr()});
        }
        return false;
    }
    return true;
}

pub fn setup(vmstate: *VMState) !void {
    vmwriteAsm(.HOST_ES_SELECTOR,
        \\ mov %es, %rbx
        \\ and $0xf8, %rbx
    );
    vmwriteAsm(.HOST_CS_SELECTOR,
        \\ mov %cs, %rbx
        \\ and $0xf8, %rbx
    );
    vmwriteAsm(.HOST_SS_SELECTOR,
        \\ mov %ss, %rbx
        \\ and $0xf8, %rbx
    );
    vmwriteAsm(.HOST_DS_SELECTOR,
        \\ mov %ds, %rbx
        \\ and $0xf8, %rbx
    );
    vmwriteAsm(.HOST_FS_SELECTOR,
        \\ mov %fs, %rbx
        \\ and $0xf8, %rbx
    );
    vmwriteAsm(.HOST_GS_SELECTOR,
        \\ mov %gs, %rbx
        \\ and $0xf8, %rbx
    );
    vmwriteAsm(.HOST_TR_SELECTOR,
        \\ str %rbx
        \\ and $0xf8, %rbx
    );
    vmwrite(.VMCS_LINK_POINTER, @bitCast(@as(i64, -1)));

    const debug_msr = rdmsr(.IA32_DEBUGCTLMSR);
    vmwrite(.GUEST_IA32_DEBUGCTL, @as(u32, @truncate(debug_msr)));
    vmwrite(.GUEST_IA32_DEBUGCTL_HIGH, debug_msr >> 32);

    // time stamp counter offset
    vmwrite(.TSC_OFFSET, 0);
    vmwrite(.TSC_OFFSET_HIGH, 0);

    vmwrite(.PAGE_FAULT_ERROR_CODE_MASK, 0);
    vmwrite(.PAGE_FAULT_ERROR_CODE_MASK, 0);

    vmwrite(.VM_EXIT_MSR_STORE_COUNT, 0);
    vmwrite(.VM_EXIT_MSR_LOAD_COUNT, 0);

    vmwrite(.VM_ENTRY_MSR_LOAD_COUNT, 0);
    vmwrite(.VM_ENTRY_INTR_INFO_FIELD, 0);

    const gdt_info = gdt.gdtInfo();
    inline for (std.enums.values(SegReg)) |seg_reg| {
        if (seg_reg == .ldtr or seg_reg == .tr) continue;
        var selector: u64 = 0;
        asm volatile ("mov %" ++ @tagName(seg_reg) ++ ", %rbx"
            : [ret] "={rbx}" (selector),
            :
            : .{ .rbx = true });

        fillGuestSelectorData(gdt_info.base, seg_reg, @truncate(selector));
    }
    fillGuestSelectorData(gdt_info.base, .ldtr, getLdtr());
    fillGuestSelectorData(gdt_info.base, .tr, getTr());

    vmwrite(.GUEST_FS_BASE, rdmsr(.FS_BASE));
    vmwrite(.GUEST_GS_BASE, rdmsr(.GS_BASE));
    vmwrite(.GUEST_INTERRUPTIBILITY_INFO, 0);
    vmwrite(.GUEST_ACTIVITY_STATE, 0);

    vmwrite(.CPU_BASED_VM_EXEC_CONTROL, adjustControls(
        VmExecutionControl,
        &[_]VmExecutionControl{
            .CPU_BASED_HLT_EXITING,
            .CPU_BASED_ACTIVATE_SECONDARY_CONTROLS,
        },
        .IA32_VMX_PROCBASED_CTLS,
    ));

    vmwrite(.SECONDARY_VM_EXEC_CONTROL, adjustControls(
        SecondaryVmExecutionControl,
        &[_]SecondaryVmExecutionControl{
            .CPU_BASED_CTL2_RDTSCP,
            // .CPU_BASED_CTL2_ENABLE_EPT, // for dealing with ept
        },
        .IA32_VMX_PROCBASED_CTLS2,
    ));

    vmwrite(.PIN_BASED_VM_EXEC_CONTROL, adjustControls(u64, &[_]u64{}, .IA32_VMX_PINBASED_CTLS));
    vmwrite(.VM_EXIT_CONTROLS, adjustControls(
        VmExitControl,
        &[_]VmExitControl{
            .VM_EXIT_IA32E_MODE, .VM_EXIT_ACK_INTR_ON_EXIT,
        },
        .IA32_VMX_EXIT_CTLS,
    ));

    vmwrite(.VM_ENTRY_CONTROLS, adjustControls(
        VmEntryControl,
        &[_]VmEntryControl{
            .VM_ENTRY_IA32E_MODE,
        },
        .IA32_VMX_ENTRY_CTLS,
    ));

    vmwriteAsm(.GUEST_CR0, "mov %cr0, %rbx");
    vmwriteAsm(.GUEST_CR3, "mov %cr3, %rbx");
    vmwriteAsm(.GUEST_CR4, "mov %cr4, %rbx");

    vmwriteAsm(.HOST_CR0, "mov %cr0, %rbx");
    vmwriteAsm(.HOST_CR3, "mov %cr3, %rbx");
    vmwriteAsm(.HOST_CR4, "mov %cr4, %rbx");

    // FIXME: it’s not a good idea to use the same IDT (and GDT) for the guest and host
    // poc: https://github.com/SinaKarvandi/Misc/tree/master/HypervisorBypassWithNMI
    vmwrite(.GUEST_GDTR_BASE, gdt_info.base);
    vmwrite(.GUEST_GDTR_LIMIT, gdt_info.limit);
    vmwrite(.GUEST_IDTR_BASE, idt.idt_descriptor.base);
    vmwrite(.GUEST_IDTR_LIMIT, idt.idt_descriptor.limit);

    vmwrite(.HOST_TR_BASE, gdt.getSegmentDescriptor(getTr(), gdt_info.base).base());

    vmwrite(.HOST_FS_BASE, rdmsr(.FS_BASE));
    vmwrite(.HOST_GS_BASE, rdmsr(.GS_BASE));

    vmwrite(.HOST_IDTR_BASE, idt.idt_descriptor.base);
    vmwrite(.HOST_GDTR_BASE, gdt_info.base);

    vmwriteAsm(.GUEST_RFLAGS, "pushfq; pop %rbx");

    vmwrite(.GUEST_SYSENTER_CS, rdmsr(.IA32_SYSENTER_CS));
    vmwrite(.GUEST_SYSENTER_EIP, rdmsr(.IA32_SYSENTER_EIP));
    vmwrite(.GUEST_SYSENTER_ESP, rdmsr(.IA32_SYSENTER_ESP));

    vmwrite(.HOST_IA32_SYSENTER_CS, rdmsr(.IA32_SYSENTER_CS));
    vmwrite(.HOST_IA32_SYSENTER_EIP, rdmsr(.IA32_SYSENTER_EIP));
    vmwrite(.HOST_IA32_SYSENTER_ESP, rdmsr(.IA32_SYSENTER_ESP));

    vmwrite(.GUEST_RSP, vmstate.guest_mem_addr);
    vmwrite(.GUEST_RIP, vmstate.guest_mem_addr);

    vmwrite(.HOST_RSP, @as(u64, @intFromPtr(vmstate.vmm_stack)) +% vmstate.vmm_stack.len -% 1);
    const VMExitHandler: *u64 = @ptrFromInt(0xffff0000);
    // FIXME: ^^ temporary
    vmwrite(.HOST_RIP, @intFromPtr(VMExitHandler));
}

/// calls vmwrite for the given selector with the given value
/// example usage:
///
/// vmwrite("mov $1, %rbx", my_selector);
/// ^^ will call `vmwrite my_selector, 1`
///
/// the result of the assembly expression should be stored in rbx.
inline fn vmwriteAsm(selector: SelectorField, value_instr: []const u8) void {
    asm volatile (std.fmt.comptimePrint(
            \\ {s}
            \\ mov $0x{x}, %rax
            \\ vmwrite %rbx, %rax
        , .{ value_instr, @intFromEnum(selector) }) ::: .{ .rbx = true, .rax = true });
}

/// calls vmwrite for the given selector with the given value
inline fn vmwrite(selector: SelectorField, value: u64) void {
    asm volatile ("vmwrite %rbx, %rax"
        :
        : [value] "{rbx}" (value),
          [selector] "{rax}" (@intFromEnum(selector)),
        : .{ .rbx = true, .rax = true });
}

fn adjustControls(comptime T: type, ctrls: []const T, by_msr: msr.All) u64 {
    var all_ctrl: u64 = 0;
    for (ctrls) |ctrl|
        all_ctrl |= if (@typeInfo(T) == .@"enum") @intFromEnum(ctrl) else ctrl;
    const msr_val = rdmsr(by_msr);
    const msr_low: u32 = @truncate(msr_val);
    const msr_high: u32 = @truncate(msr_val >> 32);

    all_ctrl &= msr_high;
    all_ctrl |= msr_low;
    return all_ctrl;
}

fn fillGuestSelectorData(gdt_base: u64, seg_reg: SegReg, selector: u16) void {
    const segment_selector = gdt.getSegmentDescriptor(selector, gdt_base);
    const attr = segment_selector.attributes;
    var access_rights: u32 =
        @as(u32, attr & 0xff) |
        (@as(u32, attr >> 8) << 12);

    if (selector == 0)
        access_rights |= 0x10000;

    const offset = @intFromEnum(seg_reg) * 2;
    const oS = offsetSelector;
    vmwrite(oS(.GUEST_ES_SELECTOR, offset), selector);
    vmwrite(oS(.GUEST_ES_LIMIT, offset), segment_selector.limit());
    vmwrite(oS(.GUEST_ES_AR_BYTES, offset), access_rights);
    vmwrite(oS(.GUEST_ES_BASE, offset), segment_selector.base());
}

fn offsetSelector(base: SelectorField, offset: u64) SelectorField {
    return @enumFromInt(@intFromEnum(base) + offset);
}

const SegReg = enum(u64) {
    es = 0,
    cs = 1,
    ss = 2,
    ds = 3,
    fs = 4,
    gs = 5,
    ldtr = 6,
    tr = 7,
};

fn getLdtr() u16 {
    var ldtr: u64 = 0;
    asm volatile ("sldt %rax"
        : [ret] "={rax}" (ldtr),
    );
    return @truncate(ldtr);
}

fn getTr() u16 {
    var tr: u64 = 0;
    asm volatile ("str %rax"
        : [ret] "={rax}" (tr),
    );
    return @truncate(tr);
}

const SelectorField = enum(u64) {
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

pub const VmExecutionControl = enum(u32) {
    CPU_BASED_VIRTUAL_INTR_PENDING = 0x00000004,
    CPU_BASED_USE_TSC_OFFSETING = 0x00000008,
    CPU_BASED_HLT_EXITING = 0x00000080,
    CPU_BASED_INVLPG_EXITING = 0x00000200,
    CPU_BASED_MWAIT_EXITING = 0x00000400,
    CPU_BASED_RDPMC_EXITING = 0x00000800,
    CPU_BASED_RDTSC_EXITING = 0x00001000,
    CPU_BASED_CR3_LOAD_EXITING = 0x00008000,
    CPU_BASED_CR3_STORE_EXITING = 0x00010000,
    CPU_BASED_CR8_LOAD_EXITING = 0x00080000,
    CPU_BASED_CR8_STORE_EXITING = 0x00100000,
    CPU_BASED_TPR_SHADOW = 0x00200000,
    CPU_BASED_VIRTUAL_NMI_PENDING = 0x00400000,
    CPU_BASED_MOV_DR_EXITING = 0x00800000,
    CPU_BASED_UNCOND_IO_EXITING = 0x01000000,
    CPU_BASED_ACTIVATE_IO_BITMAP = 0x02000000,
    CPU_BASED_MONITOR_TRAP_FLAG = 0x08000000,
    CPU_BASED_ACTIVATE_MSR_BITMAP = 0x10000000,
    CPU_BASED_MONITOR_EXITING = 0x20000000,
    CPU_BASED_PAUSE_EXITING = 0x40000000,
    CPU_BASED_ACTIVATE_SECONDARY_CONTROLS = 0x80000000,
};

pub const SecondaryVmExecutionControl = enum(u32) {
    CPU_BASED_CTL2_ENABLE_EPT = 0x2,
    CPU_BASED_CTL2_RDTSCP = 0x8,
    CPU_BASED_CTL2_ENABLE_VPID = 0x20,
    CPU_BASED_CTL2_UNRESTRICTED_GUEST = 0x80,
    CPU_BASED_CTL2_ENABLE_VMFUNC = 0x2000,
};

pub const VmEntryControl = enum(u32) {
    VM_ENTRY_IA32E_MODE = 0x00000200,
    VM_ENTRY_SMM = 0x00000400,
    VM_ENTRY_DEACT_DUAL_MONITOR = 0x00000800,
    VM_ENTRY_LOAD_GUEST_PAT = 0x00004000,
};

pub const VmExitControl = enum(u32) {
    VM_EXIT_IA32E_MODE = 0x00000200,
    VM_EXIT_ACK_INTR_ON_EXIT = 0x00008000,
    VM_EXIT_SAVE_GUEST_PAT = 0x00040000,
    VM_EXIT_LOAD_HOST_PAT = 0x00080000,
};
