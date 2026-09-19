const std = @import("std");
const debug = @import("../debug.zig");
const paging = @import("../arch/x86_64/paging.zig");
const ept = @import("ept.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const msr = @import("msr.zig");
const vmx = @import("vmx.zig");
const vmread = vmx.vmread;
const vmwrite = vmx.vmwrite;
const CpuState = vmx.CpuState;

pub fn cpuid(guest_regs: *CpuState) void {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    const leaf: u32 = @truncate(guest_regs.rax);
    const subleaf: u32 = @truncate(guest_regs.rcx);

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );

    // get features: ecx is the low half of `CpuFeatures`
    if (leaf == 1) {
        ecx &= ~(@as(u32, 1) << @bitOffsetOf(debug.CpuFeatures, "vmx"));
        ecx |= @as(u32, 1) << @bitOffsetOf(debug.CpuFeatures, "hypervisor");
    }

    // in 64-bit mode cpuid clears the upper halves of all four registers
    guest_regs.rax = eax;
    guest_regs.rbx = ebx;
    guest_regs.rcx = ecx;
    guest_regs.rdx = edx;
}

/// pops `@sizeOf(T)` bytes from the stack into return value.
pub fn pop(comptime T: type, guest_state: *vmx.VMState, cr3_if_virt: ?u64) !T {
    const rsp = vmread(.GUEST_RSP);
    const value = try ept.readGuest(T, guest_state, rsp, cr3_if_virt);
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

pub fn e820(guest_state: *vmx.VMState, guest_regs: *CpuState) void {
    _ = guest_state;
    _ = guest_regs;
    @compileError("unimplemented");
}

pub fn rdmsr(guest_state: *vmx.VMState, guest_regs: *CpuState) void {
    debug.printf("msr tag: 0x{x}\n", .{guest_regs.rcx});
    const msr_kind: msr.All = @enumFromInt(guest_regs.rcx);

    const val: u64 = switch (msr_kind) {
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
            const e = guest_state.guest_msr.find(msr_kind) orelse {
                std.debug.panic("RDMSR: MSR `{s}` is not registered\n", .{@tagName(msr_kind)});
            };
            break :blk e.data;
        },
        else => std.debug.panic("Unhandled RDMSR for {s}\n", .{@tagName(msr_kind)}),
    };

    guest_regs.edx().* = @truncate(val >> 32);
    guest_regs.eax().* = @truncate(val);
}

pub fn wrmsr(guest_state: *vmx.VMState, guest_regs: *CpuState) void {
    const val = (@as(u64, guest_regs.edx().*) << 32) | @as(u64, guest_regs.eax().*);
    const msr_kind: msr.All = @enumFromInt(guest_regs.rcx);

    switch (msr_kind) {
        .STAR, .LSTAR, .CSTAR, .TSC_AUX, .SYSCALL_MASK, .KERNEL_GS_BASE => {
            if (guest_state.guest_msr.find(msr_kind)) |e|
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
        .GS_BASE => vmwrite(.GUEST_GS_BASE, val),
        .FS_BASE => vmwrite(.GUEST_FS_BASE, val),
        else => std.debug.panic("Unhandled WRMSR for {s}\n", .{@tagName(msr_kind)}),
    }
}
