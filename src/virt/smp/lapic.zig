const std = @import("std");
const debug = @import("../../debug.zig");
const ept = @import("../ept.zig");
const instr_decoder = @import("instr_decoder.zig");
const Vcpu = @import("../vcpu.zig").Vcpu;
const vmread = @import("../vmx.zig").vmread;
const vmwrite = @import("../vmx.zig").vmwrite;

pub const lapic_base = 0xfee00000;

pub fn eptViolation(vcpu: *Vcpu, violating_addr: ept.GuestPhys) error{Aborted}!void {
    const guest_addr = vmread(.GUEST_RIP);
    const offset = violating_addr.raw() - lapic_base;
    const lapic_index: u64 = @divFloor(offset, 4);

    const mmio_instr = instr_decoder.decodeGuestRip(vcpu) catch |err| {
        const bytes = ept.readGuestVirt([instr_decoder.max_len]u8, vcpu.vm, .from(vmread(.GUEST_CR3)), .from(guest_addr)) catch return error.Aborted;
        std.log.err("failed to decode instr that caused EPT violation: {s}\nistr bytes: {any}\n", .{ @errorName(err), bytes[0..] });
        switch (err) {
            error.Unsupported => @panic(""),
            else => return error.Aborted,
        }
    };
    defer vmwrite(.GUEST_RIP, vmread(.GUEST_RIP) +% mmio_instr.len);

    debug.printf("got an mmio instr: {}\n", .{mmio_instr});

    switch (mmio_instr.kind) {
        .load => switch (mmio_instr.reg) {
            .rsp => vmwrite(.GUEST_RSP, vcpu.virt_lapic[lapic_index]),
            inline else => |reg| @field(vcpu.regs.*, @tagName(reg)) = vcpu.virt_lapic[lapic_index],
        },
        .store_imm, .store_reg => {
            const val: u32 = blk: {
                if (mmio_instr.kind == .store_imm)
                    break :blk mmio_instr.imm;
                break :blk @truncate(switch (mmio_instr.reg) {
                    .rsp => vmread(.GUEST_RSP),
                    inline else => |v| @field(vcpu.regs.*, @tagName(v)),
                });
            };

            switch (offset) {
                0x30, 0xA0, 0x100...0x270, 0x390 => {},
                0xB0 => {},
                0x300 => vcpu.virt_lapic[lapic_index] = val & ~(@as(u32, 1) << 12),
                0x380 => vcpu.virt_lapic[lapic_index] = val,
                else => vcpu.virt_lapic[lapic_index] = val,
            }
        },
    }

    // first ept violation is
    // mov eax, dword ptr [rdi - 0xa04000]
    // for
    // 8B 87 00 C0 5F FF
}
