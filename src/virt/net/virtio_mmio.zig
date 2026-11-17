//! virtio-mmio transport (version 2, "modern"), the register block of one device.
//! ref: https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html (section 4.2)
//!
//! the guest finds it through `virtio_mmio.device=4K@<base>:<irq>` on its cmdline.
const std = @import("std");
const debug = @import("../../debug.zig");
const Vcpu = @import("../vcpu.zig").Vcpu;
const ept = @import("../ept.zig");
const vmread = @import("../vmx.zig").vmread;
const vmwrite = @import("../vmx.zig").vmwrite;
const instr_decoder = @import("../instr_decoder.zig");
const virtqueue = @import("virtqueue.zig");
const Queue = virtqueue.Queue;
const virtio = @import("virtio.zig");
const NetDevice = virtio.NetDevice;
const VirtioStatus = virtio.VirtioStatus;

pub const base = 0xd0000000;
pub const size = 0x1000;
/// the IRQ given on the guest's cmdline
pub const irq = 5;

/// the MAC address of the guest's NIC. locally administered (bit 1 of the first byte)
pub const guest_mac: [6]u8 = .{ 0x52, 0x54, 0x00, 0x14, 0x41, 0x44 };

/// "virt", little endian
const magic: u32 = 0x74726976;
/// 1 is the legacy interface, 2 the one of virtio 1.0 and later
const interface_version: u32 = 2;
/// "NOAM", little endian
const vendor: u32 = 0x4d414f4e;

/// the registers, by their offset from `base`
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
    /// unknown registers, and the config space from `config_offset`
    _,
};

/// the device specific config space starts here
const config_offset = 0x100;

pub fn eptViolation(vcpu: *Vcpu, violating_addr: ept.GuestPhys) error{Aborted}!void {
    const old_logging = debug.logging_enabled;
    defer debug.logging_enabled = old_logging;
    debug.logging_enabled = true;

    const instr = instr_decoder.decodeGuestRip(vcpu) catch |err| {
        const rip = vmread(.GUEST_RIP);
        const bytes = ept.readGuestVirt([instr_decoder.max_len]u8, vcpu.vm, vmread(.GUEST_CR3), rip) catch return error.Aborted;
        return vcpu.abortMsg("can't decode the instruction behind an EPT violation: {s}\ninstr bytes: {any}\n", .{ @errorName(err), bytes[0..] });
    };
    defer vmwrite(.GUEST_RIP, vmread(.GUEST_RIP) +% instr.len);

    const dev = &vcpu.vm.virtio_net;
    const offset: u12 = @intCast(violating_addr - base);
    const reg: Offset = @enumFromInt(offset);
    const known = std.enums.tagName(Offset, reg);
    if (known == null and offset < config_offset)
        std.log.warn("virtio-mmio: access to the unknown register 0x{x}\n", .{offset});
    var name_buf: [8]u8 = undefined;
    const name = known orelse std.fmt.bufPrint(&name_buf, "0x{x}", .{offset}) catch unreachable;

    switch (instr.kind) {
        .load => {
            const val = if (offset >= config_offset)
                readConfig(dev, offset - config_offset, instr.size)
            else
                read(dev, reg);
            std.log.info("virtio-mmio LOAD @ {s} = 0x{x}\n", .{ name, val });
            instr.write(vcpu, val);
        },
        .store_imm, .store_reg => {
            const val = instr.read(vcpu);
            std.log.info("virtio-mmio STORE @ {s} = 0x{x}\n", .{ name, val });
            try write(vcpu, dev, reg, val);
        },
    }
}

/// `len` bytes of the config space from `offset`, little endian.
/// virtio-net's config space starts with the MAC, and we offer nothing after it
fn readConfig(dev: *const NetDevice, offset: u64, len: u8) u32 {
    var val: u32 = 0;
    for (0..@min(len, 4)) |i| {
        const byte: u32 = if (offset + i < dev.mac.len) dev.mac[offset + i] else 0;
        val |= byte << @intCast(8 * i);
    }
    return val;
}

fn read(dev: *NetDevice, reg: Offset) u32 {
    return switch (reg) {
        .magic_value => magic,
        .version => interface_version,
        .device_id => @intFromEnum(NetDevice.device_id),
        .vendor_id => vendor,
        .device_features => half(NetDevice.features, dev.device_features_sel),
        .queue_num_max => Queue.max_size,
        .queue_ready => @intFromBool(dev.selected().ready),
        .interrupt_status => dev.interrupt_status,
        .status => @bitCast(dev.status),
        // write-only, the config generation (never changes) and unknown registers
        else => 0,
    };
}

fn write(vcpu: *Vcpu, dev: *NetDevice, reg: Offset, val: u32) error{Aborted}!void {
    switch (reg) {
        .device_features_sel => dev.device_features_sel = val,
        .driver_features_sel => dev.driver_features_sel = val,
        .driver_features => setHalf(&dev.driver_features, dev.driver_features_sel, val),
        .queue_sel => {
            if (val >= virtqueue.queue_count)
                return vcpu.abortMsg("virtio-net: queue_sel {d} out of range\n", .{val});
            dev.queue_sel = val;
        },
        .queue_num => {
            if (val == 0 or val > Queue.max_size or !std.math.isPowerOfTwo(val))
                return vcpu.abortMsg("virtio-net: bad queue size {d}\n", .{val});
            dev.selected().size = @intCast(val);
        },
        .queue_desc_low => setHalf(&dev.selected().desc_gpa, 0, val),
        .queue_desc_high => setHalf(&dev.selected().desc_gpa, 1, val),
        .queue_driver_low => setHalf(&dev.selected().avail_gpa, 0, val),
        .queue_driver_high => setHalf(&dev.selected().avail_gpa, 1, val),
        .queue_device_low => setHalf(&dev.selected().used_gpa, 0, val),
        .queue_device_high => setHalf(&dev.selected().used_gpa, 1, val),
        .queue_ready => {
            const q = dev.selected();
            q.ready = val == 1;
            if (!q.ready) return;
            if (!q.isAligned())
                return vcpu.abortMsg("virtio-net: queue {d} rings misaligned\n", .{dev.queue_sel});
            std.log.info("queue {d}: size={d} desc=0x{x} avail=0x{x} used=0x{x}", .{ dev.queue_sel, q.size, q.desc_gpa, q.avail_gpa, q.used_gpa });
        },
        .queue_notify => try dev.notify(vcpu, val),
        // the driver acknowledges the bits it read from InterruptStatus
        .interrupt_ack => dev.interrupt_status &= ~val,
        .status => writeStatus(dev, val),
        // read-only and unknown registers
        else => {},
    }
}

fn writeStatus(dev: *NetDevice, val: u32) void {
    if (val == 0) {
        std.log.info("virtio-mmio: device reset\n", .{});
        return dev.reset();
    }

    var new: VirtioStatus = @bitCast(val);
    // the driver may only accept what the device offers, and virtio 1.0+ needs VERSION_1
    const accepted = dev.driver_features;
    if (new.feat_ok and (accepted & ~NetDevice.features != 0 or accepted & virtio.f_version_1 == 0)) {
        std.log.warn("virtio-mmio: refusing the driver's features 0x{x}\n", .{accepted});
        new.feat_ok = false;
    }

    const old = dev.status;
    dev.status = new;
    inline for (.{ "ack", "driver", "feat_ok", "driver_ok", "failed" }) |bit| {
        if (@field(new, bit) and !@field(old, bit))
            std.log.info("virtio-mmio: driver set " ++ bit ++ ", features 0x{x}\n", .{accepted});
    }
}

/// the 32-bit half `sel` (0 low, 1 high) of `v`
fn half(v: u64, sel: u32) u32 {
    return switch (sel) {
        0 => @truncate(v),
        1 => @truncate(v >> 32),
        else => 0,
    };
}

/// sets the 32-bit half `sel` (0 low, 1 high) of `field` to `val`
fn setHalf(field: *u64, sel: u32, val: u32) void {
    switch (sel) {
        0 => field.* = (field.* & 0xffff_ffff_0000_0000) | val,
        1 => field.* = (field.* & 0x0000_0000_ffff_ffff) | (@as(u64, val) << 32),
        else => {},
    }
}
