const std = @import("std");
const debug = @import("debug.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const vmx = @import("virt/vmx.zig");
const Pcpu = @import("virt/pcpu.zig").Pcpu;
const ept = @import("virt/ept.zig");
const vmcs = @import("virt/vmcs.zig");
const mbt2 = @import("arch/x86_64/multiboot2.zig");
const hhdm = @import("mem/hhdm.zig");
const mem_allocator = @import("mem/allocator.zig");
const GuestAllocator = @import("mem/guest_allocator.zig");
const kalloc = &mem_allocator.kalloc;
const linux = @import("virt/guest_os/linux.zig");
const tsc = @import("arch/x86_64/tsc.zig");

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

    debug.printf("mbt2 magic: 0x{x}\n", .{mbt2.magic});
    if (mbt2.magic != mbt2.bootloader_magic) {
        @panic("invalid multiboot2 magic number!");
    }

    hhdm.init();
    std.log.info("HHDM initialized\n", .{});

    const mmap_tag = mbt2.findTag(.mmap) orelse @panic("unable to find mmap tag in mb2 hdr");

    debug.printf("mmap entries:\n", .{});
    var mmap_it: mbt2.MMAPIterator = .init(@ptrCast(@alignCast(mmap_tag)));
    while (mmap_it.next()) |mmap_entry| {
        debug.printf("mmap entry: {}\n", .{mmap_entry});
    }

    gdt.initTss();
    std.log.info("TSS initialized\n", .{});

    const gdt_info = gdt.gdtInfo();
    for (0..3) |i| {
        std.log.info("gdt[{d}] = {}\n", .{ i, gdt.getSegmentDescriptor(@truncate(i << 3), gdt_info.base).* });
    }

    mem_allocator.init();
    std.log.info("kernel allocator initialized\n", .{});

    const scratch = try kalloc.alloc(u8, 64);
    kalloc.free(scratch);

    const pages = try kalloc.allocPages(2);
    debug.printf("allocated {d} pool pages at 0x{x}\n", .{ pages.len / @TypeOf(kalloc.*).page_size, @intFromPtr(pages.ptr) });
    kalloc.freePages(pages);

    var guest_alloc: GuestAllocator = try .init(kalloc.allocator());
    std.log.info("guest allocator initialized, {d} free 1GB blocks\n", .{guest_alloc.availBlocks()});

    var node: @TypeOf(kalloc.fla.head) = kalloc.fla.head;
    while (node) |n| {
        defer node = n.next;
        debug.printf("fla allocator block free of size: {d:.2}MB\n", .{@as(f64, @floatFromInt(n.block_size)) / (1 << 20)});
    }

    asm volatile ("int $144");

    debug.printf("vendor: {s}\n", .{debug.getVendor()});
    debug.printf("features: {}\n", .{debug.getFeatures()});

    tsc.calibrate();
    std.log.info("TSC runs at {d} kHz\n", .{tsc.hz / 1000});
    if (!vmx.supportsVirtualization()) {
        std.log.err("proccessor does not support VT-x virtualization.\n", .{});
        trap();
    }

    var pcpu: Pcpu = undefined;
    try pcpu.init();
    defer vmx.vmxoff();

    const guest_states: *[1]vmx.VMState = @ptrCast(try kalloc.allocPage());

    for (guest_states) |*guest_state| {
        try guest_state.prepare(&pcpu, &guest_alloc, .{
            .ram_block_count = 2, // 2GB memory
            .vcpu_count = 3,
        });
        try linux.load(guest_state);
    }

    std.log.info("launching guest...\n", .{});
    pcpu.run();
    std.log.info("guest stopped\n", .{});

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
