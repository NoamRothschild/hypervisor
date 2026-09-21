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

/// uses cpuid to fetch the vendor
pub fn getVendor() [12]u8 {
    var vendor: [12]u8 = undefined;
    asm volatile (
        \\ push %rax
        \\ mov $0, %rax
        \\ cpuid
        \\ pop %rax
        \\ mov %ebx, (%rax)
        \\ mov %edx, 4(%rax)
        \\ mov %ecx, 8(%rax)
        :
        : [vendor] "{rax}" (&vendor),
        : .{ .rax = true, .ebx = true, .ecx = true, .edx = true });

    return vendor;
}

pub fn getFeatures() CpuFeatures {
    var ecx: u32 = 0;
    var edx: u32 = 0;
    asm volatile (
        \\ mov $1, %eax
        \\ cpuid
        : [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        :
        : .{ .eax = true, .ebx = true, .ecx = true, .edx = true });
    const both: u64 = @as(u64, ecx) | (@as(u64, edx) << 32);
    return @bitCast(both);
}

pub const CpuFeatures = packed struct(u64) {
    // ecx
    sse3: u1 = 0,
    pclmul: u1 = 0,
    dtes64: u1 = 0,
    monitor: u1 = 0,
    ds_cpl: u1 = 0,
    vmx: u1 = 0,
    smx: u1 = 0,
    est: u1 = 0,
    tm2: u1 = 0,
    ssse3: u1 = 0,
    cid: u1 = 0,
    sdbg: u1 = 0,
    fma: u1 = 0,
    cx16: u1 = 0,
    xtpr: u1 = 0,
    pdcm: u1 = 0,
    _reserved1: u1 = 0,
    pcid: u1 = 0,
    dca: u1 = 0,
    sse4_1: u1 = 0,
    sse4_2: u1 = 0,
    x2apic: u1 = 0,
    movbe: u1 = 0,
    popcnt: u1 = 0,
    ecx_tsc: u1 = 0,
    aes: u1 = 0,
    xsave: u1 = 0,
    osxsave: u1 = 0,
    avx: u1 = 0,
    f16c: u1 = 0,
    rdrand: u1 = 0,
    hypervisor: u1 = 0,
    // edx
    fpu: u1 = 0,
    vme: u1 = 0,
    de: u1 = 0,
    pse: u1 = 0,
    edx_tsc: u1 = 0,
    msr: u1 = 0,
    pae: u1 = 0,
    mce: u1 = 0,
    cx8: u1 = 0,
    apic: u1 = 0,
    _reserved2: u1 = 0,
    sep: u1 = 0,
    mtrr: u1 = 0,
    pge: u1 = 0,
    mca: u1 = 0,
    cmov: u1 = 0,
    pat: u1 = 0,
    pse36: u1 = 0,
    psn: u1 = 0,
    clflush: u1 = 0,
    _reserved3: u1 = 0,
    ds: u1 = 0,
    acpi: u1 = 0,
    mmx: u1 = 0,
    fxsr: u1 = 0,
    sse: u1 = 0,
    sse2: u1 = 0,
    ss: u1 = 0,
    htt: u1 = 0,
    tm: u1 = 0,
    ia64: u1 = 0,
    pbe: u1 = 0,
};
