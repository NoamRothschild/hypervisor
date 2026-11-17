//! ARP for IPv4 over Ethernet (RFC 826): "who has this IP? tell me your MAC"
const eth = @import("../ethernet.zig");
const Be = eth.Be;
const Mac = eth.Mac;
const Ip = eth.Ip;

pub const Op = enum(u16) {
    request = 1,
    reply = 2,
    _,
};

pub const Arp = extern struct {
    /// 1 for Ethernet
    htype: Be(u16),
    /// `EtherType.ipv4`
    ptype: Be(eth.EtherType),
    /// 6, the length of a MAC
    hlen: u8,
    /// 4, the length of an IPv4 address
    plen: u8,
    oper: Be(Op),
    /// sender MAC and IP
    sha: Mac,
    spa: Ip,
    /// target MAC and IP. `tha` is zero in a request
    tha: Mac,
    tpa: Ip,
};

comptime {
    if (@sizeOf(Arp) != 28) @compileError("Arp must be 28 bytes");
}
