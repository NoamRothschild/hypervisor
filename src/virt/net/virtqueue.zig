pub const queue_count = 2;

pub const Queue = struct {
    num: u16 = 0, // QueueNum
    ready: bool = false,
    desc_gpa: u64 = 0, // QueueDesc  (low | high << 32)
    avail_gpa: u64 = 0, // QueueDriver
    used_gpa: u64 = 0, // QueueDevice
    last_avail: u16 = 0, // how far we've consumed the avail ring (see below)
};
