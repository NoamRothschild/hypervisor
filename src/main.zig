comptime {
    _ = @import("entry.zig");
}

export fn kmain() void {
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
