//! IPv4 headers (RFC 791)
const eth = @import("../ethernet.zig");
const Be = eth.Be;
const Ip = eth.Ip;
const L4 = eth.L4;

/// what `Ipv4.proto` says follows the header
pub const Proto = enum(u8) {
    icmp = 1,
    tcp = 6,
    udp = 17,
    _,
};

/// the fixed part of an IPv4 header. options may follow it, see `headerLen`
pub const Ipv4 = extern struct {
    /// version in the high nibble, header length in 32-bit words in the low one
    ver_ihl: u8,
    tos: u8,
    /// header + payload, without the Ethernet header
    total_len: Be(u16),
    id: Be(u16),
    /// flags in the top 3 bits, fragment offset in 8-byte units in the rest
    flags_frag: Be(u16),
    ttl: u8,
    proto: Proto,
    /// RFC 1071 checksum of the header
    checksum: Be(u16),
    src: Ip,
    dst: Ip,

    pub fn version(self: *const Ipv4) u4 {
        return @intCast(self.ver_ihl >> 4);
    }

    /// in bytes, options included. at least 20 in a valid header
    pub fn headerLen(self: *const Ipv4) usize {
        return @as(usize, self.ver_ihl & 0x0f) * 4;
    }

    /// the transport header, after the options. `@constCast` it to modify it
    pub fn l4(self: *const Ipv4) *const L4 {
        const bytes: [*]const u8 = @ptrCast(self);
        return @ptrCast(bytes + self.headerLen());
    }
};

comptime {
    if (@sizeOf(Ipv4) != 20) @compileError("Ipv4 must be 20 bytes");
}
