const std = @import("std");
const debug = @import("debug.zig");
const paging = @import("arch/x86_64/paging.zig");

comptime {
    _ = @import("arch/x86_64/entry.zig");
    _ = @import("arch/x86_64/paging.zig");
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

        paging.unmap_page(@intFromPtr(page_addr));
    }

    asm volatile ("int $144");

    while (true) {}
}

pub const panic = debug.panic;
pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = debug.logFn,
};
