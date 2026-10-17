//! Inter-processor interrupts: what a vcpu's write to its ICR does to the vcpus it targets.
//! ref: SDM Vol.3A, "Issuing Interprocessor Interrupts"
const std = @import("std");
const debug = @import("../../debug.zig");
const lapic = @import("lapic.zig");
const Vcpu = @import("../vcpu.zig").Vcpu;

/// The interrupt command register: ICR high (0x310) << 32 | ICR low (0x300).
pub const Icr = packed struct(u64) {
    vector: u8,
    delivery_mode: DeliveryMode,
    dest_mode: DestMode,
    /// send pending. always reads 0, an IPI is delivered before the ICR write returns
    delivery_status: u1 = 0,
    rsvd0: u1 = 0,
    /// false only in the "INIT level de-assert" IPI, which modern cpus ignore
    level_assert: bool,
    trigger: Trigger,
    rsvd1: u2 = 0,
    shorthand: Shorthand,
    rsvd2: u36 = 0,
    /// an APIC ID (physical mode) or a logical ID to match against LDRs (logical mode)
    dest: u8,

    pub const DeliveryMode = enum(u3) {
        fixed = 0,
        lowest_priority = 1,
        smi = 2,
        nmi = 4,
        init = 5,
        startup = 6,
        _,
    };
    pub const DestMode = enum(u1) { physical, logical };
    pub const Trigger = enum(u1) { edge, level };
    pub const Shorthand = enum(u2) { none, self, all_including_self, all_excluding_self };
};

/// What decides whether a LAPIC is the destination of an IPI.
pub const Target = struct {
    apic_id: u8,
    /// LDR[31:24]
    logical_id: u8,
    /// DFR[31:28], how `logical_id` is matched: 0xf is the flat model, 0x0 the cluster one
    dfr_model: u4,
};

/// Delivers the IPI `sender` just wrote into its ICR to every vcpu it targets.
///
/// it only changes the targets' software state (the IRR, `Vcpu.state`, the start
/// state), never their VMCS, which isn't the current one. each target picks it up in
/// its own `prepareEntry`.
pub fn send(sender: *Vcpu) void {
    const icr = lapic.icr(sender);
    const sender_id = lapic.apicId(sender);

    for (sender.vm.cpus) |*target| {
        if (!isDestination(icr, sender_id, lapic.ipiTarget(target))) continue;
        deliver(target, icr);
        // a single vcpu runs at a time, so the first match is as low a priority as any
        if (icr.delivery_mode == .lowest_priority) break;
    }
}

fn deliver(target: *Vcpu, icr: Icr) void {
    switch (icr.delivery_mode) {
        // vectors 0-15 are illegal for fixed interrupts, the sender's ESR would report it
        .fixed, .lowest_priority => if (icr.vector >= 16) lapic.raise(target, icr.vector),
        .init => {
            // the de-assert half of the old INIT handshake does nothing on modern cpus
            if (icr.trigger == .level and !icr.level_assert) return;
            logAlways("vcpu {d}: INIT\n", .{target.index});
            target.handleInit();
        },
        .startup => {
            logAlways("vcpu {d}: SIPI, vector 0x{x}\n", .{ target.index, icr.vector });
            target.handleStartup(icr.vector);
        },
        else => std.log.warn("vcpu {d}: dropped an IPI with delivery mode {d}\n", .{
            target.index,
            @intFromEnum(icr.delivery_mode),
        }),
    }
}

/// Whether the LAPIC described by `target` receives `icr`, sent by the LAPIC with `sender_id`.
pub fn isDestination(icr: Icr, sender_id: u8, target: Target) bool {
    return switch (icr.shorthand) {
        .self => target.apic_id == sender_id,
        .all_including_self => true,
        .all_excluding_self => target.apic_id != sender_id,
        .none => switch (icr.dest_mode) {
            .physical => icr.dest == 0xff or icr.dest == target.apic_id,
            .logical => logicalMatch(icr.dest, target),
        },
    };
}

fn logicalMatch(dest: u8, target: Target) bool {
    // a broadcast in both models
    if (dest == 0xff) return true;
    return switch (target.dfr_model) {
        // flat: `dest` is a bitmask, a LAPIC matches if it shares a bit with its LDR
        0xf => dest & target.logical_id != 0,
        // cluster: the high nibble picks the cluster, the low nibble is a bitmask in it
        0x0 => dest >> 4 == target.logical_id >> 4 and dest & target.logical_id & 0xf != 0,
        else => false,
    };
}

/// INIT and SIPI are rare and the first thing to look at when an AP doesn't come
/// up, so they are logged even while a VM-exit handler mutes logging.
fn logAlways(comptime fmt: []const u8, args: anytype) void {
    const old = debug.logging_enabled;
    defer debug.logging_enabled = old;
    debug.logging_enabled = true;
    std.log.info(fmt, args);
}

fn testIcr(fields: struct {
    dest_mode: Icr.DestMode = .physical,
    shorthand: Icr.Shorthand = .none,
    dest: u8 = 0,
}) Icr {
    return .{
        .vector = 0xfd,
        .delivery_mode = .fixed,
        .dest_mode = fields.dest_mode,
        .level_assert = true,
        .trigger = .edge,
        .shorthand = fields.shorthand,
        .dest = fields.dest,
    };
}

test "Icr layout" {
    // INIT, level assert, physical, to APIC ID 1: what Linux writes to wake an AP
    const init: Icr = @bitCast(@as(u64, 0x01 << 56 | 0x0000_c500));
    try std.testing.expectEqual(.init, init.delivery_mode);
    try std.testing.expect(init.level_assert);
    try std.testing.expectEqual(.level, init.trigger);
    try std.testing.expectEqual(1, init.dest);

    // STARTUP to the trampoline at 0x9a000, with the all-excluding-self shorthand
    const sipi: Icr = @bitCast(@as(u64, 0x000c_069a));
    try std.testing.expectEqual(.startup, sipi.delivery_mode);
    try std.testing.expectEqual(0x9a, sipi.vector);
    try std.testing.expectEqual(.all_excluding_self, sipi.shorthand);
}

test "isDestination physical" {
    const cpu1: Target = .{ .apic_id = 1, .logical_id = 0, .dfr_model = 0xf };
    try std.testing.expect(isDestination(testIcr(.{ .dest = 1 }), 0, cpu1));
    try std.testing.expect(!isDestination(testIcr(.{ .dest = 2 }), 0, cpu1));
    try std.testing.expect(isDestination(testIcr(.{ .dest = 0xff }), 0, cpu1));
}

test "isDestination shorthands" {
    const cpu0: Target = .{ .apic_id = 0, .logical_id = 0, .dfr_model = 0xf };
    try std.testing.expect(isDestination(testIcr(.{ .shorthand = .self }), 0, cpu0));
    try std.testing.expect(!isDestination(testIcr(.{ .shorthand = .self }), 1, cpu0));
    try std.testing.expect(!isDestination(testIcr(.{ .shorthand = .all_excluding_self }), 0, cpu0));
    try std.testing.expect(isDestination(testIcr(.{ .shorthand = .all_including_self }), 0, cpu0));
    // the shorthand wins over `dest`
    try std.testing.expect(isDestination(testIcr(.{ .shorthand = .all_excluding_self, .dest = 5 }), 1, cpu0));
}

test "isDestination logical" {
    const flat_cpu1: Target = .{ .apic_id = 1, .logical_id = 0b10, .dfr_model = 0xf };
    try std.testing.expect(isDestination(testIcr(.{ .dest_mode = .logical, .dest = 0b11 }), 0, flat_cpu1));
    try std.testing.expect(!isDestination(testIcr(.{ .dest_mode = .logical, .dest = 0b01 }), 0, flat_cpu1));

    const cluster2_cpu1: Target = .{ .apic_id = 9, .logical_id = 0x22, .dfr_model = 0x0 };
    try std.testing.expect(isDestination(testIcr(.{ .dest_mode = .logical, .dest = 0x23 }), 0, cluster2_cpu1));
    try std.testing.expect(!isDestination(testIcr(.{ .dest_mode = .logical, .dest = 0x12 }), 0, cluster2_cpu1));
    try std.testing.expect(isDestination(testIcr(.{ .dest_mode = .logical, .dest = 0xff }), 0, cluster2_cpu1));
}
