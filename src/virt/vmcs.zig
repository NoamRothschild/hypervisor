const std = @import("std");
const vmx = @import("vmx.zig");
const msr = @import("msr.zig");
const debug = @import("../debug.zig");
const paging = @import("../arch/x86_64/paging.zig");
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

    const basic = rdmsr(msr.vt_msrs.IA32_VMX_BASIC);
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
    _ = vmstate;
}
