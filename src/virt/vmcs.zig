const std = @import("std");
const vmx = @import("vmx.zig");
const msr = @import("msr.zig");
const debug = @import("../debug.zig");
const hhdm = @import("../mem/hhdm.zig");
const mem_allocator = @import("../mem/allocator.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const idt = @import("../arch/x86_64/idt.zig");
const ept = @import("ept.zig");
const GuestAllocator = @import("../mem/guest_allocator.zig");
const VMState = vmx.VMState;
const rdmsr = msr.rdmsr;
const wrmsr = msr.wrmsr;
const vmwrite = vmx.vmwrite;

/// Prepares the VMCS region and executes VMPTRLD.
pub fn allocRegion(guest_state: *VMState) !void {
    const vmcs_page = try mem_allocator.kalloc.allocPage();
    const vmcs_virt = @intFromPtr(vmcs_page);
    const vmcs_region_phys = hhdm.physOf(vmcs_page);

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

pub fn setup(vmstate: *VMState, eptp: ept.EPTP) !void {
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

    // TEMPORARY: trap every exception so the first guest fault reports its
    // vector and RIP, instead of escalating through an empty guest IDT into an
    // opaque triple fault
    vmwrite(.EXCEPTION_BITMAP, 0xffff_ffff);

    vmwrite(.VM_EXIT_MSR_STORE_COUNT, 0);
    vmwrite(.VM_EXIT_MSR_LOAD_COUNT, 0);

    vmwrite(.VM_ENTRY_MSR_LOAD_COUNT, 0);
    vmwrite(.VM_ENTRY_INTR_INFO_FIELD, 0);

    const gdt_info = gdt.gdtInfo();

    setupGuestState32();

    vmwrite(.GUEST_INTERRUPTIBILITY_INFO, 0);
    vmwrite(.GUEST_ACTIVITY_STATE, 0);

    vmwrite(.CPU_BASED_VM_EXEC_CONTROL, try adjustControls(VmExecutionControl, .IA32_VMX_PROCBASED_CTLS, &.{
        .optional(.CPU_BASED_HLT_EXITING),
        .optional(.CPU_BASED_ACTIVATE_SECONDARY_CONTROLS),
        .optional(.CPU_BASED_ACTIVATE_MSR_BITMAP),
    }));

    vmwrite(.SECONDARY_VM_EXEC_CONTROL, try adjustControls(SecondaryVmExecutionControl, .IA32_VMX_PROCBASED_CTLS2, &.{
        .optional(.CPU_BASED_CTL2_RDTSCP),
        .required(.CPU_BASED_CTL2_ENABLE_EPT, error.EptUnsupported),
        // without this, IA32_VMX_CR0_FIXED0 forces guest CR0.PE and CR0.PG to 1, and
        // a guest entered with paging off (so it can build its own) cannot be launched
        .required(.CPU_BASED_CTL2_UNRESTRICTED_GUEST, error.UnrestrictedGuestUnsupported),
    }));
    vmwrite(.EPT_POINTER, @bitCast(eptp));

    vmwrite(.PIN_BASED_VM_EXEC_CONTROL, try adjustControls(u64, .IA32_VMX_PINBASED_CTLS, &.{}));

    vmwrite(.VM_EXIT_CONTROLS, try adjustControls(VmExitControl, .IA32_VMX_EXIT_CTLS, &.{
        .optional(.VM_EXIT_IA32E_MODE),
        .optional(.VM_EXIT_ACK_INTR_ON_EXIT),
        // restores the host's EFER, since the guest runs with EFER=0
        .required(.VM_EXIT_LOAD_IA32_EFER, error.EferControlsUnsupported),
    }));

    vmwrite(.VM_ENTRY_CONTROLS, try adjustControls(VmEntryControl, .IA32_VMX_ENTRY_CTLS, &.{
        // no IA32E_MODE: the guest enters in 32-bit protected mode and brings up
        // long mode itself
        .required(.VM_ENTRY_LOAD_IA32_EFER, error.EferControlsUnsupported),
    }));

    setupGuestControlRegs();
    vmwrite(.HOST_IA32_EFER, rdmsr(.EFER));

    vmwriteAsm(.HOST_CR0, "mov %cr0, %rbx");
    vmwriteAsm(.HOST_CR3, "mov %cr3, %rbx");
    vmwriteAsm(.HOST_CR4, "mov %cr4, %rbx");

    vmwrite(.GUEST_GDTR_BASE, 0);
    vmwrite(.GUEST_GDTR_LIMIT, 0);
    vmwrite(.GUEST_IDTR_BASE, 0);
    vmwrite(.GUEST_IDTR_LIMIT, 0);

    vmwrite(.HOST_TR_BASE, gdt.getSegmentDescriptor(getTr(), gdt_info.base).base());

    vmwrite(.HOST_FS_BASE, rdmsr(.FS_BASE));
    vmwrite(.HOST_GS_BASE, rdmsr(.GS_BASE));

    vmwrite(.HOST_IDTR_BASE, idt.idt_descriptor.base);
    vmwrite(.HOST_GDTR_BASE, gdt_info.base);

    // Bit 10 of DR7 is reserved and must be 1.
    vmwrite(.GUEST_DR7, 0x400);

    // bit 1 is reserved and must be 1; IF=0, the guest enables interrupts itself
    vmwrite(.GUEST_RFLAGS, 0x2);

    vmwrite(.MSR_BITMAP, vmstate.msr_bitmap_phys);

    vmwrite(.GUEST_SYSENTER_CS, rdmsr(.IA32_SYSENTER_CS));
    vmwrite(.GUEST_SYSENTER_EIP, rdmsr(.IA32_SYSENTER_EIP));
    vmwrite(.GUEST_SYSENTER_ESP, rdmsr(.IA32_SYSENTER_ESP));

    vmwrite(.HOST_IA32_SYSENTER_CS, rdmsr(.IA32_SYSENTER_CS));
    vmwrite(.HOST_IA32_SYSENTER_EIP, rdmsr(.IA32_SYSENTER_EIP));
    vmwrite(.HOST_IA32_SYSENTER_ESP, rdmsr(.IA32_SYSENTER_ESP));

    vmwrite(.GUEST_RSP, vmstate.guest_ram_block_count * GuestAllocator.block_size);
    vmwrite(.GUEST_RIP, 0);

    vmwrite(.HOST_RSP, @intFromPtr(vmstate.vmm_stack.ptr) +% vmstate.vmm_stack.len);
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

/// one control bit to merge in, and whether the cpu silently dropping it
/// (because it isn't supported) should be tolerated or should fail setup.
fn ControlSpec(comptime CtrlType: type) type {
    return struct {
        ctrl: CtrlType,
        err: ?anyerror,

        pub fn optional(ctrl: CtrlType) @This() {
            return .{ .ctrl = ctrl, .err = null };
        }
        pub fn required(ctrl: CtrlType, err: anyerror) @This() {
            return .{ .ctrl = ctrl, .err = err };
        }
    };
}

fn bitOf(comptime CtrlType: type, ctrl: CtrlType) u64 {
    return if (@typeInfo(CtrlType) == .@"enum") @intFromEnum(ctrl) else ctrl;
}

/// merges all controls given while stripping away all controls not supported by
/// the processor, then fails if any `.required` control didn't survive.
fn adjustControls(comptime CtrlType: type, by_msr: msr.All, specs: []const ControlSpec(CtrlType)) !u64 {
    var all_ctrl: u64 = 0;
    for (specs) |spec|
        all_ctrl |= bitOf(CtrlType, spec.ctrl);

    const msr_val = rdmsr(by_msr);
    const allowed_on_settings: u32 = @truncate(msr_val);
    const allowed_off_settings: u32 = @truncate(msr_val >> 32);

    all_ctrl &= allowed_off_settings;
    all_ctrl |= allowed_on_settings;

    for (specs) |spec| {
        const err = spec.err orelse continue;
        if (all_ctrl & bitOf(CtrlType, spec.ctrl) == 0)
            return err;
    }
    return all_ctrl;
}

fn setGuestSegment(seg_reg: SegReg, selector: u16, base: u64, limit: u32, access_rights: u32) void {
    const offset = @intFromEnum(seg_reg) * 2;
    const oS = offsetSelector;
    vmwrite(oS(.GUEST_ES_SELECTOR, offset), selector);
    vmwrite(oS(.GUEST_ES_LIMIT, offset), limit);
    vmwrite(oS(.GUEST_ES_AR_BYTES, offset), access_rights);
    vmwrite(oS(.GUEST_ES_BASE, offset), base);
}

/// Guest segment state for the Linux 32-bit boot protocol: flat 4GB segments,
/// CS = __BOOT_CS (0x10) and DS/ES/SS = __BOOT_DS (0x18), both covering all of
/// memory. The matching descriptors have to exist in the GDT the guest OS
/// loader writes into guest RAM.
fn setupGuestState32() void {
    // G=1, D/B=1, P=1, S=1, type=0xb (execute/read/accessed)
    const code_ar: u32 = 0xc09b;
    // G=1, D/B=1, P=1, S=1, type=0x3 (read/write/accessed)
    const data_ar: u32 = 0xc093;
    // The byte-granular limit, not the 20-bit descriptor value: a limit of
    // 0xfffff with G=1 was being taken literally, so every fetch at or above
    // 1MB raised #GP(0) while the same byte ran fine below it.
    const flat_limit: u32 = 0xffff_ffff;

    setGuestSegment(.cs, 0x10, 0, flat_limit, code_ar);
    for ([_]SegReg{ .ds, .es, .ss, .fs, .gs }) |seg|
        setGuestSegment(seg, 0x18, 0, flat_limit, data_ar);

    // VM entry requires a usable TR even though the guest never task-switches;
    // type 0xb is a busy 32-bit TSS.
    setGuestSegment(.tr, 0, 0, 0xffff, 0x8b);
    // bit 16 marks the segment unusable
    setGuestSegment(.ldtr, 0, 0, 0, 0x10000);
}

/// Guest control registers for a 32-bit protected-mode entry with paging off.
fn setupGuestControlRegs() void {
    const cr0_pe: u64 = 1 << 0;
    const cr0_et: u64 = 1 << 4;
    const cr0_ne: u64 = 1 << 5;
    const cr0_pg: u64 = 1 << 31;
    const cr4_vmxe: u64 = 1 << 13;

    // Unrestricted guest exempts PE and PG from the fixed-0 requirements, so
    // mask them out before applying the mandatory bits, then force paging off.
    var guest_cr0 = (cr0_pe | cr0_et | cr0_ne) |
        (rdmsr(.IA32_VMX_CR0_FIXED0) & ~(cr0_pe | cr0_pg));
    guest_cr0 &= rdmsr(.IA32_VMX_CR0_FIXED1);
    guest_cr0 &= ~cr0_pg;

    // VMXE is forced on by the fixed MSRs; the guest must not see it, or it
    // reads back a bit it never set
    var guest_cr4 = rdmsr(.IA32_VMX_CR4_FIXED0);
    guest_cr4 &= rdmsr(.IA32_VMX_CR4_FIXED1);

    vmwrite(.GUEST_CR0, guest_cr0);
    vmwrite(.GUEST_CR4, guest_cr4);
    // meaningless with paging off; the guest installs its own tables
    vmwrite(.GUEST_CR3, 0);

    // let the guest own CR0 (it needs to set PG itself), but hide CR4.VMXE
    vmwrite(.CR0_GUEST_HOST_MASK, 0);
    vmwrite(.CR0_READ_SHADOW, guest_cr0);
    vmwrite(.CR4_GUEST_HOST_MASK, cr4_vmxe);
    vmwrite(.CR4_READ_SHADOW, guest_cr4 & ~cr4_vmxe);

    // the guest starts in 32-bit protected mode: no LME, no LMA
    vmwrite(.GUEST_IA32_EFER, 0);
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
    VM_ENTRY_LOAD_IA32_EFER = 0x00008000,
};

pub const VmExitControl = enum(u32) {
    VM_EXIT_IA32E_MODE = 0x00000200,
    VM_EXIT_ACK_INTR_ON_EXIT = 0x00008000,
    VM_EXIT_SAVE_GUEST_PAT = 0x00040000,
    VM_EXIT_LOAD_HOST_PAT = 0x00080000,
    VM_EXIT_SAVE_IA32_EFER = 0x00100000,
    VM_EXIT_LOAD_IA32_EFER = 0x00200000,
};
