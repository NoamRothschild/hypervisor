const std = @import("std");
const debug = @import("../../debug.zig");
const assert = std.debug.assert;
const vmx = @import("../vmx.zig");
const ept = @import("../ept.zig");
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
pub const module_name = "linux_bz_img";

/// The guest kernel, loaded by GRUB as a multiboot2 module
/// requires `hhdm.init()` to have run.
fn kernelImg() []const u8 {
    const mod = mbt2.findModule(module_name) orelse
        @panic("GRUB linux kernel module missing");
    return mod.data();
}

/// flashes the kernel into guest memory
pub fn load(dst_guest: *vmx.VMState) !void {
    const img = kernelImg();
    var bp: BootParams = .fromBzImage(img);

    // Setup necessary fields
    bp.hdr.type_of_loader = 0xFF;
    bp.hdr.ext_loader_ver = 0;
    bp.hdr.loadflags.loaded_high = true; // load kernel at 0x10_0000
    bp.hdr.loadflags.can_use_heap = true; // use memory 0..BOOTPARAM as heap
    bp.hdr.heap_end_ptr = layout.bootparam - 0x200;
    bp.hdr.loadflags.keep_segments = false;
    bp.hdr.cmd_line_ptr = layout.cmdline;
    bp.hdr.vid_mode = 0xFFFF; // VGA (normal)

    bp.addE820Entry(.{
        .addr = 0,
        .size = (1 << 30) * dst_guest.guest_mem_pages.len,
        .type = .ram,
    });

    const cmdline_max_size = if (bp.hdr.cmdline_size < 256) bp.hdr.cmdline_size else 256;
    const cmdline_val = "console=ttyS0 earlyprintk=serial nokaslr";
    try ept.writeGuest(dst_guest, cmdline_val, .from(layout.cmdline));
    try ept.memsetGuest(dst_guest, 0, .from(layout.cmdline + cmdline_val.len), cmdline_max_size - cmdline_val.len);

    const guest_gdt = gdt32.flatProtectedMode();
    try ept.writeGuest(dst_guest, std.mem.asBytes(&guest_gdt), .from(layout.gdt));
    vmx.vmwrite(.GUEST_GDTR_BASE, layout.gdt);
    vmx.vmwrite(.GUEST_GDTR_LIMIT, @sizeOf(@TypeOf(guest_gdt)) - 1);

    const code_offset = bp.hdr.protectedCodeOffset();
    const code_size = img.len - code_offset;
    try ept.writeGuest(dst_guest, std.mem.asBytes(&bp), .from(layout.bootparam));
    try ept.writeGuest(
        dst_guest,
        img[code_offset .. code_offset + code_size],
        .from(layout.kernel_base),
    );
}
