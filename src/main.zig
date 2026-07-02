const std = @import("std");
const debug = @import("debug.zig");
const paging = @import("arch/x86_64/paging.zig");
const vmx = @import("vmx.zig");

comptime {
    _ = @import("arch/x86_64/entry.zig");
    _ = @import("arch/x86_64/paging.zig");
}

export fn kmain_start() void {}
comptime {
    @export(&kmain_start, .{ .name = "kmain" });
}

pub fn kmain() !void {
    kmain_start();
    debug.printf("inside kmain!\n", .{});
    for (0..10) |_| {
        const page_addr: [*]usize = @ptrFromInt(paging.allocPage() catch |err| {
            debug.printf("page allocation failed with: {s}\n", .{@errorName(err)});
            return;
        });
        debug.printf("allocated a new page at addr {*}\n", .{page_addr});
        const first = page_addr[0];
        debug.printf("read from my_special_addr: {d}\n", .{first});

        paging.unmapPage(@intFromPtr(page_addr));
    }

    asm volatile ("int $144");

    debug.printf("vendor: {s}\n", .{debug.getVendor()});
    debug.printf("features: {}\n", .{debug.getFeatures()});
    if (!vmx.supportsVirtualization()) {
        std.log.err("proccessor does not support VT-x virtualization.\n", .{});
        trap();
    }

    vmx.enableOperation();
    std.log.info("vmx enabled\n", .{});

    vmx.allocVmxonRegion() catch |err| {
        std.log.err("VMXON failed: {s}\n", .{@errorName(err)});
        return err;
    };

    std.log.info("VMXON succeeded\n", .{});

    vmx.allocVmcsRegion() catch |err| {
        std.log.err("VMCS allocation or VMPTRLD failed: {s}\n", .{@errorName(err)});
        return err;
    };

    std.log.info("VMPTRLD succeeded\n", .{});

    trap();
}

inline fn trap() noreturn {
    while (true)
        asm volatile ("hlt");
}

pub const panic = debug.panic;
pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = debug.logFn,
    .page_size_max = 0x1000,
};
