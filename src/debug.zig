const std = @import("std");

pub inline fn outb(port: u16, byte: u8) void {
    asm volatile (
        \\ mov %[port], %dx
        \\ mov %[byte], %al
        \\ out %al, %dx
        :
        : [port] "{dx}" (port),
          [byte] "{al}" (byte),
        : "al", "dx"
    );
}

pub inline fn inb(port: u16) u8 {
    var ret: u8 = undefined;
    asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (ret),
        : [port] "{dx}" (port),
    );
    return ret;
}

pub inline fn wait() void {
    outb(0x80, 0);
}

pub const COM1 = 0x03F8;

pub const outWriter = std.io.Writer(void, error{}, (struct {
    pub fn callback(_: void, string: []const u8) error{}!usize {
        for (string) |char| {
            outb(COM1, char);
        }
        return string.len;
    }
}).callback){ .context = {} };

pub fn printf(comptime format: []const u8, args: anytype) void {
    std.fmt.format(outWriter, format, args) catch unreachable;
}
