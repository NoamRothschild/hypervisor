//! virtio-net, the device side. the guest reaches it through `virtio_mmio.zig`.
//! ref: virtio 1.2, section 5.1
const std = @import("std");
const debug = @import("../../debug.zig");
const VMState = @import("../vmx.zig").VMState;
const Vcpu = @import("../vcpu.zig").Vcpu;
const virtio_mmio = @import("virtio_mmio.zig");
const virtqueue = @import("virtqueue.zig");
const Queue = virtqueue.Queue;
const responder = @import("responder.zig");
const ethernet = @import("ethernet.zig");

pub const VirtioStatus = packed struct(u32) {
    ack: bool = false, // 0x01
    driver: bool = false, // 0x02
    driver_ok: bool = false, // 0x04
    feat_ok: bool = false, // 0x08
    rsvd: u2 = 0,
    needs_reset: bool = false, // 0x40
    failed: bool = false, // 0x80
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

/// feature bit 32: the device follows virtio 1.0 and later. required by interface version 2
pub const f_version_1: u64 = 1 << 32;
/// VIRTIO_NET_F_MAC, feature bit 5: the device has a MAC address in its config space
pub const f_net_mac: u64 = 1 << 5;

/// InterruptStatus bit 0: the device put buffers in a used ring
const int_used_buffer: u32 = 1 << 0;

/// 14-byte Ethernet header + 1500 MTU, no FCS
pub const max_frame = 1514;

/// what precedes every frame on both queues
pub const NetHdr = extern struct {
    flags: u8 = 0, // NEEDS_CSUM = 1, DATA_VALID = 2
    gso_type: u8 = 0, // GSO_NONE = 0
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    /// RX: how many chains the packet used
    num_buffers: u16 = 0,

    comptime {
        std.debug.assert(@sizeOf(NetHdr) == 12);
    }
};

/// a frame with its `NetHdr`, the way it sits in a chain
const Packet = [@sizeOf(NetHdr) + max_frame]u8;

/// the state of the guest's virtio-net device, shared by all of its vcpus
pub const NetDevice = struct {
    pub const device_id: DeviceID = .network;
    /// what the device offers, the driver accepts a subset in `driver_features`
    pub const features: u64 = f_version_1 | f_net_mac;

    const rx_q = 0;
    const tx_q = 1;

    /// the MAC address in the config space
    mac: [6]u8,
    status: VirtioStatus = .{},
    driver_features: u64 = 0,
    /// which 32-bit half of the features DeviceFeatures and DriverFeatures access
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    queues: [virtqueue.queue_count]Queue = @splat(.{}),
    /// the queue the Queue* registers access
    queue_sel: u32 = 0,
    /// InterruptStatus, the interrupts the driver hasn't acknowledged yet
    interrupt_status: u32 = 0,
    /// frames that arrived while the guest had no RX buffer posted.
    /// on the heap: it is ~48KB and the kernel stack is 40KB
    backlog: *Backlog,
    /// frames dropped because the backlog was full
    rx_dropped: u64 = 0,

    /// empties `backlog`, it may hold garbage
    pub fn init(mac: [6]u8, backlog: *Backlog) NetDevice {
        backlog.clear();
        return .{ .mac = mac, .backlog = backlog };
    }

    /// the driver wrote 0 to Status
    pub fn reset(self: *NetDevice) void {
        self.* = .init(self.mac, self.backlog);
    }

    /// the queue_sel write already checked it is in range
    pub fn selected(self: *NetDevice) *Queue {
        return &self.queues[self.queue_sel];
    }

    /// the driver wrote QueueNotify: `queue` has new buffers
    pub fn notify(self: *NetDevice, vcpu: *Vcpu, queue: u32) error{Aborted}!void {
        switch (queue) {
            rx_q => self.flushBacklog(vcpu),
            tx_q => self.processTx(vcpu) catch |err|
                return vcpu.abortMsg("virtio-net TX: {s}\n", .{@errorName(err)}),
            else => {},
        }
    }

    /// sends every chain the guest queued for TX
    fn processTx(self: *NetDevice, vcpu: *Vcpu) !void {
        const q = &self.queues[tx_q];
        if (!q.ready) return;

        var buf: Packet = undefined;
        var sent_any = false;
        while (try q.pop(vcpu.vm)) |head| {
            var chain = q.chain(vcpu.vm, head);
            const pkt = try chain.read(&buf);
            try q.push(vcpu.vm, head, 0); // the device wrote nothing
            sent_any = true;
            if (pkt.len > @sizeOf(NetHdr))
                self.transmit(vcpu, pkt[@sizeOf(NetHdr)..]);
        }
        if (sent_any) self.interrupt(vcpu.vm, q);
    }

    /// a frame the guest sent. for now the built-in gateway answers it
    fn transmit(self: *NetDevice, vcpu: *Vcpu, frame: []const u8) void {
        logFrame("TX", frame);
        var reply: [max_frame]u8 = undefined;
        if (responder.respond(frame, &reply)) |n|
            self.receive(vcpu, reply[0..n]);
    }

    /// hands a frame to the guest: into an RX buffer, or into the backlog if it
    /// has none posted. drops it if the backlog is full too
    pub fn receive(self: *NetDevice, vcpu: *Vcpu, frame: []const u8) void {
        // only skip the backlog when it is empty, so frames stay in order
        if (self.backlog.isEmpty() and self.deliver(vcpu, frame)) return;
        if (!self.backlog.push(frame)) self.rx_dropped += 1;
    }

    /// delivers backlogged frames, oldest first, until the guest runs out of RX buffers
    fn flushBacklog(self: *NetDevice, vcpu: *Vcpu) void {
        while (self.backlog.peek()) |frame| {
            if (!self.deliver(vcpu, frame)) return;
            self.backlog.drop();
        }
    }

    /// copies `frame` into the next RX chain. false if the guest has none posted
    fn deliver(self: *NetDevice, vcpu: *Vcpu, frame: []const u8) bool {
        const q = &self.queues[rx_q];
        if (!q.ready or !self.status.driver_ok or frame.len > max_frame) return false;
        const head = (q.pop(vcpu.vm) catch return false) orelse return false;

        var buf: Packet = undefined;
        const hdr: NetHdr = .{ .num_buffers = 1 };
        @memcpy(buf[0..@sizeOf(NetHdr)], std.mem.asBytes(&hdr));
        @memcpy(buf[@sizeOf(NetHdr)..][0..frame.len], frame);

        var chain = q.chain(vcpu.vm, head);
        const written = chain.write(buf[0 .. @sizeOf(NetHdr) + frame.len]);
        // push it even if the packet didn't fit, or the driver loses the buffer
        q.push(vcpu.vm, head, written) catch return false;
        self.interrupt(vcpu.vm, q);
        return true;
    }

    /// tells the driver `q` has used buffers, unless it turned interrupts off for `q`.
    /// call it once per batch of pushes, not after every one
    fn interrupt(self: *NetDevice, vm: *VMState, q: *const Queue) void {
        if (!q.wantsInterrupt(vm)) return;
        self.interrupt_status |= int_used_buffer;
        // the virtual PIC injects it into the BSP once the guest unmasks it and sets IF
        vm.pending_irq |= 1 << virtio_mmio.irq;
    }
};

/// prints what `frame` is (e.g. `ARP request 10.0.2.15 -> 10.0.2.2`), then its
/// bytes in hex separated by `::`
fn logFrame(comptime dir: []const u8, frame: []const u8) void {
    if (!debug.logging_enabled) return;
    std.log.info(dir ++ " pkt (len={d}):", .{frame.len});
    describeFrame(frame);
    for (frame, 0..) |byte, i|
        debug.printf("{s}{x:0>2}", .{ if (i == 0) "" else "::", byte });
    debug.printf("\n", .{});
}

/// one line: the protocols in `frame` and their addresses or ports
fn describeFrame(frame: []const u8) void {
    if (frame.len < ethernet.header_len) return debug.printf("runt frame\n", .{});
    const f: *const ethernet.Frame = @ptrCast(frame.ptr);
    switch (f.ethertype.get()) {
        .arp => {
            if (!ethernet.fits(frame, ethernet.Arp)) return debug.printf("ARP, truncated\n", .{});
            const arp = &f.payload.arp;
            debug.printf("ARP {s} {f} -> {f}\n", .{ tagName(arp.oper.get()), fmtIp(arp.spa), fmtIp(arp.tpa) });
        },
        .ipv4 => {
            if (!ethernet.fits(frame, ethernet.Ipv4)) return debug.printf("IPv4, truncated\n", .{});
            const ip = &f.payload.ipv4;
            debug.printf("IPv4 {f} -> {f} {s}", .{ fmtIp(ip.src), fmtIp(ip.dst), tagName(ip.proto) });
            switch (ip.proto) {
                .icmp => if (ethernet.fitsL4(frame, ethernet.Icmp))
                    debug.printf(" {s}", .{tagName(ip.l4().icmp.type)}),
                .udp => if (ethernet.fitsL4(frame, ethernet.Udp))
                    debug.printf(" {d} -> {d}", .{ ip.l4().udp.src_port.get(), ip.l4().udp.dst_port.get() }),
                .tcp => if (ethernet.fitsL4(frame, ethernet.Tcp))
                    debug.printf(" {d} -> {d}", .{ ip.l4().tcp.src_port.get(), ip.l4().tcp.dst_port.get() }),
                _ => {},
            }
            debug.printf("\n", .{});
        },
        else => |t| debug.printf("ethertype {s} (0x{x:0>4})\n", .{ tagName(t), @intFromEnum(t) }),
    }
}

/// the name of `e`, or "?" for a value the enum doesn't name
fn tagName(e: anytype) []const u8 {
    return std.enums.tagName(@TypeOf(e), e) orelse "?";
}

fn fmtIp(ip: ethernet.Ip) std.fmt.Alt(ethernet.Ip, formatIp) {
    return .{ .data = ip };
}

fn formatIp(ip: ethernet.Ip, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
}

/// a FIFO of frames waiting for the guest to post RX buffers
pub const Backlog = struct {
    pub const depth = 32;

    frames: [depth][max_frame]u8,
    lens: [depth]u16,
    /// index of the oldest frame
    head: usize,
    len: usize,

    pub fn clear(self: *Backlog) void {
        self.head = 0;
        self.len = 0;
    }

    fn isEmpty(self: *const Backlog) bool {
        return self.len == 0;
    }

    /// copies `frame` in at the back. false if the backlog is full or the frame too long
    fn push(self: *Backlog, frame: []const u8) bool {
        if (self.len == depth or frame.len > max_frame) return false;
        const i = (self.head + self.len) % depth;
        @memcpy(self.frames[i][0..frame.len], frame);
        self.lens[i] = @intCast(frame.len);
        self.len += 1;
        return true;
    }

    /// the oldest frame. it stays in the backlog until `drop`
    fn peek(self: *const Backlog) ?[]const u8 {
        if (self.len == 0) return null;
        return self.frames[self.head][0..self.lens[self.head]];
    }

    /// removes the oldest frame
    fn drop(self: *Backlog) void {
        self.head = (self.head + 1) % depth;
        self.len -= 1;
    }
};
