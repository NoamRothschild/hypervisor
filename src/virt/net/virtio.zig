const std = @import("std");
const debug = @import("../../debug.zig");
const VMState = @import("../vmx.zig").VMState;
const Vcpu = @import("../vcpu.zig").Vcpu;
const virtio_mmio = @import("virtio_mmio.zig");
const ept = @import("../ept.zig");
const virtqueue = @import("virtqueue.zig");
const Queue = @import("virtqueue.zig").Queue;

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

/// feature bit 32, the device follows virtio 1.0 and later. required by `interface_version` 2.
pub const f_version_1: u64 = 1 << 32;
/// VIRTIO_NET_F_MAC, feature bit 5: the device has a MAC address in its config space
pub const f_net_mac: u64 = 1 << 5;

/// InterruptStatus bit 0: the device put buffers in a used ring
const int_used_buffer: u32 = 1 << 0;
/// VIRTQ_AVAIL_F_NO_INTERRUPT, in the avail ring's `flags`: the driver doesn't want
/// an interrupt when this queue gets used buffers
const avail_f_no_interrupt: u16 = 1 << 0;

/// the state of one virtio-mmio device, shared by every vcpu of the guest
pub const NetDevice = struct {
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
    queues: [virtqueue.queue_count]Queue,
    /// the queue the `queue_*` registers refer to
    queue_sel: u32,
    /// what InterruptStatus reads, the reasons for interrupts the driver hasn't acknowledged yet
    interrupt_status: u32,

    pub fn init(device_id: DeviceID, mac: [6]u8) NetDevice {
        return .{
            .device_id = device_id,
            .mac = mac,
            .status = .{},
            .device_features = f_version_1 | f_net_mac,
            .driver_features = 0,
            .device_features_sel = 0,
            .driver_features_sel = 0,
            .queues = .{
                Queue{},
                Queue{},
            },
            .queue_sel = 0,
            .interrupt_status = 0,
        };
    }

    const rx_q = 0;
    const tx_q = 1;

    pub fn notify(self: *NetDevice, vcpu: *Vcpu, queue: u32) error{Aborted}!void {
        switch (queue) {
            rx_q => {},
            tx_q => self.processTx(vcpu) catch |err| {
                if (err == error.Aborted)
                    return error.Aborted;
                return vcpu.abortMsg("processTx failed with: {s}\n", .{@errorName(err)});
            },
            else => {},
        }
    }

    fn processTx(self: *NetDevice, vcpu: *Vcpu) !void {
        const q = &self.queues[tx_q];
        if (!q.ready) return;

        var any: bool = false;
        var buf: [@sizeOf(NetHdr) + max_frame]u8 = undefined;
        while (try q.pop(vcpu.vm)) |head| {
            var n: usize = 0;
            var c = q.chain(vcpu.vm, head);

            while (try c.nextDesc()) |d| {
                if (d.flags & virtqueue.DescEntry.f_write != 0)
                    return vcpu.abortMsg("TX descriptor is device-writable", .{});
                if (d.len > buf.len - n)
                    return vcpu.abortMsg("TX frame too long", .{});

                var guest_chunks = try ept.guestChunks(vcpu.vm, d.addr, d.len);
                while (guest_chunks.next()) |ch| {
                    @memcpy(buf[n..][0..ch.len], ch);
                    n += ch.len;
                }
            }

            try q.push(vcpu.vm, head, 0); // TX: the device wrote nothing
            any = true;
            if (n > @sizeOf(NetHdr))
                self.transmit(buf[@sizeOf(NetHdr)..n]);
        }
        if (any)
            self.interrupt(vcpu.vm, q);
    }

    pub fn transmit(_: *NetDevice, buf: []u8) void {
        if (!debug.logging_enabled)
            return;

        std.log.info("TX pkt (len={d}): ", .{buf.len});
        for (buf, 0..) |byte, i| {
            debug.printf("{x:0>2}", .{byte});
            if (i != buf.len - 1) {
                debug.outb(debug.COM1, ':');
                debug.outb(debug.COM1, ':');
            } else debug.outb(debug.COM1, '\n');
        }
    }

    /// Tells the driver `q` has new used buffers: sets the used buffer bit of
    /// InterruptStatus and raises `irq`, unless the driver turned interrupts off for `q`.
    /// call it once after pushing a batch of used buffers, not after every one.
    pub fn interrupt(self: *NetDevice, vm: *VMState, q: *const Queue) void {
        // the driver may ask for no interrupts (Linux does on TX while it is busy).
        // it is only a hint, so an avail ring we can't read interrupts anyway.
        const avail_flags = ept.readGuestPhys(u16, vm, q.avail_gpa) catch 0;
        if (avail_flags & avail_f_no_interrupt != 0) return;
        self.interrupt_status |= int_used_buffer;
        // the virtual PIC injects it into the BSP once the guest unmasks it and IF is set
        vm.pending_irq |= 1 << virtio_mmio.irq;
        std.log.info("virtio-net irq: avail flags=0x{x} pic mask=0x{x} pending=0x{x}", .{ avail_flags, vm.pic.primary_mask, vm.pending_irq });
    }

    pub fn selectedQueue(self: *NetDevice) *Queue {
        // checks for queue_sel setup must be enfored before.
        // this code assumes the index is valid.
        return &self.queues[self.queue_sel];
    }

    /// writing 0 to `status`
    pub fn reset(self: *NetDevice) void {
        self.* = .init(self.device_id, self.mac);
    }
};

const max_frame = 1514; // 14-byte Ethernet header + 1500 MTU, no FCS

pub const NetHdr = extern struct {
    flags: u8 = 0, // NEEDS_CSUM = 1, DATA_VALID = 2
    gso_type: u8 = 0, // GSO_NONE = 0
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    num_buffers: u16 = 0, // RX: number of chains this packet used

    comptime {
        std.debug.assert(@sizeOf(NetHdr) == 12);
    }
};
