const std = @import("std");

// the protocols big enough for a file of their own, under ether/
pub const arp = @import("ether/arp.zig");
pub const ipv4 = @import("ether/ipv4.zig");
pub const tcp = @import("ether/tcp.zig");
pub const dhcp = @import("ether/dhcp.zig");

pub const Arp = arp.Arp;
pub const ArpOp = arp.Op;
pub const Ipv4 = ipv4.Ipv4;
pub const IpProto = ipv4.Proto;
pub const Tcp = tcp.Tcp;
pub const Dhcp = dhcp.Dhcp;

pub const Mac = [6]u8;
pub const Ip = [4]u8;

pub const broadcast: Mac = @splat(0xff);

/// the payload of a frame without a VLAN tag
pub const mtu = 1500;
/// dst, src and ethertype
pub const header_len = 14;

/// a big-endian `T`, an integer or an enum with an integer tag
pub fn Be(comptime T: type) type {
    const is_enum = @typeInfo(T) == .@"enum";
    const Int = if (is_enum) @typeInfo(T).@"enum".tag_type else T;

    return extern struct {
        bytes: [@sizeOf(Int)]u8,

        const Self = @This();

        pub fn of(v: T) Self {
            var self: Self = undefined;
            self.set(v);
            return self;
        }

        pub fn get(self: *const Self) T {
            const v = std.mem.readInt(Int, &self.bytes, .big);
            return if (is_enum) @enumFromInt(v) else v;
        }

        pub fn set(self: *Self, v: T) void {
            std.mem.writeInt(Int, &self.bytes, if (is_enum) @intFromEnum(v) else v, .big);
        }

        pub fn eql(self: *const Self, other: *const Self) bool {
            return std.mem.eql(u8, self.bytes[0..], other.bytes[0..]);
        }
    };
}

pub const EtherType = enum(u16) {
    ipv4 = 0x0800,
    arp = 0x0806,
    ipv6 = 0x86dd,
    _,
};

pub const Frame = extern struct {
    dst: Mac,
    src: Mac,
    ethertype: Be(EtherType),
    payload: extern union {
        arp: Arp,
        ipv4: Ipv4,
        raw: [mtu]u8,
    },
};

/// the header after an IPv4 header, pick the arm by `Ipv4.proto`
pub const L4 = extern union {
    icmp: Icmp,
    udp: Udp,
    tcp: Tcp,
};

pub const IcmpType = enum(u8) {
    echo_reply = 0,
    dest_unreachable = 3,
    echo_request = 8,
    time_exceeded = 11,
    _,
};

/// an ICMP header, `id` and `seq` as in echo request and reply
pub const Icmp = extern struct {
    type: IcmpType,
    code: u8,
    /// RFC 1071 checksum of the ICMP header and its data
    checksum: Be(u16),
    id: Be(u16),
    seq: Be(u16),
};

pub const Udp = extern struct {
    src_port: Be(u16),
    dst_port: Be(u16),
    /// header + data
    len: Be(u16),
    checksum: Be(u16),

    /// the DHCP message after the header, see `dhcp.fits`. `@constCast` it to modify it
    pub fn dhcp(self: *const Udp) *const Dhcp {
        const bytes: [*]const u8 = @ptrCast(self);
        return @ptrCast(bytes + @sizeOf(Udp));
    }
};

/// true if `frame` is long enough for a `T` (`Arp` or `Ipv4`) after the Ethernet header
pub fn fits(frame: []const u8, comptime T: type) bool {
    return frame.len >= header_len + @sizeOf(T);
}

/// true if `frame`, which holds an IPv4 packet that `fits`, is long enough for
/// a `T` (`Icmp`, `Udp` or `Tcp`) after the IPv4 header and its options
pub fn fitsL4(frame: []const u8, comptime T: type) bool {
    const ip: *const Ipv4 = @ptrCast(frame[header_len..].ptr);
    return frame.len >= header_len + ip.headerLen() + @sizeOf(T);
}

/// RFC 1071: the one's complement of the one's complement sum of 16-bit words
pub fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) sum += std.mem.readInt(u16, data[i..][0..2], .big);
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

comptime {
    std.debug.assert(@offsetOf(Frame, "payload") == header_len);
    std.debug.assert(@sizeOf(Frame) == header_len + mtu);
    std.debug.assert(@sizeOf(Icmp) == 8);
    std.debug.assert(@sizeOf(Udp) == 8);
    std.debug.assert(@alignOf(Frame) == 1);
    std.debug.assert(@alignOf(L4) == 1);
}
