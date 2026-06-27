const syscall = @import("syscall.zig");
const debug = @import("../../debug.zig");

pub const HandlerType = fn (*const cpuState) callconv(.c) void;
export var handlers_map: [0xff]*const HandlerType = undefined;

pub const cpuState = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,

    interrupt_id: u64,
    error_code: u64,

    rip: u64,
    cs: u64,
    rflags: u64,
};

pub fn init() void {
    // set default handlers
    for (&handlers_map) |*entry|
        entry.* = dump;
}

pub fn setHandler(id: u32, handler: HandlerType) void {
    handlers_map[@as(usize, id)] = handler;
}

fn dump(cpu_state: *const cpuState) callconv(.c) void {
    const err_msg = switch (cpu_state.interrupt_id) {
        0 => "Division by zero",
        1 => "Debug",
        2 => "Non maskable interrupt",
        3 => "Breakpoint",
        4 => "Overflow",
        5 => "Bound range exceeded",
        6 => "Invalid opcode",
        7 => "Device not available",
        8 => "Double fault",
        9 => "Coprocessor segment overrun",
        10 => "Invalid TSS",
        11 => "Segment not present",
        12 => "Stack segment fault",
        13 => "General protection fault",
        14 => "Page fault",
        15 => "Reserved",
        16 => "x87 floating point exception",
        17 => "Alignment check",
        18 => "Machine check",
        19 => "SIMD floating point exception",
        20 => "Virtualization exception",
        21 => "Control protection exception",
        22...31 => "Reserved",
        syscall.id => "Syscall",
        else => "Unknown trap gate caught",
    };
    debug.printf(
        "{s}interrupt {d} caught: {s}\nCPU state:\n{any}\n\n",
        .{
            (if (cpu_state.interrupt_id <= 31) "Hardware " else ""),
            cpu_state.interrupt_id,
            err_msg,
            cpu_state.*,
        },
    );

    if (cpu_state.interrupt_id != syscall.id)
        asm volatile ("hlt");
}
