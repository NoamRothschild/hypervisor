const std = @import("std");
const syscall = @import("syscall.zig");
const interrupts = @import("interrupts.zig");
const pic = @import("pic.zig");

/// offsets from the GDT table present inside entry.asm
pub const gdt_offsets = struct {
    nulld: usize = 0,
    kernel_codeseg: usize = 1,
    kernel_dataseg: usize = 2,
    // tss: usize = 3,
}{};

pub const SegmentSelector = packed struct {
    rpl: u2,
    ti: u1,
    index: u13,
};

pub const IdtGate = packed struct {
    offset_low: u16,
    segment_selector: SegmentSelector,
    ist: u8,
    gate_type: u4,
    zero: u1,
    dpl: u2,
    p: u1,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

const gate_types = struct {
    intr_gate64bit: u4 = 0xe,
    trap_gate64bit: u4 = 0xf,
}{};

var entries: [0xff]IdtGate = [_]IdtGate{std.mem.zeroes(IdtGate)} ** 0xff;

pub var idt_descriptor = extern struct {
    limit: u16,
    base: u64 align(1),
}{
    .limit = undefined,
    .base = undefined,
};

inline fn isrAddress(comptime vector: comptime_int) u64 {
    @setEvalBranchQuota(10000);
    const symbol = comptime std.fmt.comptimePrint("isr_{d}", .{vector});
    return @intFromPtr(@extern(*const anyopaque, .{ .name = symbol }));
}

inline fn irqAddress(comptime vector: comptime_int) u64 {
    @setEvalBranchQuota(10000);
    const symbol = comptime std.fmt.comptimePrint("irq_{d}", .{vector});
    return @intFromPtr(@extern(*const anyopaque, .{ .name = symbol }));
}

inline fn initTable() void {
    const syscall_gate = makeState(.{
        .offset = isrAddress(syscall.id),
        .segment_selector = .{
            .index = gdt_offsets.kernel_codeseg,
            .rpl = 0x0,
            .ti = 0,
        },
        .gate_type = gate_types.intr_gate64bit,
        .dpl = 0x3, // everyone can call these interrupts using `int`
        .p = 1,
    });

    // const task_gate = makeState(.{
    //     .offset = 0,
    //     .segment_selector = .{
    //         .index = gdt_offsets.tss,
    //         .rpl = 0x0, // TODO: Check if does not conflict with dpl somehow
    //         .ti = 0,
    //     },
    //     .gate_type = gate_types.task_gate,
    //     .dpl = 0x3, // everyone can call these interrupts using `int`
    //     .p = 1,
    // });

    // trap gates
    inline for (0..32) |i|
        entries[i] = makeState(.{
            .offset = isrAddress(i),
            .segment_selector = .{
                .index = gdt_offsets.kernel_codeseg,
                .rpl = 0x0,
                .ti = 0,
            },
            .gate_type = gate_types.trap_gate64bit,
            .dpl = 0x0,
            .p = 1,
        });

    // irq gates
    inline for (32..48) |i|
        entries[i] = makeState(.{
            .offset = irqAddress(i),
            .segment_selector = .{
                .index = gdt_offsets.kernel_codeseg,
                .rpl = 0x0,
                .ti = 0,
            },
            .gate_type = gate_types.trap_gate64bit,
            .dpl = 0x0,
            .p = 1,
        });

    entries[syscall.id] = syscall_gate;
}

pub fn init() void {
    interrupts.init();
    syscall.init();

    initTable();
    pic.init();

    idt_descriptor.limit = @sizeOf(@TypeOf(entries)) - 1;
    idt_descriptor.base = @intFromPtr(&entries);

    asm volatile ("lidt (%[desc])"
        :
        : [desc] "r" (&idt_descriptor),
        : .{ .memory = true });

    asm volatile ("sti");
}

fn makeState(config: struct { offset: u64, segment_selector: SegmentSelector, gate_type: u4, dpl: u2, p: u1 }) IdtGate {
    return IdtGate{
        .offset_low = @truncate(config.offset),
        .segment_selector = config.segment_selector,
        .ist = 0,
        .gate_type = config.gate_type,
        .zero = 0,
        .dpl = config.dpl,
        .p = config.p,
        .offset_mid = @truncate(config.offset >> 16),
        .offset_high = @truncate(config.offset >> 32),
        .reserved = 0,
    };
}
