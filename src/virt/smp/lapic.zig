const std = @import("std");
const debug = @import("../../debug.zig");
const ept = @import("../ept.zig");
const instr_decoder = @import("instr_decoder.zig");
const ipi = @import("ipi.zig");
const Vcpu = @import("../vcpu.zig").Vcpu;
const vmread = @import("../vmx.zig").vmread;
const vmwrite = @import("../vmx.zig").vmwrite;
const tsc = @import("../../arch/x86_64/tsc.zig");

pub const lapic_base = 0xfee00000;

/// register offsets from `lapic_base`
const apic_id = 0x20;
const version = 0x30;
const task_priority = 0x80;
const processor_priority = 0xA0;
const eoi = 0xB0;
const logical_destination = 0xD0;
const destination_format = 0xE0;
const spurious_vector = 0xF0;
/// in-service register, 8 words of 32 vectors each, 0x10 apart
const isr_base = 0x100;
/// interrupt request register, laid out like `isr_base`
const irr_base = 0x200;
const icr_low = 0x300;
const icr_high = 0x310;
const lvt_timer = 0x320;
const lvt_lint0 = 0x350;
const timer_initial_count = 0x380;
const timer_current_count = 0x390;
const timer_divide_config = 0x3E0;

/// LVT entry bit 16
const lvt_masked = 1 << 16;
/// spurious vector register bit 8
const svr_apic_enabled = 1 << 8;

/// the APIC timer's input clock runs at TSC / `tsc_per_bus_cycle`. CPUID 0x15
/// reports it as the core crystal clock, which Linux takes as the timer's frequency.
pub const tsc_per_bus_cycle = 16;

pub fn eptViolation(vcpu: *Vcpu, violating_addr: ept.GuestPhys) error{Aborted}!void {
    const guest_addr = vmread(.GUEST_RIP);
    const offset = violating_addr - lapic_base;
    const lapic_index: u64 = @divFloor(offset, 4);

    const mmio_instr = instr_decoder.decodeGuestRip(vcpu) catch |err| {
        const bytes = ept.readGuestVirt([instr_decoder.max_len]u8, vcpu.vm, vmread(.GUEST_CR3), guest_addr) catch return error.Aborted;
        return vcpu.abortMsg("failed to decode instr that caused EPT violation: {s}\nistr bytes: {any}\n", .{ @errorName(err), bytes[0..] });
    };
    defer vmwrite(.GUEST_RIP, vmread(.GUEST_RIP) +% mmio_instr.len);

    switch (mmio_instr.kind) {
        .load => {
            const val: u32 = switch (offset) {
                processor_priority => processorPriority(vcpu),
                timer_current_count => timerCurrentCount(vcpu),
                else => vcpu.virt_lapic[lapic_index],
            };
            switch (mmio_instr.reg) {
                .rsp => vmwrite(.GUEST_RSP, val),
                inline else => |reg| @field(vcpu.regs, @tagName(reg)) = val,
            }
            std.log.info("lapic LOAD @ 0x{x} = 0x{x}\n", .{ offset, val });
        },
        .store_imm, .store_reg => {
            const val: u32 = blk: {
                if (mmio_instr.kind == .store_imm)
                    break :blk mmio_instr.imm;
                break :blk @truncate(switch (mmio_instr.reg) {
                    .rsp => vmread(.GUEST_RSP),
                    inline else => |v| @field(vcpu.regs, @tagName(v)),
                });
            };
            std.log.info("lapic STORE @ 0x{x} = 0x{x}\n", .{ offset, val });

            switch (offset) {
                0x30, processor_priority, 0x100...0x270, timer_current_count => {},
                eoi => endOfInterrupt(vcpu),
                icr_low => {
                    // the IPI is delivered right away, so it never reads as send pending
                    vcpu.virt_lapic[lapic_index] = val & ~(@as(u32, 1) << 12);
                    ipi.send(vcpu);
                },
                timer_initial_count => {
                    vcpu.virt_lapic[lapic_index] = val;
                    timerStart(vcpu, val);
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

fn lapicReg(vcpu: *Vcpu, offset: usize) *u32 {
    return &vcpu.virt_lapic[offset / 4];
}

/// The state a LAPIC powers up in, and goes back to on INIT: software disabled,
/// every LVT masked, nothing requested or in service, the timer stopped.
pub fn reset(vcpu: *Vcpu) void {
    vcpu.virt_lapic = @splat(0);
    lapicReg(vcpu, apic_id).* = @as(u32, @truncate(vcpu.index)) << 24;
    lapicReg(vcpu, version).* = 0x0005_0014; // version 0x14, maximum LVT index 5
    lapicReg(vcpu, destination_format).* = 0xFFFF_FFFF; // flat model
    lapicReg(vcpu, spurious_vector).* = 0x0000_00FF;
    // 0x2F0 CMCI, 0x320 timer, 0x330 thermal, 0x340 perfmon, 0x350 LINT0, 0x360 LINT1, 0x370 error
    for ([_]usize{ 0x2F0, 0x320, 0x330, 0x340, 0x350, 0x360, 0x370 }) |lvt|
        lapicReg(vcpu, lvt).* = lvt_masked;
    vcpu.lapic_timer_start_tsc = 0;
    vcpu.lapic_timer_deadline_tsc = 0;
}

/// ID[31:24]
pub fn apicId(vcpu: *Vcpu) u8 {
    return @truncate(lapicReg(vcpu, apic_id).* >> 24);
}

/// What decides whether `vcpu`'s LAPIC is the destination of an IPI.
pub fn ipiTarget(vcpu: *Vcpu) ipi.Target {
    return .{
        .apic_id = apicId(vcpu),
        .logical_id = @truncate(lapicReg(vcpu, logical_destination).* >> 24),
        .dfr_model = @truncate(lapicReg(vcpu, destination_format).* >> 28),
    };
}

/// the interrupt command register as the guest last wrote it, both halves
pub fn icr(vcpu: *Vcpu) ipi.Icr {
    const high: u64 = lapicReg(vcpu, icr_high).*;
    return @bitCast(high << 32 | lapicReg(vcpu, icr_low).*);
}

/// Requests `vector` in the IRR, as a fixed interrupt arriving at the LAPIC does.
/// `Vcpu.prepareEntry` injects it once the guest's priority lets it through.
pub fn raise(vcpu: *Vcpu, vector: u8) void {
    setVector(vcpu, irr_base, vector);
}

fn softwareEnabled(vcpu: *Vcpu) bool {
    return lapicReg(vcpu, spurious_vector).* & svr_apic_enabled != 0;
}

/// The highest priority interrupt in the IRR that the current processor priority lets through.
pub fn pendingVector(vcpu: *Vcpu) ?u8 {
    if (!softwareEnabled(vcpu)) return null;
    const vector = highestVector(vcpu, irr_base) orelse return null;
    // only a higher priority class than the one in service (or the TPR's) interrupts
    if (vector >> 4 <= processorPriority(vcpu) >> 4) return null;
    return vector;
}

/// The guest is being handed `vector`: it moves from the IRR to the ISR until the guest's EOI.
pub fn acceptVector(vcpu: *Vcpu, vector: u8) void {
    clearVector(vcpu, irr_base, vector);
    setVector(vcpu, isr_base, vector);
}

/// Whether the 8259 PIC's output gets through LINT0. Until the guest software-enables
/// its LAPIC, the PIC is wired straight to the cpu (virtual wire mode), as a BIOS leaves it.
pub fn acceptsExtInt(vcpu: *Vcpu) bool {
    if (!softwareEnabled(vcpu)) return true;
    const lvt = lapicReg(vcpu, lvt_lint0).*;
    const delivery_extint = 0b111;
    return lvt & lvt_masked == 0 and (lvt >> 8) & 0b111 == delivery_extint;
}

/// PPR: the TPR, or the priority class of the highest vector in service if that is higher.
fn processorPriority(vcpu: *Vcpu) u32 {
    const tpr = lapicReg(vcpu, task_priority).* & 0xff;
    const in_service: u32 = highestVector(vcpu, isr_base) orelse 0;
    return if (tpr >> 4 >= in_service >> 4) tpr else in_service & 0xf0;
}

/// the guest is done with the highest priority interrupt in service
fn endOfInterrupt(vcpu: *Vcpu) void {
    const vector = highestVector(vcpu, isr_base) orelse return;
    clearVector(vcpu, isr_base, vector);
}

/// the 32-bit register holding `vector`'s bit in the IRR or ISR at `base`
fn vectorWord(vcpu: *Vcpu, base: usize, vector: u8) *u32 {
    return lapicReg(vcpu, base + 0x10 * @as(usize, vector >> 5));
}

fn setVector(vcpu: *Vcpu, base: usize, vector: u8) void {
    vectorWord(vcpu, base, vector).* |= @as(u32, 1) << @truncate(vector);
}

fn clearVector(vcpu: *Vcpu, base: usize, vector: u8) void {
    vectorWord(vcpu, base, vector).* &= ~(@as(u32, 1) << @truncate(vector));
}

fn highestVector(vcpu: *Vcpu, base: usize) ?u8 {
    var word_idx: u8 = 8;
    while (word_idx > 0) {
        word_idx -= 1;
        const word = lapicReg(vcpu, base + 0x10 * @as(usize, word_idx)).*;
        if (word != 0) return word_idx * 32 + (31 - @as(u8, @clz(word)));
    }
    return null;
}

/// (re)starts the countdown from `initial`, 0 stops the timer
fn timerStart(vcpu: *Vcpu, initial: u32) void {
    const now = tsc.read();
    vcpu.lapic_timer_start_tsc = now;
    vcpu.lapic_timer_deadline_tsc = if (initial == 0) 0 else now + @as(u64, initial) * tscPerTick(vcpu);
}

/// The TSC at which the timer next fires, null if it is stopped or one-shot and already fired.
pub fn timerDeadline(vcpu: *Vcpu) ?u64 {
    const deadline = vcpu.lapic_timer_deadline_tsc;
    return if (deadline == 0) null else deadline;
}

/// Fires the timer if its deadline passed: raises the LVT's vector in the IRR,
/// then re-arms a periodic timer or stops a one-shot one.
/// Called before every VM entry, the preemption timer makes sure one happens in time.
pub fn timerPoll(vcpu: *Vcpu) void {
    const deadline = timerDeadline(vcpu) orelse return;
    const now = tsc.read();
    if (now < deadline) return;

    const lvt = lapicReg(vcpu, lvt_timer).*;
    // a masked timer still counts down, it just doesn't interrupt
    if (lvt & lvt_masked == 0) setVector(vcpu, irr_base, @truncate(lvt));

    if (timerMode(lvt) == .periodic) {
        const period = @as(u64, lapicReg(vcpu, timer_initial_count).*) * tscPerTick(vcpu);
        // the IRR has one bit per vector, so periods missed meanwhile merge into this one
        vcpu.lapic_timer_deadline_tsc = deadline + period * ((now - deadline) / period + 1);
    } else {
        vcpu.lapic_timer_deadline_tsc = 0;
    }
}

/// The value the APIC timer's current count register reads as: the initial
/// count minus the timer ticks since it was written, reloading in periodic mode.
pub fn timerCurrentCount(vcpu: *Vcpu) u32 {
    const initial = lapicReg(vcpu, timer_initial_count).*;
    if (initial == 0) return 0;

    const ticks = (tsc.read() -% vcpu.lapic_timer_start_tsc) / tscPerTick(vcpu);
    if (timerMode(lapicReg(vcpu, lvt_timer).*) == .periodic)
        return initial - @as(u32, @intCast(ticks % initial));
    return if (ticks >= initial) 0 else initial - @as(u32, @intCast(ticks));
}

/// LVT timer bits 17-18. TSC-deadline isn't advertised in CPUID, so the guest doesn't pick it
const TimerMode = enum(u2) { one_shot = 0b00, periodic = 0b01, tsc_deadline = 0b10, _ };

fn timerMode(lvt: u32) TimerMode {
    return @enumFromInt(@as(u2, @truncate(lvt >> 17)));
}

fn tscPerTick(vcpu: *Vcpu) u64 {
    return tsc_per_bus_cycle * timerDivisor(lapicReg(vcpu, timer_divide_config).*);
}

/// Decodes the divide configuration register. bits 0, 1 and 3 select
/// 2, 4, 8, ..., 128 and then 1 for 0b111.
fn timerDivisor(divide_config: u32) u64 {
    const sel: u3 = @truncate((divide_config & 0b11) | ((divide_config >> 1) & 0b100));
    return @as(u64, 1) << (sel +% 1);
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
