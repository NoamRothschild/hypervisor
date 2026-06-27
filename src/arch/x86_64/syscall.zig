const debug = @import("../../debug.zig");
const interrupts = @import("interrupts.zig");
const cpuState = interrupts.cpuState;

pub const id = 144; // int $144

/// must be called after calling interrupts.init!
pub fn init() void {
    interrupts.setHandler(id, syscallHandler);
}

fn syscallHandler(cpu_state: *const cpuState) callconv(.c) void {
    debug.printf("syscall!: {}\n", .{cpu_state});
}
