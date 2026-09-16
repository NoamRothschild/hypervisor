const std = @import("std");
const debug = @import("../debug.zig");
const paging = @import("../arch/x86_64/paging.zig");
const ept = @import("ept.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
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
    @panic("unimplemented");
}
