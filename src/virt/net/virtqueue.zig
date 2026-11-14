const ept = @import("../ept.zig");
const VMState = @import("../vmx.zig").VMState;
const Vcpu = @import("../vcpu.zig").Vcpu;
pub const queue_count = 2;

pub const Queue = struct {
    pub const max_size = 256;

    size: u16 = 0, // QueueNum
    ready: bool = false,
    desc_gpa: u64 = 0, // QueueDesc  (low | high << 32)
    avail_gpa: u64 = 0, // QueueDriver
    used_gpa: u64 = 0, // QueueDevice
    last_avail: u16 = 0, // how far we've consumed the avail ring (see below)
    next_used: u16 = 0,

    pub inline fn validate(self: *Queue, vcpu: *Vcpu) !void {
        if (self.desc_gpa % 16 != 0 or self.avail_gpa % 2 != 0 or self.used_gpa % 4 != 0)
            return vcpu.abortMsg("virtio-net queue params misaligned\n", .{});
    }

    /// the head of the next chain the guest made available, or null if there is none
    pub fn pop(self: *Queue, vm: *VMState) !?u16 {
        const avail_idx = @atomicLoad(u16, try ept.guestPtr(u16, vm, self.avail_gpa + 2), .acquire);
        if (avail_idx == self.last_avail) return null;
        if (avail_idx -% self.last_avail > self.size) return error.BadAvailIndex;

        const slot = self.last_avail % self.size;
        const head = try ept.readGuestPhys(u16, vm, self.avail_gpa + 4 + 2 * @as(u64, slot));
        if (head >= self.size) return error.BadDescriptor;
        self.last_avail +%= 1;
        return head;
    }

    /// gives chain `head` back to the guest, reporting `written` bytes
    pub fn push(self: *Queue, vm: *VMState, head: u16, written: u32) !void {
        const slot = self.next_used % self.size;
        const elem = self.used_gpa + 4 + 8 * @as(u64, slot);

        (try ept.guestPtr(u32, vm, elem)).* = head;
        (try ept.guestPtr(u32, vm, elem + 4)).* = written;
        self.next_used +%= 1;
        @atomicStore(u16, try ept.guestPtr(u16, vm, self.used_gpa + 2), self.next_used, .release);
    }

    pub fn chain(self: *const Queue, vm: *VMState, head: u16) Chain {
        return .{ .q = self, .vm = vm, .next = head };
    }

    pub fn setLow(field: *u64, v: u32) void {
        field.* = (field.* & ~@as(u64, 0xffff_ffff)) | v;
    }

    pub fn setHigh(field: *u64, v: u32) void {
        field.* = (field.* & 0xffff_ffff) | (@as(u64, v) << 32);
    }
};

pub const Chain = struct {
    q: *const Queue,
    vm: *VMState,
    next: ?u16,
    hops: u16 = 0,

    pub fn nextDesc(self: *Chain) !?DescEntry {
        const i = self.next orelse return null;
        if (self.hops == self.q.size) return error.DescriptorLoop;
        self.hops += 1;
        const d = try ept.readGuestPhys(DescEntry, self.vm, self.q.desc_gpa + 16 * @as(u64, i));
        if (d.flags & DescEntry.f_indirect != 0) return error.UnexpectedIndirect;
        if (d.flags & DescEntry.f_next != 0) {
            if (d.next >= self.q.size) return error.BadDescriptor;
            self.next = d.next;
        } else self.next = null;
        return d;
    }
};

/// An entry inside the descriptor ring
pub const DescEntry = packed struct {
    pub const f_next: u16 = 1;
    pub const f_write: u16 = 2;
    pub const f_indirect: u16 = 4;

    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

/// An entry inside the avail ring
pub const AvailEntry = packed struct {
    flags: u16,
    idx: u16,
    ring_first: u16,

    pub fn ring(self: *AvailEntry) [*]u16 {
        return @ptrCast(&self.ring_first);
    }
};
