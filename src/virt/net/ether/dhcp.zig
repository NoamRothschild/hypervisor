//! DHCP (RFC 2131, options in RFC 2132). it runs over UDP, see `Udp.dhcp`
const eth = @import("../ethernet.zig");
const Be = eth.Be;
const Mac = eth.Mac;
const Ip = eth.Ip;
const Ipv4 = eth.Ipv4;
const Udp = eth.Udp;

/// the port the server listens on
pub const server_port = 67;
/// the port the client listens on
pub const client_port = 68;

/// the fixed part of a DHCP message (the BOOTP header). options follow it, see `Options`
pub const Dhcp = extern struct {
    /// BOOTREQUEST from the client, BOOTREPLY from the server
    op: Op,
    /// 1 for Ethernet
    htype: u8,
    /// 6, the length of a MAC
    hlen: u8,
    /// relay agents increment it, clients send 0
    hops: u8,
    /// picked by the client, the server copies it into its replies
    xid: Be(u32),
    /// seconds since the client started asking
    secs: Be(u16),
    /// only `flag_broadcast` is defined
    flags: Be(u16),
    /// the client's IP, if it already has one (renewing)
    ciaddr: Ip,
    /// "your" IP: the address the server gives the client
    yiaddr: Ip,
    /// the next server to boot from (TFTP), 0 if none
    siaddr: Ip,
    /// the relay agent's IP, 0 when there is none
    giaddr: Ip,
    /// the client's MAC in the first `hlen` bytes, zero padded
    chaddr: [16]u8,
    /// server host name and boot file name, unused here
    sname: [64]u8,
    file: [128]u8,
    /// `magic`, what makes it DHCP and not plain BOOTP
    cookie: Be(u32),

    pub const magic: u32 = 0x63825363;
    /// the client can't receive unicast before it has an IP, reply to broadcast
    pub const flag_broadcast: u16 = 1 << 15;

    pub const Op = enum(u8) {
        request = 1,
        reply = 2,
        _,
    };

    pub fn clientMac(self: *const Dhcp) Mac {
        return self.chaddr[0..6].*;
    }
};

/// option 53, the kind of DHCP message
pub const MsgType = enum(u8) {
    discover = 1,
    offer = 2,
    request = 3,
    decline = 4,
    ack = 5,
    nak = 6,
    release = 7,
    inform = 8,
    _,
};

/// an option is `code`, `len`, then `len` bytes of data. `pad` and `end` are a
/// single byte with no length
pub const Option = enum(u8) {
    pad = 0,
    /// 4 bytes
    subnet_mask = 1,
    /// 4 bytes per router
    router = 3,
    /// 4 bytes per server
    dns = 6,
    hostname = 12,
    /// 4 bytes, in a request: the IP the client asks for
    requested_ip = 50,
    /// 4 bytes, seconds
    lease_time = 51,
    /// 1 byte, `MsgType`
    msg_type = 53,
    /// 4 bytes, the IP of the server that made the offer
    server_id = 54,
    /// a list of option codes the client wants in the reply
    param_request_list = 55,
    end = 255,
    _,
};

/// true if `frame`, which holds a UDP packet that `eth.fitsL4`, is long enough
/// for a DHCP header after the UDP one, and carries the DHCP magic cookie
pub fn fits(frame: []const u8) bool {
    const ip: *const Ipv4 = @ptrCast(frame[eth.header_len..].ptr);
    const start = eth.header_len + ip.headerLen() + @sizeOf(Udp);
    if (frame.len < start + @sizeOf(Dhcp)) return false;
    const msg: *const Dhcp = @ptrCast(frame[start..].ptr);
    return msg.cookie.get() == Dhcp.magic;
}

/// walks the options after a `Dhcp` header
pub const Options = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub const Entry = struct {
        code: Option,
        data: []const u8,
    };

    /// the options of the DHCP message in `frame`, which must pass `fits`.
    /// they end at the IP packet's end, before any Ethernet padding
    pub fn of(frame: []const u8) Options {
        const ip: *const Ipv4 = @ptrCast(frame[eth.header_len..].ptr);
        const start = eth.header_len + ip.headerLen() + @sizeOf(Udp) + @sizeOf(Dhcp);
        const end = @min(frame.len, eth.header_len + @as(usize, ip.total_len.get()));
        return .{ .bytes = if (end > start) frame[start..end] else &.{} };
    }

    /// the next option. null at `end`, at the end of the bytes, or at an option
    /// whose length runs past them
    pub fn next(self: *Options) ?Entry {
        while (self.pos < self.bytes.len) {
            const code: Option = @enumFromInt(self.bytes[self.pos]);
            switch (code) {
                .pad => self.pos += 1,
                .end => return null,
                else => {
                    if (self.pos + 2 > self.bytes.len) return null;
                    const len = self.bytes[self.pos + 1];
                    const data_start = self.pos + 2;
                    if (data_start + len > self.bytes.len) return null;
                    self.pos = data_start + len;
                    return .{ .code = code, .data = self.bytes[data_start..][0..len] };
                },
            }
        }
        return null;
    }

    /// the data of the first `code` option, from the start
    pub fn find(self: Options, code: Option) ?[]const u8 {
        var it: Options = .{ .bytes = self.bytes };
        while (it.next()) |opt| if (opt.code == code) return opt.data;
        return null;
    }

    /// option 53, null if it is missing or malformed
    pub fn msgType(self: Options) ?MsgType {
        const data = self.find(.msg_type) orelse return null;
        if (data.len != 1) return null;
        return @enumFromInt(data[0]);
    }
};

/// appends options after a `Dhcp` header, for building replies
pub const OptionWriter = struct {
    buf: []u8,
    len: usize = 0,

    /// false if it doesn't fit, leaving room for `end`
    pub fn put(self: *OptionWriter, code: Option, data: []const u8) bool {
        if (data.len > 255 or self.len + 2 + data.len + 1 > self.buf.len) return false;
        self.buf[self.len] = @intFromEnum(code);
        self.buf[self.len + 1] = @intCast(data.len);
        @memcpy(self.buf[self.len + 2 ..][0..data.len], data);
        self.len += 2 + data.len;
        return true;
    }

    /// closes the options. returns their length, `end` included
    pub fn end(self: *OptionWriter) usize {
        self.buf[self.len] = @intFromEnum(Option.end);
        self.len += 1;
        return self.len;
    }
};

comptime {
    if (@sizeOf(Dhcp) != 240) @compileError("Dhcp must be 240 bytes");
    if (@alignOf(Dhcp) != 1) @compileError("Dhcp must be cast-able at any address");
}
