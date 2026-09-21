const std = @import("std");
const debug = @import("../debug.zig");
const hhdm = @import("../mem/hhdm.zig");
const ept = @import("ept.zig");
const vmcs = @import("vmcs.zig");
const msr = @import("msr.zig");
const vmx = @import("vmx.zig");
const vmread = vmx.vmread;
const vmwrite = vmx.vmwrite;
const Vcpu = @import("vcpu.zig").Vcpu;

pub const Cr0 = packed struct(u64) {
    /// protected mode enable
    pe: bool,
    /// monitor co-processor
    mp: bool,
    /// emulation
    em: bool,
    /// task switched
    ts: bool,
    /// extension type
    et: bool,
    /// numeric error
    ne: bool,
    /// reserved
    rsvd1: u10 = 0,
    /// write protect
    wp: bool,
    /// reserved
    rsvd2: u1 = 0,
    /// alignment mask
    am: bool,
    /// reserved
    rsvd3: u10 = 0,
    /// not-Write Through
    nw: bool,
    /// cache disable
    cd: bool,
    /// paging
    pg: bool,
    /// reserved
    rsvd4: u32 = 0,
};

/// contains the VA of the last page fault
pub const Cr2 = u64;

pub const Cr4 = packed struct(u64) {
    /// virtual-8086 mode extensions
    vme: bool,
    /// protected mode virtual interrupts
    pvi: bool,
    /// time stamp disable
    tsd: bool,
    /// debugging extensions
    de: bool,
    /// page size extension
    pse: bool,
    /// physical address extension. If unset, 32-bit paging
    pae: bool,
    /// machine check exception
    mce: bool,
    /// page global enable
    pge: bool,
    /// performance monitoring counter enable
    pce: bool,
    /// operating system support for FXSAVE and FXRSTOR instructions
    osfxsr: bool,
    /// operating system support for unmasked SIMD floating-point exceptions
    osxmmexcpt: bool,
    /// virtual machine extensions
    umip: bool,
    /// 57-bit linear addresses. If set, CPU uses 5-level paging
    la57: bool = false,
    /// virtual machine extensions enable
    vmxe: bool,
    /// safer mode extensions enable
    smxe: bool,
    /// reserved
    rsvd2: u1 = 0,
    /// enables the instructions RDFSBASE, RDGSBASE, WRFSBASE, and WRGSBASE
    fsgsbase: bool,
    /// pCID enable
    pcide: bool,
    /// xSAVE and processor extended states enable
    osxsave: bool,
    /// reserved
    rsvd3: u1 = 0,
    /// supervisor mode execution protection enable
    smep: bool,
    /// supervisor mode access protection enable
    smap: bool,
    /// protection key enable
    pke: bool,
    /// control-flow Enforcement Technology enable
    cet: bool,
    /// protection keys for supervisor-mode pages enable
    pks: bool,
    /// reserved
    rsvd4: u39 = 0,
};

fn crPassthroughRead(vcpu: *Vcpu, exit_qual: vmx.ExitQualification.Cr) error{Aborted}!void {
    // read access to CR0 and CR4 does not cause a VM Exit
    // since all bits in the masks are set, reads from CR0 and CR4
    //  always return the values stored in the read shadows
    const val = switch (exit_qual.index) {
        3 => vmread(.GUEST_CR3),
        else => return vcpu.abortMsg("unhandled read from CR{d}\n", .{exit_qual.index}),
    };

    exit_qual.setVal(vcpu, val);
}

fn crPassthroughWrite(vcpu: *Vcpu, exit_qual: vmx.ExitQualification.Cr) error{Aborted}!void {
    var cr_val = exit_qual.getVal(vcpu);
    std.log.info("new CR{d} value: 0x{x}\n", .{ exit_qual.index, cr_val });
    switch (exit_qual.index) {
        0 => {
            vmwrite(.CR0_READ_SHADOW, cr_val);
            vmx.adjustCr0(&cr_val);
            vmwrite(.GUEST_CR0, cr_val);
            updateIa32e();
        },
        3 => {
            // TODO: opt for INVVPID rather than INVEPT (extra uneccessary flushes)
            ept.invept(.single_context, vmread(.EPT_POINTER));

            // in VMX Operation, the guest’s CR3[63] must always be 0. (related to PCID)
            cr_val &= ~@as(u64, 1 << 63);
            vmwrite(.GUEST_CR3, cr_val);
        },
        4 => {
            vmwrite(.CR4_READ_SHADOW, cr_val);
            vmx.adjustCr4(&cr_val);
            vmwrite(.GUEST_CR4, cr_val);
            updateIa32e();
        },
        else => return vcpu.abortMsg("unhandled write to CR{d}\n", .{exit_qual.index}),
    }
}

/// Update IA-32e mode of the vCPU.
fn updateIa32e() void {
    const cr0: Cr0 = @bitCast(vmx.vmread(.GUEST_CR0));
    const cr4: Cr4 = @bitCast(vmx.vmread(.GUEST_CR4));
    const ia32e_enabled = cr0.pg and cr4.pae;

    var entry_ctrl: u32 = @truncate(vmread(.VM_ENTRY_CONTROLS));
    if (ia32e_enabled)
        entry_ctrl |= @intFromEnum(vmcs.VmEntryControl.VM_ENTRY_IA32E_MODE)
    else
        entry_ctrl &= ~@intFromEnum(vmcs.VmEntryControl.VM_ENTRY_IA32E_MODE);
    vmwrite(.VM_ENTRY_CONTROLS, entry_ctrl);

    var efer: msr.Efer = @bitCast(vmread(.GUEST_IA32_EFER) | (vmread(.GUEST_IA32_EFER_HIGH) << 32));
    efer.lma = ia32e_enabled;
    efer.lme = if (cr0.pg) efer.lma else efer.lme;
    const efer_int: u64 = @bitCast(efer);
    vmx.vmwrite(.GUEST_IA32_EFER_HIGH, efer_int >> 32);
    vmx.vmwrite(.GUEST_IA32_EFER, efer_int);
}

pub fn crAccess(vcpu: *Vcpu, exit_qual: vmx.ExitQualification.Cr) error{Aborted}!void {
    std.log.info("guest tried to perform {s} on CR{d} from reg {s}\n", .{
        @tagName(exit_qual.access_type),
        exit_qual.index,
        @tagName(exit_qual.reg),
    });
    switch (exit_qual.access_type) {
        .mov_to => try crPassthroughWrite(vcpu, exit_qual),
        .mov_from => try crPassthroughRead(vcpu, exit_qual),
        else => return vcpu.abortMsg("Unimplemented CR access request for {s}\n", .{@tagName(exit_qual.access_type)}),
    }
}
