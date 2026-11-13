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

    pub fn setLow(field: *u64, v: u32) void {
        field.* = (field.* & ~@as(u64, 0xffff_ffff)) | v;
    }

    pub fn setHigh(field: *u64, v: u32) void {
        field.* = (field.* & 0xffff_ffff) | (@as(u64, v) << 32);
    }
};
