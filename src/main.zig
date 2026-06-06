const debug = @import("debug.zig");
const paging = @import("paging.zig");

comptime {
    _ = @import("entry.zig");
    _ = @import("paging.zig");
}

pub export fn kmain() void {
    debug.printf("inside kmain!\n", .{});
    for (0..10) |_| {
        const page_addr: [*]usize = @ptrFromInt(paging.alloc_page() catch |err| {
            debug.printf("page allocation failed with: {s}\n", .{@errorName(err)});
            return;
        });
        debug.printf("allocated a new page at addr {*}\n", .{page_addr});
        const first = page_addr[0];
        debug.printf("read from my_special_addr: {d}\n", .{first});
    }

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
