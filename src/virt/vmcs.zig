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
const vmwrite = vmx.vmwrite;

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

    // Bit 10 of DR7 is reserved and must be 1.
    vmwrite(.GUEST_DR7, 0x400);

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
    vmwrite(.HOST_RIP, @intFromPtr(&vmx.vmExitHandler));
}

/// calls vmwrite for the given selector with the given value
/// example usage:
///
/// vmwrite("mov $1, %rbx", my_selector);
/// ^^ will call `vmwrite my_selector, 1`
///
/// the result of the assembly expression should be stored in rbx.
inline fn vmwriteAsm(selector: vmx.SelectorField, value_instr: []const u8) void {
    asm volatile (std.fmt.comptimePrint(
            \\ {s}
            \\ mov $0x{x}, %rax
            \\ vmwrite %rbx, %rax
        , .{ value_instr, @intFromEnum(selector) }) ::: .{ .rbx = true, .rax = true });
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
        (@as(u32, (attr >> 8) & 0xf0) << 8);

    if (selector == 0)
        access_rights |= 0x10000;

    const offset = @intFromEnum(seg_reg) * 2;
    const oS = offsetSelector;
    vmwrite(oS(.GUEST_ES_SELECTOR, offset), selector);
    vmwrite(oS(.GUEST_ES_LIMIT, offset), segment_selector.limit());
    vmwrite(oS(.GUEST_ES_AR_BYTES, offset), access_rights);
    vmwrite(oS(.GUEST_ES_BASE, offset), segment_selector.base());
}

fn offsetSelector(base: vmx.SelectorField, offset: u64) vmx.SelectorField {
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
