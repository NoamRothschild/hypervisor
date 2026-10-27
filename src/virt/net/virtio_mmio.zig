///! virtio-mmio transport (version 2, "modern"), the register block of one device.
///! ref: https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html (section 4.2)
///!
///! the guest finds it through `virtio_mmio.device=4K@<base>:<irq>` on its cmdline.
const std = @import("std");
const debug = @import("../../debug.zig");
const Vcpu = @import("../vcpu.zig").Vcpu;
const ept = @import("../ept.zig");
const vmread = @import("../vmx.zig").vmread;
const vmwrite = @import("../vmx.zig").vmwrite;
const instr_decoder = @import("../instr_decoder.zig");

pub const base = 0xd0000000;
pub const size = 0x1000;
/// the IRQ given on the guest's cmdline
pub const irq = 5;

/// the registers of the register block, by their offset from `base`
const Offset = enum(u12) {
    magic_value = 0x000,
    version = 0x004,
    device_id = 0x008,
    vendor_id = 0x00c,
    device_features = 0x010,
    device_features_sel = 0x014,
    driver_features = 0x020,
    driver_features_sel = 0x024,
    queue_sel = 0x030,
    queue_num_max = 0x034,
    queue_num = 0x038,
    queue_ready = 0x044,
    queue_notify = 0x050,
    interrupt_status = 0x060,
    interrupt_ack = 0x064,
    status = 0x070,
    queue_desc_low = 0x080,
    queue_desc_high = 0x084,
    queue_driver_low = 0x090,
    queue_driver_high = 0x094,
    queue_device_low = 0x0a0,
    queue_device_high = 0x0a4,
    config_generation = 0x0fc,
    /// anything else, including the device specific configuration space from `config_offset`
    _,
};

/// device specific configuration space starts here
const config_offset = 0x100;

/// the MAC address of the guest's NIC. locally administered (bit 1 of the first byte).
pub const guest_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x14, 0x41, 0x44 };

/// "virt", little endian
const magic: u32 = 0x74726976;
/// 1 is the legacy interface, 2 the one of virtio 1.0 and later
const interface_version: u32 = 2;
/// "NOAM", little endian
const vendor: u32 = 0x4d414f4e;

pub const DeviceID = enum(u32) {
    invalid = 0,
    network = 1,
    block = 2,
    console = 3,
    entropy = 4,
    memory_balloon = 5,
    filesystem_9p = 9,
    gpu = 16,
    input = 18,
    filesystem_fs = 26,
    _,
};

pub const VirtioStatus = packed struct(u32) {
    ack: bool = false, // (0x01)
    driver: bool = false, // (0x02)
    driver_ok: bool = false, // (0x04)
    feat_ok: bool = false, // (0x08)
    rsvd: u2 = 0,
    needs_reset: bool = false, // (0x40)
    failed: bool = false, // (0x80)
    rsvd1: u24 = 0,
};

/// feature bit 32, the device follows virtio 1.0 and later. required by `interface_version` 2.
const f_version_1: u64 = 1 << 32;
/// VIRTIO_NET_F_MAC, feature bit 5: the device has a MAC address in its config space
const f_net_mac: u64 = 1 << 5;

/// the state of one virtio-mmio device, shared by every vcpu of the guest
pub const Device = struct {
    device_id: DeviceID,
    /// the MAC address in the config space, see `virtio_net_config`
    mac: [6]u8,
    status: VirtioStatus,
    /// the features the device offers
    device_features: u64,
    /// the features the driver accepted
    driver_features: u64,
    /// which 32 bit half of the features `device_features`/`driver_features` access
    device_features_sel: u32,
    driver_features_sel: u32,
    /// the queue the `queue_*` registers refer to
    queue_sel: u32,

    pub fn init(device_id: DeviceID, mac: [6]u8) Device {
        return .{
            .device_id = device_id,
            .mac = mac,
            .status = .{},
            .device_features = f_version_1 | f_net_mac,
            .driver_features = 0,
            .device_features_sel = 0,
            .driver_features_sel = 0,
            .queue_sel = 0,
        };
    }

    /// writing 0 to `status`
    fn reset(self: *Device) void {
        self.* = .init(self.device_id, self.mac);
    }
};

pub fn eptViolation(vcpu: *Vcpu, violating_addr: ept.GuestPhys) error{Aborted}!void {
    const old_debug_enable = debug.logging_enabled;
    defer debug.logging_enabled = old_debug_enable;
    debug.logging_enabled = true;

    const guest_addr = vmread(.GUEST_RIP);
    const offset = violating_addr - base;

    const mmio_instr = instr_decoder.decodeGuestRip(vcpu) catch |err| {
        const bytes = ept.readGuestVirt([instr_decoder.max_len]u8, vcpu.vm, vmread(.GUEST_CR3), guest_addr) catch return error.Aborted;
        return vcpu.abortMsg("failed to decode instr that caused EPT violation: {s}\nistr bytes: {any}\n", .{ @errorName(err), bytes[0..] });
    };
    defer vmwrite(.GUEST_RIP, vmread(.GUEST_RIP) +% mmio_instr.len);

    const dev = &vcpu.vm.virtio_net;
    const reg: Offset = @enumFromInt(offset);
    var name_buf: [8]u8 = undefined;
    const name = regName(reg, &name_buf);

    switch (mmio_instr.kind) {
        .load => {
            const val = if (offset >= config_offset)
                readConfig(dev, offset - config_offset, mmio_instr.size)
            else
                read(dev, reg);
            std.log.info("virtio-mmio LOAD @ {s} = 0x{x}\n", .{ name, val });
            mmio_instr.write(vcpu, val);
        },
        .store_imm, .store_reg => {
            const val = mmio_instr.read(vcpu);
            std.log.info("virtio-mmio STORE @ {s} = 0x{x}\n", .{ name, val });
            write(dev, reg, val);
        },
    }
}

/// the name of `reg`, or its offset in hex when it has none
fn regName(reg: Offset, buf: *[8]u8) []const u8 {
    return std.enums.tagName(Offset, reg) orelse
        std.fmt.bufPrint(buf, "0x{x}", .{@intFromEnum(reg)}) catch unreachable;
}

/// `len` bytes of the config space from `offset` (relative to `config_offset`), little endian.
/// the config space of virtio-net starts with the MAC, nothing else is offered.
fn readConfig(dev: *Device, offset: u64, len: u8) u32 {
    var val: u32 = 0;
    for (0..@min(len, 4)) |i| {
        const byte: u32 = if (offset + i < dev.mac.len) dev.mac[offset + i] else 0;
        val |= byte << @intCast(8 * i);
    }
    return val;
}

fn read(dev: *Device, reg: Offset) u32 {
    return switch (reg) {
        .magic_value => magic,
        .version => interface_version,
        .device_id => @intFromEnum(dev.device_id),
        .vendor_id => vendor,
        .device_features => featuresHalf(dev.device_features, dev.device_features_sel),
        .status => @bitCast(dev.status),
        // no queue exists yet, 0 tells the driver that the selected queue is unavailable
        .queue_num_max, .queue_ready => 0,
        .interrupt_status, .config_generation => 0,
        // write-only registers
        .device_features_sel,
        .driver_features,
        .driver_features_sel,
        .queue_sel,
        .queue_num,
        .queue_notify,
        .interrupt_ack,
        .queue_desc_low,
        .queue_desc_high,
        .queue_driver_low,
        .queue_driver_high,
        .queue_device_low,
        .queue_device_high,
        => 0,
        // the config space is served by `readConfig`
        _ => unknownAccess(reg),
    };
}

fn write(dev: *Device, reg: Offset, val: u32) void {
    switch (reg) {
        .device_features_sel => dev.device_features_sel = val,
        .driver_features_sel => dev.driver_features_sel = val,
        .driver_features => {
            const shift: u6 = if (dev.driver_features_sel == 0) 0 else 32;
            const mask = @as(u64, 0xffff_ffff) << shift;
            dev.driver_features = (dev.driver_features & ~mask) | (@as(u64, val) << shift);
        },
        .queue_sel => dev.queue_sel = val,
        .status => writeStatus(dev, val),
        // queues are set up in a later step
        .queue_num,
        .queue_ready,
        .queue_notify,
        .interrupt_ack,
        .queue_desc_low,
        .queue_desc_high,
        .queue_driver_low,
        .queue_driver_high,
        .queue_device_low,
        .queue_device_high,
        => {},
        // read-only registers
        .magic_value,
        .version,
        .device_id,
        .vendor_id,
        .device_features,
        .queue_num_max,
        .interrupt_status,
        .config_generation,
        => {},
        _ => _ = unknownAccess(reg),
    }
}

/// what a load from `reg` returns, a store is ignored
fn unknownAccess(reg: Offset) u32 {
    if (@intFromEnum(reg) < config_offset)
        std.log.warn("virtio-mmio: access to the unknown register 0x{x}\n", .{@intFromEnum(reg)});
    return 0;
}

/// the half of `features` that `sel` (0 or 1) picks
fn featuresHalf(features: u64, sel: u32) u32 {
    return switch (sel) {
        0 => @truncate(features),
        1 => @truncate(features >> 32),
        else => 0,
    };
}

fn writeStatus(dev: *Device, val: u32) void {
    if (val == 0) {
        std.log.info("virtio-mmio: device reset\n", .{});
        dev.reset();
        return;
    }

    var new: VirtioStatus = @bitCast(val);
    // the driver may only accept what the device offered
    if (new.feat_ok and (dev.driver_features & ~dev.device_features) != 0) {
        std.log.warn("virtio-mmio: driver accepted features 0x{x} the device doesn't offer\n", .{dev.driver_features});
        new.feat_ok = false;
    }
    // virtio 1.0+ requires VERSION_1
    if (new.feat_ok and (dev.driver_features & f_version_1) == 0) {
        std.log.warn("virtio-mmio: driver didn't accept VERSION_1\n", .{});
        new.feat_ok = false;
    }

    const old = dev.status;
    dev.status = new;
    if (new.ack and !old.ack) std.log.info("virtio-mmio: driver ACKNOWLEDGE\n", .{});
    if (new.driver and !old.driver) std.log.info("virtio-mmio: driver DRIVER\n", .{});
    if (new.feat_ok and !old.feat_ok) std.log.info("virtio-mmio: driver FEATURES_OK, features 0x{x}\n", .{dev.driver_features});
    if (new.driver_ok and !old.driver_ok) std.log.info("virtio-mmio: driver DRIVER_OK\n", .{});
    if (new.failed and !old.failed) std.log.info("virtio-mmio: driver FAILED\n", .{});
}
