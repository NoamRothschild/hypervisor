//! Split virtqueues: the rings the driver and the device share in guest RAM.
//! ref: virtio 1.2, section 2.7
//!
//!   desc   Desc[size]                               (align 16)
//!   avail  flags: u16, idx: u16, ring: [size]u16    (align 2, written by the driver)
//!   used   flags: u16, idx: u16, ring: [size]Used   (align 4, written by the device)
const ept = @import("../ept.zig");
const VMState = @import("../vmx.zig").VMState;

pub const queue_count = 2;

/// VIRTQ_AVAIL_F_NO_INTERRUPT, in the avail ring's `flags`
const avail_no_interrupt: u16 = 1 << 0;
/// `idx` of the avail and used rings, after `flags`
const idx_offset = 2;
/// `ring` of the avail and used rings, after `flags` and `idx`
const ring_offset = 4;

/// a buffer in guest RAM, linked into a chain with `next`
pub const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: Flags,
    next: u16,

    pub const Flags = packed struct(u16) {
        /// `next` continues the chain
        next: bool,
        /// the device writes the buffer (RX), otherwise it only reads it (TX)
        write: bool,
        indirect: bool,
        reserved: u13,
    };
};

/// an element of the used ring: which chain the device is done with
const Used = extern struct {
    head: u32,
    /// how many bytes the device wrote into the chain
    len: u32,
};

pub const Queue = struct {
    pub const max_size = 256;

    /// QueueNum
    size: u16 = 0,
    /// QueueReady
    ready: bool = false,
    /// QueueDesc, QueueDriver and QueueDevice
    desc_gpa: u64 = 0,
    avail_gpa: u64 = 0,
    used_gpa: u64 = 0,
    /// the avail ring's `idx` we consumed up to
    last_avail: u16 = 0,
    /// the used ring's `idx` we published
    next_used: u16 = 0,

    pub fn isAligned(self: *const Queue) bool {
        return self.desc_gpa % 16 == 0 and self.avail_gpa % 2 == 0 and self.used_gpa % 4 == 0;
    }

    /// the head of the next chain the driver made available, null if there is none
    pub fn pop(self: *Queue, vm: *VMState) !?u16 {
        const avail_idx = @atomicLoad(u16, try ept.guestPtr(u16, vm, self.avail_gpa + idx_offset), .acquire);
        if (avail_idx == self.last_avail) return null;
        if (avail_idx -% self.last_avail > self.size) return error.BadAvailIndex;

        const head = try ept.readGuestPhys(u16, vm, self.availSlot(self.last_avail));
        if (head >= self.size) return error.BadDescriptor;
        self.last_avail +%= 1;
        return head;
    }

    /// gives chain `head` back to the driver, `written` bytes of it filled
    pub fn push(self: *Queue, vm: *VMState, head: u16, written: u32) !void {
        (try ept.guestPtr(Used, vm, self.usedSlot(self.next_used))).* = .{ .head = head, .len = written };
        self.next_used +%= 1;
        @atomicStore(u16, try ept.guestPtr(u16, vm, self.used_gpa + idx_offset), self.next_used, .release);
    }

    pub fn chain(self: *const Queue, vm: *VMState, head: u16) Chain {
        return .{ .q = self, .vm = vm, .next_idx = head };
    }

    /// false if the driver turned interrupts off for this queue. only a hint,
    /// so an avail ring we can't read wants them
    pub fn wantsInterrupt(self: *const Queue, vm: *VMState) bool {
        const flags = ept.readGuestPhys(u16, vm, self.avail_gpa) catch return true;
        return flags & avail_no_interrupt == 0;
    }

    fn availSlot(self: *const Queue, idx: u16) u64 {
        return self.avail_gpa + ring_offset + @sizeOf(u16) * @as(u64, idx % self.size);
    }

    fn usedSlot(self: *const Queue, idx: u16) u64 {
        return self.used_gpa + ring_offset + @sizeOf(Used) * @as(u64, idx % self.size);
    }

    fn descAt(self: *const Queue, i: u16) u64 {
        return self.desc_gpa + @sizeOf(Desc) * @as(u64, i);
    }
};

/// walks the descriptors of one chain
pub const Chain = struct {
    q: *const Queue,
    vm: *VMState,
    next_idx: ?u16,
    /// descriptors seen so far, a chain longer than the queue loops
    hops: u16 = 0,

    pub fn next(self: *Chain) !?Desc {
        const i = self.next_idx orelse return null;
        if (self.hops == self.q.size) return error.DescriptorLoop;
        self.hops += 1;

        const d = try ept.readGuestPhys(Desc, self.vm, self.q.descAt(i));
        if (d.flags.indirect) return error.UnexpectedIndirect;
        if (d.flags.next and d.next >= self.q.size) return error.BadDescriptor;
        self.next_idx = if (d.flags.next) d.next else null;
        return d;
    }

    /// copies the whole chain into `dst` (TX). returns the part of `dst` it filled
    pub fn read(self: *Chain, dst: []u8) ![]u8 {
        var n: usize = 0;
        while (try self.next()) |d| {
            if (d.flags.write) return error.WritableDescriptor;
            if (d.len > dst.len - n) return error.ChainTooLong;
            try ept.readGuestBytes(self.vm, dst[n..][0..d.len], d.addr);
            n += d.len;
        }
        return dst[0..n];
    }

    /// copies `src` into the chain's buffers (RX). stops early at the end of the
    /// chain or at a bad descriptor. returns how many bytes it copied
    pub fn write(self: *Chain, src: []const u8) u32 {
        var n: usize = 0;
        while (n < src.len) {
            const d = (self.next() catch null) orelse break;
            if (!d.flags.write) break;
            const len = @min(d.len, src.len - n);
            ept.writeGuest(self.vm, src[n..][0..len], d.addr) catch break;
            n += len;
        }
        return @intCast(n);
    }
};
