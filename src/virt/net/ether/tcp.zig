//! TCP headers (RFC 9293)
const builtin = @import("builtin");
const eth = @import("../ethernet.zig");
const Be = eth.Be;

/// the fixed part of a TCP header. options may follow it, see `headerLen`
pub const Tcp = extern struct {
    src_port: Be(u16),
    dst_port: Be(u16),
    seq: Be(u32),
    ack: Be(u32),
    /// header length and flags, cast straight from the wire bytes, see `OffFlags`
    off_flags: OffFlags align(1),
    window: Be(u16),
    checksum: Be(u16),
    urgent: Be(u16),

    /// Assumes host cpu is little-endian and network order is big-endian
    pub const OffFlags = packed struct(u16) {
        // byte 12
        ns: bool,
        reserved: u3,
        /// header length in 32-bit words, options included
        data_off: u4,
        // byte 13
        fin: bool,
        syn: bool,
        rst: bool,
        psh: bool,
        ack: bool,
        urg: bool,
        ece: bool,
        cwr: bool,
    };

    /// in bytes, options included
    pub fn headerLen(self: *const Tcp) usize {
        return @as(usize, self.off_flags.data_off) * 4;
    }
};

comptime {
    if (@sizeOf(Tcp) != 20) @compileError("Tcp must be 20 bytes");
    if (builtin.cpu.arch.endian() != .little) @compileError("Tcp.OffFlags assumes a little-endian host");
}
