const std = @import("std");
const debug = @import("debug.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const paging = @import("arch/x86_64/paging.zig");
const vmx = @import("virt/vmx.zig");
const ept = @import("virt/ept.zig");
const vmcs = @import("virt/vmcs.zig");

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

    const rsp = asm volatile ("mov %rsp, %r8"
        : [rsp] "={r8}" (-> u64),
    );
    debug.printf("rsp: 0x{x}\n", .{rsp});

    gdt.initTss();
    std.log.info("TSS initialized", .{});

    const gdt_info = gdt.gdtInfo();
    for (0..3) |i| {
        std.log.info("gdt[{d}] = {}\n", .{ i, gdt.getSegmentDescriptor(@truncate(i << 3), gdt_info.base).* });
    }

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

    const guest_states: *[1]vmx.VMState = @ptrCast(try paging.alloc4KAligned());

    // TODO: run this block for each CPU
    for (guest_states) |*guest_state| {
        guest_state.* = std.mem.zeroes(vmx.VMState);

        vmx.enableOperation();
        std.log.info("vmx enabled\n", .{});

        vmx.allocVmxonRegion(guest_state) catch |err| {
            std.log.err("VMXON failed: {s}\n", .{@errorName(err)});
            return err;
        };

        std.log.info("VMXON succeeded\n", .{});
        defer vmx.vmxoff();

        vmcs.allocRegion(guest_state) catch |err| {
            std.log.err("VMCS allocation or VMPTRLD failed: {s}\n", .{@errorName(err)});
            return err;
        };

        // errors are logged inside the function
        if (!vmcs.clear(guest_state))
            return error.clear_vmcs_failed;
        if (!vmcs.load(guest_state))
            return error.vmcs_load_failed;

        std.log.info("VMPTRLD succeeded\n", .{});

        try ept.init(guest_state);

        const stack_pages: [1]*[4096]u8 = .{try paging.alloc4KAligned()};
        guest_state.vmm_stack = @ptrCast(stack_pages[0]);
        guest_state.vmm_stack.len = stack_pages.len * 4096;
        inline for (stack_pages[0..]) |stack_page| {
            @memset(stack_page.*[0..], @as(u8, 0));
        }

        const msr_bitmap_page = try paging.alloc4KAligned();
        guest_state.msr_bitmap = msr_bitmap_page;
        guest_state.msr_bitmap_phys = paging.physAddr(@intFromPtr(msr_bitmap_page)).?;
        @memset(msr_bitmap_page.*[0..], @as(u8, 0));

        try vmcs.setup(guest_state);

        if (vmx.vmlaunch()) {
            std.log.info("vm launch finished\n", .{});
        } else {
            std.log.info("vm launch finished failed\n", .{});
        }

        trap();
    }

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
