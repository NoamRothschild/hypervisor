const std = @import("std");
const log = std.log;

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

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(err: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    _ = ra;

    printf("PANIC!: {s}\n", .{err});
    printf("return address: 0x{x} frame address: 0x{x}\n", .{ @returnAddress(), @frameAddress() });

    while (true) {}
}

pub fn logFn(
    comptime message_level: log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const prefix = switch (message_level) {
        .debug => "[debug] ",
        .err => "[err] ",
        .info => "[info] ",
        .warn => "[warn] ",
    };
    printf("{s}", .{prefix});
    printf(format, args);
}
