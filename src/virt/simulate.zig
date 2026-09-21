const std = @import("std");
const debug = @import("../debug.zig");
const paging = @import("../arch/x86_64/paging.zig");
const ept = @import("ept.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const msr = @import("msr.zig");
const vmx = @import("vmx.zig");
const vmread = vmx.vmread;
const vmwrite = vmx.vmwrite;
const Vcpu = @import("vcpu.zig").Vcpu;

pub fn cpuid(vcpu: *Vcpu) void {
    const guest_regs = vcpu.regs;
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    const leaf: u32 = @truncate(guest_regs.rax);
    const subleaf: u32 = @truncate(guest_regs.rcx);

    if (leaf >= 0x40000000 and leaf <= 0x4fffffff) {
        // TODO: fixme: move bellow sig to a move visible place place,
        // instead of hardcoding it in simulate.cpuid
        const sig = "NoamRTD HV\x00\x00".*;
        const is_base = leaf == 0x40000000;
        guest_regs.rax = if (is_base) 0x40000000 else 0;
        guest_regs.rbx = if (is_base) std.mem.readInt(u32, sig[0..4], .little) else 0;
        guest_regs.rcx = if (is_base) std.mem.readInt(u32, sig[4..8], .little) else 0;
        guest_regs.rdx = if (is_base) std.mem.readInt(u32, sig[8..12], .little) else 0;
        return;
    }

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );

    // get features: ecx is the low half of `CpuFeatures`, edx the high half
    if (leaf == 1) {
        ecx &= ~(@as(u32, 1) << @bitOffsetOf(debug.CpuFeatures, "vmx"));
        ecx |= @as(u32, 1) << @bitOffsetOf(debug.CpuFeatures, "hypervisor");
        // no MTRRs: Linux then skips MTRR setup and never touches those MSRs
        edx &= ~(@as(u32, 1) << (@bitOffsetOf(debug.CpuFeatures, "mtrr") - 32));
    }

    // in 64-bit mode cpuid clears the upper halves of all four registers
    guest_regs.rax = eax;
    guest_regs.rbx = ebx;
    guest_regs.rcx = ecx;
    guest_regs.rdx = edx;
}

/// pops `@sizeOf(T)` bytes from the stack into return value.
pub fn pop(comptime T: type, guest_state: *vmx.VMState, cr3_if_virt: ?ept.GuestPhys) !T {
    const rsp = vmread(.GUEST_RSP);
    const value = if (cr3_if_virt) |cr3|
        try ept.readGuestVirt(T, guest_state, cr3, .from(rsp))
    else
        try ept.readGuestPhys(T, guest_state, .from(rsp));
    vmwrite(.GUEST_RSP, rsp +% 8);
    return value;
}

/// emulate `iret` for real mode systems. to be used while emulating BIOS commands
pub fn iret16(guest_state: *vmx.VMState) !void {
    const ip = try pop(u16, guest_state, null);
    errdefer vmwrite(.GUEST_RSP, vmread(.GUEST_RSP) -% 8);

    const cs = try pop(u16, guest_state, null);
    errdefer vmwrite(.GUEST_RSP, vmread(.GUEST_RSP) -% 8);

    const flags = try pop(u16, guest_state, null);
    errdefer vmwrite(.GUEST_RSP, vmread(.GUEST_RSP) -% 8);

    vmwrite(.GUEST_RIP, ip);
    vmwrite(.GUEST_CS_SELECTOR, cs);
    vmwrite(.GUEST_CS_BASE, @as(u64, cs) << 4);
    vmwrite(.GUEST_RFLAGS, flags);
}

pub fn rdmsr(vcpu: *Vcpu) error{Aborted}!void {
    const guest_regs = vcpu.regs;
    const msr_kind: msr.All = @enumFromInt(guest_regs.rcx);

    const val: u64 = switch (msr_kind) {
        .IA32_TSC_ADJUST => vcpu.shadow_msrs.tsc_adjust,
        .IA32_MCG_CAP => msr.mc_bank_count, // count only, no MCG_CTL_P/extended features
        .EFER => vmread(.GUEST_IA32_EFER) | (vmread(.GUEST_IA32_EFER_HIGH) << 32),
        .FS_BASE => vmread(.GUEST_FS_BASE),
        .GS_BASE => vmread(.GUEST_GS_BASE),
        .IA32_MISC_ENABLE => blk: {
            var val: msr.IA32_MISC_ENABLE = @bitCast(msr.rdmsr(.IA32_MISC_ENABLE));
            // cpuid is passed through, so all leaves are reachable
            val.limit_cpuid_maxval = 0;
            // the guest brings up long mode with NX
            val.xd_bit_disable = 0;
            // neither branch trace store nor PEBS is emulated
            val.bts_unavailable = 1;
            val.pebs_unavailable = 1;
            break :blk @bitCast(val);
        },
        .KERNEL_GS_BASE => blk: {
            const e = vcpu.guest_msr.find(msr_kind) orelse {
                std.debug.panic("RDMSR: MSR `{s}` is not registered\n", .{@tagName(msr_kind)});
            };
            break :blk e.data;
        },
        .IA32_UCODE_REV => blk: {
            const msr_initial = if (vcpu.guest_msr.find(.IA32_UCODE_REV)) |m|
                m.data
            else
                0;
            msr.wrmsr(.IA32_UCODE_REV, msr_initial);
            _ = debug.getFeatures();
            // ^^ cpuid, eax=1
            break :blk msr.rdmsr(.IA32_UCODE_REV);
        },
        .IA32_ARCH_CAPABILITIES => msr.rdmsr(.IA32_ARCH_CAPABILITIES),
        _ => if (msr.isMcBankMsr(guest_regs.ecx().*))
            0 // RAZ
        else
            return vcpu.abortMsg("Unhandled RDMSR for 0x{x}\n", .{@intFromEnum(msr_kind)}),
        else => return vcpu.abortMsg("Unhandled RDMSR for {s}\n", .{@tagName(msr_kind)}),
    };

    guest_regs.edx().* = @truncate(val >> 32);
    guest_regs.eax().* = @truncate(val);
}

pub fn wrmsr(vcpu: *Vcpu) error{Aborted}!void {
    const guest_regs = vcpu.regs;
    const val = (@as(u64, guest_regs.edx().*) << 32) | @as(u64, guest_regs.eax().*);
    const msr_kind: msr.All = @enumFromInt(guest_regs.rcx);

    switch (msr_kind) {
        .STAR, .LSTAR, .CSTAR, .TSC_AUX, .SYSCALL_MASK, .KERNEL_GS_BASE => {
            if (vcpu.guest_msr.find(msr_kind)) |e|
                e.data = val
            else
                std.debug.panic("WRMSR: MSR `{s}` is not registered\n", .{@tagName(msr_kind)});
        },
        .IA32_SYSENTER_CS => vmwrite(.GUEST_SYSENTER_CS, val),
        .IA32_SYSENTER_EIP => vmwrite(.GUEST_SYSENTER_EIP, val),
        .IA32_SYSENTER_ESP => vmwrite(.GUEST_SYSENTER_ESP, val),
        .EFER => {
            vmwrite(.GUEST_IA32_EFER, val & 0xffff_ffff);
            vmwrite(.GUEST_IA32_EFER_HIGH, val >> 32);
        },
        .IA32_TSC_ADJUST => vcpu.shadow_msrs.tsc_adjust = val, // shadow only, TSC_OFFSET is not touched
        .GS_BASE => vmwrite(.GUEST_GS_BASE, val),
        .FS_BASE => vmwrite(.GUEST_FS_BASE, val),
        .IA32_UCODE_REV => {
            if (val != 0)
                return;
            vcpu.guest_msr.set(.IA32_UCODE_REV, val);
        },
        _ => if (!msr.isMcBankMsr(guest_regs.ecx().*)) // else WI
            return vcpu.abortMsg("Unhandled WRMSR for 0x{x}\n", .{@intFromEnum(msr_kind)}),
        else => return vcpu.abortMsg("Unhandled WRMSR for {s}\n", .{@tagName(msr_kind)}),
    }
}

pub const crAccess = @import("cr.zig").crAccess;
