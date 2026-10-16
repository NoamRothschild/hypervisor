const std = @import("std");
const debug = @import("../../debug.zig");
const ept = @import("../ept.zig");
const instr_decoder = @import("instr_decoder.zig");
const Vcpu = @import("../vcpu.zig").Vcpu;
const vmread = @import("../vmx.zig").vmread;
const vmwrite = @import("../vmx.zig").vmwrite;

pub const lapic_base = 0xfee00000;

/// register offsets from `lapic_base`
const lvt_timer = 0x320;
const timer_initial_count = 0x380;
const timer_current_count = 0x390;
const timer_divide_config = 0x3E0;

/// the APIC timer's input clock runs at TSC / `tsc_per_bus_cycle`.
/// any steady rate works, Linux calibrates the timer against the PIT.
const tsc_per_bus_cycle = 16;

pub fn eptViolation(vcpu: *Vcpu, violating_addr: ept.GuestPhys) error{Aborted}!void {
    const guest_addr = vmread(.GUEST_RIP);
    const offset = violating_addr.raw() - lapic_base;
    const lapic_index: u64 = @divFloor(offset, 4);

    const mmio_instr = instr_decoder.decodeGuestRip(vcpu) catch |err| {
        const bytes = ept.readGuestVirt([instr_decoder.max_len]u8, vcpu.vm, .from(vmread(.GUEST_CR3)), .from(guest_addr)) catch return error.Aborted;
        return vcpu.abortMsg("failed to decode instr that caused EPT violation: {s}\nistr bytes: {any}\n", .{ @errorName(err), bytes[0..] });
    };
    defer vmwrite(.GUEST_RIP, vmread(.GUEST_RIP) +% mmio_instr.len);

    switch (mmio_instr.kind) {
        .load => {
            const val: u32 = switch (offset) {
                timer_current_count => timerCurrentCount(vcpu),
                else => vcpu.virt_lapic[lapic_index],
            };
            switch (mmio_instr.reg) {
                .rsp => vmwrite(.GUEST_RSP, val),
                inline else => |reg| @field(vcpu.regs.*, @tagName(reg)) = val,
            }
            std.log.info("lapic LOAD @ 0x{x} = 0x{x}\n", .{ offset, val });
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
            std.log.info("lapic STORE @ 0x{x} = 0x{x}\n", .{ offset, val });

            switch (offset) {
                0x30, 0xA0, 0x100...0x270, timer_current_count => {},
                0xB0 => {},
                0x300 => vcpu.virt_lapic[lapic_index] = val & ~(@as(u32, 1) << 12),
                // (re)starts the countdown from `val`, 0 stops the timer
                timer_initial_count => {
                    vcpu.virt_lapic[lapic_index] = val;
                    vcpu.lapic_timer_start_tsc = rdtsc();
                },
                else => vcpu.virt_lapic[lapic_index] = val,
            }
        },
    }

    // first ept violation is
    // mov eax, dword ptr [rdi - 0xa04000]
    // for
    // 8B 87 00 C0 5F FF
}

/// The value the APIC timer's current count register reads as: the initial
/// count minus the timer ticks since it was written, reloading in periodic mode.
pub fn timerCurrentCount(vcpu: *Vcpu) u32 {
    const initial = vcpu.virt_lapic[timer_initial_count / 4];
    if (initial == 0) return 0;

    const tsc_per_tick = tsc_per_bus_cycle * timerDivisor(vcpu.virt_lapic[timer_divide_config / 4]);
    const ticks = (rdtsc() -% vcpu.lapic_timer_start_tsc) / tsc_per_tick;

    // LVT timer bits 17-18: 00 one-shot, 01 periodic, 10 TSC-deadline (not advertised in CPUID)
    const mode: u2 = @truncate(vcpu.virt_lapic[lvt_timer / 4] >> 17);
    if (mode == 0b01)
        return initial - @as(u32, @intCast(ticks % initial));
    return if (ticks >= initial) 0 else initial - @as(u32, @intCast(ticks));
}

/// Decodes the divide configuration register. bits 0, 1 and 3 select
/// 2, 4, 8, ..., 128 and then 1 for 0b111.
fn timerDivisor(divide_config: u32) u64 {
    const sel: u3 = @truncate((divide_config & 0b11) | ((divide_config >> 1) & 0b100));
    return @as(u64, 1) << (sel +% 1);
}

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

test "timerDivisor" {
    try std.testing.expectEqual(2, timerDivisor(0b0000));
    try std.testing.expectEqual(16, timerDivisor(0b0011)); // what Linux programs
    try std.testing.expectEqual(32, timerDivisor(0b1000));
    try std.testing.expectEqual(128, timerDivisor(0b1010));
    try std.testing.expectEqual(1, timerDivisor(0b1011));
    // bit 2 is reserved
    try std.testing.expectEqual(2, timerDivisor(0b0100));
}
