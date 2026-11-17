//! A fake gateway at 10.0.2.2 that answers ARP requests and pings, to test RX
//! before there is a switch and a NIC to deliver real frames.
const std = @import("std");

const gw_mac = [6]u8{ 0x52, 0x55, 0x0a, 0x00, 0x02, 0x02 }; // what QEMU's slirp uses
const gw_ip = [4]u8{ 10, 0, 2, 2 };

const ethertype_arp = 0x0806;
const ethertype_ipv4 = 0x0800;

/// writes a reply to `in` into `out`. returns its length, or null if `in` is not for us
pub fn respond(in: []const u8, out: []u8) ?usize {
    if (in.len < 14) return null;
    return switch (std.mem.readInt(u16, in[12..14], .big)) {
        ethertype_arp => arpReply(in, out),
        ethertype_ipv4 => echoReply(in, out),
        else => null,
    };
}

/// answers "who has 10.0.2.2" with `gw_mac`
fn arpReply(in: []const u8, out: []u8) ?usize {
    if (in.len < 42 or out.len < 42) return null;
    if (std.mem.readInt(u16, in[20..22], .big) != 1) return null; // not a request
    if (!std.mem.eql(u8, in[38..42], &gw_ip)) return null;
    @memcpy(out[0..42], in[0..42]);
    @memcpy(out[0..6], in[6..12]); // to whoever asked
    @memcpy(out[6..12], &gw_mac);
    std.mem.writeInt(u16, out[20..22], 2, .big); // reply
    @memcpy(out[22..28], &gw_mac); // sender: us
    @memcpy(out[28..32], &gw_ip);
    @memcpy(out[32..38], in[22..28]); // target: the asker
    @memcpy(out[38..42], in[28..32]);
    return 42;
}

/// turns an ICMP echo request to 10.0.2.2 into an echo reply
fn echoReply(in: []const u8, out: []u8) ?usize {
    if (in.len < 34 or in[23] != 1) return null; // not ICMP
    if (!std.mem.eql(u8, in[30..34], &gw_ip)) return null;
    const ihl = @as(usize, in[14] & 0x0f) * 4;
    const end = 14 + @as(usize, std.mem.readInt(u16, in[16..18], .big));
    const icmp = 14 + ihl;
    if (ihl < 20 or end > in.len or end > out.len or end < icmp + 8 or in[icmp] != 8) return null;

    @memcpy(out[0..end], in[0..end]);
    @memcpy(out[0..6], in[6..12]);
    @memcpy(out[6..12], &gw_mac);
    @memcpy(out[26..30], in[30..34]); // swap IPs. The IP header checksum is a sum
    @memcpy(out[30..34], in[26..30]); // of 16-bit words, so swapping two of them keeps it valid
    out[icmp] = 0; // echo reply
    std.mem.writeInt(u16, out[icmp + 2 ..][0..2], 0, .big);
    std.mem.writeInt(u16, out[icmp + 2 ..][0..2], checksum(out[icmp..end]), .big);
    return end;
}

/// RFC 1071: one's complement of the one's complement sum of 16-bit words
fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) sum += std.mem.readInt(u16, data[i..][0..2], .big);
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}
