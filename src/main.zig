comptime {
    _ = @import("entry.zig");
    _ = @import("paging.zig");
}

pub export fn kmain() void {
    asm volatile (
        \\ mov $0x144, %eax
        \\ mov $0x144, %eax
        \\ mov $0x144, %rax
        \\ mov $0x144, %eax
        \\ mov $0x144, %eax
        \\ mov $0x144, %eax
        \\ mov $0x144, %rax
    );
}
