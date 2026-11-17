//! A fake gateway at 10.0.2.2 that answers ARP requests and pings, to test RX
//! before there is a switch and a NIC to deliver real frames.
//!
//! a reply is the request edited in place: copied to `out`, then the fields
//! that differ are rewritten.
const std = @import("std");
const ethernet = @import("ethernet.zig");
const Frame = ethernet.Frame;
const Mac = ethernet.Mac;
const Ip = ethernet.Ip;

const gw_mac: Mac = .{ 0x52, 0x55, 0x0a, 0x00, 0x02, 0x02 }; // what QEMU's slirp uses
const gw_ip: Ip = .{ 10, 0, 2, 2 };

/// writes a reply to `in` into `out`. returns its length, or null if `in` is not for us
pub fn respond(in: []const u8, out: []u8) ?usize {
    if (in.len < ethernet.header_len or in.len > out.len) return null;
    const pkt = out[0..in.len];
    @memcpy(pkt, in);

    const f: *Frame = @ptrCast(pkt.ptr);
    const len = switch (f.ethertype.get()) {
        .arp => arpReply(pkt, f),
        .ipv4 => echoReply(pkt, f),
        else => null,
    } orelse return null;

    // back to whoever sent it, from us
    f.dst = f.src;
    f.src = gw_mac;
    return len;
}

/// answers "who has 10.0.2.2" with `gw_mac`
fn arpReply(pkt: []const u8, f: *Frame) ?usize {
    if (!ethernet.fits(pkt, ethernet.Arp)) return null;
    const arp = &f.payload.arp;
    if (arp.oper.get() != .request or !std.mem.eql(u8, &arp.tpa, &gw_ip)) return null;

    arp.oper.set(.reply);
    arp.tha = arp.sha; // to the asker
    arp.tpa = arp.spa;
    arp.sha = gw_mac; // from us
    arp.spa = gw_ip;
    return ethernet.header_len + @sizeOf(ethernet.Arp);
}

/// turns an ICMP echo request to 10.0.2.2 into an echo reply
fn echoReply(pkt: []const u8, f: *Frame) ?usize {
    if (!ethernet.fits(pkt, ethernet.Ipv4)) return null;
    const ip = &f.payload.ipv4;
    if (ip.proto != .icmp or !std.mem.eql(u8, &ip.dst, &gw_ip)) return null;
    if (ip.headerLen() < @sizeOf(ethernet.Ipv4) or !ethernet.fitsL4(pkt, ethernet.Icmp)) return null;

    // `pkt` may carry Ethernet padding after the IP packet
    const icmp_start = ethernet.header_len + ip.headerLen();
    const end = ethernet.header_len + @as(usize, ip.total_len.get());
    if (end > pkt.len or end < icmp_start + @sizeOf(ethernet.Icmp)) return null;

    const icmp = &@constCast(ip.l4()).icmp;
    if (icmp.type != .echo_request) return null;

    // the IP checksum sums 16-bit words, so swapping two of them keeps it valid
    std.mem.swap(Ip, &ip.src, &ip.dst);
    icmp.type = .echo_reply;
    icmp.checksum.set(0);
    icmp.checksum.set(ethernet.checksum(pkt[icmp_start..end]));
    return end;
}
