const std = @import("std");
const log = std.log;

pub inline fn outb(port: u16, byte: u8) void {
    asm volatile (
        \\ mov %[port], %%dx
        \\ mov %[byte], %%al
        \\ out %%al, %%dx
        :
        : [port] "{dx}" (port),
          [byte] "{al}" (byte),
        : .{ .al = true, .dx = true });
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

fn serialDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    for (w.buffer[0..w.end]) |byte| outb(COM1, byte);
    w.end = 0;

    if (data.len == 0) return 0;

    var written: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        for (bytes) |byte| outb(COM1, byte);
        written += bytes.len;
    }
    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        for (pattern) |byte| outb(COM1, byte);
        written += pattern.len;
    }
    return written;
}

var serial_writer: std.Io.Writer = .{
    .vtable = &.{
        .drain = serialDrain,
        .flush = std.Io.Writer.noopFlush,
    },
    .buffer = &.{},
};

pub const out_writer = &serial_writer;

pub fn printf(comptime format: []const u8, args: anytype) void {
    std.Io.Writer.print(out_writer, format, args) catch unreachable;
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
