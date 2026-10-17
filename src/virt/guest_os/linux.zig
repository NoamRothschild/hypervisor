const std = @import("std");
const debug = @import("../../debug.zig");
const assert = std.debug.assert;
const vmx = @import("../vmx.zig");
const ept = @import("../ept.zig");
const mptable = @import("../smp/mptable.zig");
const mbt2 = @import("../../arch/x86_64/multiboot2.zig");
const gdt32 = @import("../../arch/x86/gdt.zig");
const bootparams = @import("linux_bootparams.zig");
const BootParams = bootparams.BootParams;
const SetupHeader = bootparams.SetupHeader;

pub const layout = struct {
    /// Where the GDT the guest enters with is written. The boot protocol needs
    /// descriptors for __BOOT_CS (0x10) and __BOOT_DS (0x18) to exist.
    pub const gdt = 0x0000_3000;
    /// Where the kernel boot parameters are loaded, known as "zero page".
    /// Must be initialized with zeros.
    pub const bootparam = 0x0001_0000;
    /// Where the kernel cmdline is located.
    pub const cmdline = 0x0002_0000;
    /// Where the protected-mode kernel code is loaded
    pub const kernel_base = 0x0010_0000;
    /// Where the initrd is loaded.
    pub const initrd = 0x0600_0000;

    comptime {
        assert(bootparam < (1 << 30));
        assert(cmdline < (1 << 30));
        assert(kernel_base < (1 << 30));
        assert(initrd < (1 << 30));
    }
};

/// The cmdline the bzImage is given in grub.cfg, which is how we find it again.
pub const kernel_module_name = "linux_bz_img";

/// The cmdline the rootfs.cpio.gz is given in grub.cfg, which is how we find it again.
pub const rootfs_module_name = "linux_rootfs";

/// The guest kernel, loaded by GRUB as a multiboot2 module
/// requires `hhdm.init()` to have run.
fn kernelImg() []const u8 {
    const mod = mbt2.findModule(kernel_module_name) orelse
        @panic("GRUB linux kernel module missing");
    return mod.data();
}

/// The guest rootfs, loaded by GRUB as a multiboot2 module
/// requires `hhdm.init()` to have run.
fn kernelRootFs() []const u8 {
    const mod = mbt2.findModule(rootfs_module_name) orelse
        @panic("GRUB linux rootfs module missing");
    return mod.data();
}

/// flashes the kernel into guest memory
pub fn load(dst_guest: *vmx.VMState) !void {
    const img = kernelImg();
    var bp: BootParams = .fromBzImage(img);

    const rootfs_raw = kernelRootFs();

    // Setup necessary fields
    bp.hdr.type_of_loader = 0xFF;
    bp.hdr.ext_loader_ver = 0;
    bp.hdr.loadflags.loaded_high = true; // load kernel at 0x10_0000
    bp.hdr.loadflags.can_use_heap = true; // use memory 0..BOOTPARAM as heap
    bp.hdr.heap_end_ptr = layout.bootparam - 0x200;
    bp.hdr.loadflags.keep_segments = false;
    bp.hdr.cmd_line_ptr = layout.cmdline;
    bp.hdr.vid_mode = 0xFFFF; // VGA (normal)
    bp.hdr.ramdisk_image = layout.initrd;
    bp.hdr.ramdisk_size = @truncate(rootfs_raw.len);

    // base memory, up to the MP tables in its last KB
    bp.addE820Entry(.{
        .addr = 0,
        .size = mptable.base.raw(),
        .type = .ram,
    });
    // the MP tables, and the VGA/BIOS hole up to 1MB, as on a PC
    bp.addE820Entry(.{
        .addr = mptable.base.raw(),
        .size = layout.kernel_base - mptable.base.raw(),
        .type = .reserved,
    });
    // RAM up to the MMIO hole, the rest of it is above the hole, see `ept.mmio_hole_start`
    const block_count = dst_guest.guest_mem_pages.len;
    const low_blocks: usize = @min(block_count, ept.mmio_hole_start.raw() >> 30);
    bp.addE820Entry(.{
        .addr = layout.kernel_base,
        .size = (1 << 30) * low_blocks - layout.kernel_base,
        .type = .ram,
    });
    if (block_count > low_blocks) {
        bp.addE820Entry(.{
            .addr = ept.mmio_hole_end.raw(),
            .size = (1 << 30) * (block_count - low_blocks),
            .type = .ram,
        });
    }
    try mptable.write(dst_guest, .{ .cpu_count = @intCast(dst_guest.cpus.len) });

    const cmdline_max_size = if (bp.hdr.cmdline_size < 256) bp.hdr.cmdline_size else 256;
    var cmdline_val: [256]u8 = @splat(0);
    _ = std.fmt.bufPrint(cmdline_val[0..cmdline_max_size], "console=ttyS0 earlyprintk=serial nokaslr apic=debug nr_cpus={d} acpi=off noapic", .{dst_guest.cpus.len}) catch |err| {
        std.log.err("provided guest cmdline too long!", .{});
        return err;
    };
    try ept.writeGuest(dst_guest, cmdline_val[0..], .from(layout.cmdline));

    const guest_gdt = gdt32.flatProtectedMode();
    try ept.writeGuest(dst_guest, std.mem.asBytes(&guest_gdt), .from(layout.gdt));

    // the BSP enters the kernel, the APs wait for the kernel to start them
    const bsp = &dst_guest.cpus[0];
    // the 32-bit boot protocol: esi points at the zero page, and ebx, ebp
    // and edi must be zero
    bsp.regs = std.mem.zeroes(@TypeOf(bsp.regs));
    bsp.regs.rsi = layout.bootparam;
    bsp.start(.{ .protected32 = .{
        .rip = layout.kernel_base,
        // top of the RAM below the MMIO hole, so the stack is RAM even for a 32-bit guest
        .rsp = @intCast((1 << 30) * low_blocks),
        .gdtr_base = layout.gdt,
        .gdtr_limit = @sizeOf(@TypeOf(guest_gdt)) - 1,
    } });

    const code_offset = bp.hdr.protectedCodeOffset();
    const code_size = img.len - code_offset;
    try ept.writeGuest(dst_guest, std.mem.asBytes(&bp), .from(layout.bootparam));
    try ept.writeGuest(
        dst_guest,
        img[code_offset .. code_offset + code_size],
        .from(layout.kernel_base),
    );
    try ept.writeGuest(
        dst_guest,
        rootfs_raw,
        .from(layout.initrd),
    );
}
