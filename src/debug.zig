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
        : .{ .eax = true, .ebx = true, .ecx = true, .edx = true });

    return vendor;
}

pub fn getFeatures() CpuFeatures {
    var ecx: u32 = 0;
    var edx: u32 = 0;
    // _ = &ecx;
    // _ = &edx;
    asm volatile (
        \\ mov $1, %eax
        \\ cpuid
        : [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        :
        : .{ .ecx = true, .edx = true, .eax = true });
    const both: u64 = @as(u64, ecx) | (@as(u64, edx) << 32);
    return @bitCast(both);
}

const CpuFeatures = packed struct {
    // ecx
    sse3: u1,
    pclmul: u1,
    dtes64: u1,
    monitor: u1,
    ds_cpl: u1,
    vmx: u1,
    smx: u1,
    est: u1,
    tm2: u1,
    ssse3: u1,
    cid: u1,
    sdbg: u1,
    fma: u1,
    cx16: u1,
    xtpr: u1,
    pdcm: u1,
    _reserved1: u1,
    pcid: u1,
    dca: u1,
    sse4_1: u1,
    sse4_2: u1,
    x2apic: u1,
    movbe: u1,
    popcnt: u1,
    ecx_tsc: u1,
    aes: u1,
    xsave: u1,
    osxsave: u1,
    avx: u1,
    f16c: u1,
    rdrand: u1,
    hypervisor: u1,
    // edx
    fpu: u1,
    vme: u1,
    de: u1,
    pse: u1,
    edx_tsc: u1,
    msr: u1,
    pae: u1,
    mce: u1,
    cx8: u1,
    apic: u1,
    _reserved2: u1,
    sep: u1,
    mtrr: u1,
    pge: u1,
    mca: u1,
    cmov: u1,
    pat: u1,
    pse36: u1,
    psn: u1,
    clflush: u1,
    _reserved3: u1,
    ds: u1,
    acpi: u1,
    mmx: u1,
    fxsr: u1,
    sse: u1,
    sse2: u1,
    ss: u1,
    htt: u1,
    tm: u1,
    ia64: u1,
    pbe: u1,
};
