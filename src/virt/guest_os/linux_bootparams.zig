//! PORTED FROM: https://docs.rs/linux-boot-params/latest/src/linux_boot_params/lib.rs.html
//! SPDX-License-Identifier: MPL-2.0
//!
//! The definition of Linux Boot Protocol boot_params struct.
//!
//! The bootloader will deliver the address of the `BootParams` struct
//! as the argument of the kernel entrypoint. So we must define a Linux
//! ABI compatible struct in Zig, despite that most of the fields are
//! currently not needed.
//!
//! Every struct here is an `extern struct` with `align(1)` on each field,
//! not a `packed struct`: the ABI is byte-exact but not naturally aligned
//! (`hdr` lives at 0x1f1, `capabilities` at 0x36, an e820 entry is 20 bytes),
//! and a packed struct cannot hold the byte arrays these structs need.
//! Dropping an `align(1)` silently shifts every field after it, so the
//! `comptime` block at the bottom of this file checks the critical offsets.

const std = @import("std");
const testing = std.testing;

/// Magic stored in the boot protocol header.
pub const linux_boot_header_magic: u32 = 0x53726448;

/// Linux 32/64-bit Boot Protocol parameter struct.
///
/// Originally defined in the linux source tree:
/// `linux/arch/x86/include/uapi/asm/bootparam.h`
pub const BootParams = extern struct {
    /// 0x000
    screen_info: ScreenInfo align(1),
    /// 0x040
    apm_bios_info: ApmBiosInfo align(1),
    /// 0x054
    _pad2: u32 align(1),
    /// 0x058
    tboot_addr: u64 align(1),
    /// 0x060
    ist_info: IstInfo align(1),
    /// 0x070
    acpi_rsdp_addr: u64 align(1),
    /// 0x078
    _pad3: u64 align(1),
    /// obsolete! 0x080
    hd0_info: [16]u8 align(1),
    /// obsolete! 0x090
    hd1_info: [16]u8 align(1),
    /// obsolete! 0x0a0
    sys_desc_table: SysDescTable align(1),
    /// 0x0b0
    olpc_ofw_header: OlpcOfwHeader align(1),
    /// 0x0c0
    ext_ramdisk_image: u32 align(1),
    /// 0x0c4
    ext_ramdisk_size: u32 align(1),
    /// 0x0c8
    ext_cmd_line_ptr: u32 align(1),
    /// 0x0cc
    _pad4: [112]u8 align(1),
    /// 0x13c
    cc_blob_address: u32 align(1),
    /// 0x140
    edid_info: EdidInfo align(1),
    /// 0x1c0
    efi_info: EfiInfo align(1),
    /// 0x1e0
    alt_mem_k: u32 align(1),
    /// Scratch field! 0x1e4
    scratch: u32 align(1),
    /// 0x1e8
    e820_entries: u8 align(1),
    /// 0x1e9
    eddbuf_entries: u8 align(1),
    /// 0x1ea
    edd_mbr_sig_buf_entries: u8 align(1),
    /// 0x1eb
    kbd_status: u8 align(1),
    /// 0x1ec
    secure_boot: u8 align(1),
    /// 0x1ed
    _pad5: [2]u8 align(1),
    /// 0x1ef
    sentinel: u8 align(1),
    /// 0x1f0
    _pad6: [1]u8 align(1),
    /// setup header 0x1f1
    hdr: SetupHeader align(1),
    _pad7: [0x290 - 0x1f1 - @sizeOf(SetupHeader)]u8 align(1),
    /// 0x290
    edd_mbr_sig_buffer: [edd_mbr_sig_max]u32 align(1),
    /// 0x2d0
    e820_table: [e820_max_entries_zeropage]BootE820Entry align(1),
    /// 0xcd0
    _pad8: [48]u8 align(1),
    /// 0xd00
    eddbuf: [eddmaxnr]EddInfo align(1),
    /// 0xeec
    _pad9: [276]u8 align(1),

    /// Offset of the setup header, both inside a bzImage and inside the zero page.
    pub const hdr_offset = 0x1f1;

    /// Builds the zero page from a bzImage.
    ///
    /// Everything is zeroed except `hdr`, which is copied out of the image.
    /// Only the setup header is shared between the two layouts: 0x000..0x1f0 of
    /// a bzImage is boot sector code, so copying the image's first 4KiB verbatim
    /// would hand the kernel garbage for `screen_info`, `apm_bios_info` and the
    /// rest. (The kernel half-defends against exactly that with the `sentinel`
    /// byte at 0x1ef, scrubbing some fields when it is non-zero.)
    pub fn fromBzImage(image: []const u8) error{ ImageTooSmall, NotABzImage }!BootParams {
        if (image.len < hdr_offset + @sizeOf(SetupHeader))
            return error.ImageTooSmall;

        var bp: BootParams = undefined;
        @memset(std.mem.asBytes(&bp), 0);

        // the two values the kernel itself checks before trusting the header
        if (std.mem.readInt(u16, image[0x1fe..][0..2], .little) != 0xaa55)
            return error.NotABzImage;
        if (std.mem.readInt(u32, image[0x202..][0..4], .little) != linux_boot_header_magic)
            return error.NotABzImage;

        // the header ends at 0x202 plus the byte at 0x201, which is shorter than
        // `SetupHeader` on older kernels; never copy more than either side holds
        const header_end = 0x202 + @as(usize, image[0x201]);
        const len = @min(header_end -| hdr_offset, @sizeOf(SetupHeader));
        @memcpy(std.mem.asBytes(&bp.hdr)[0..len], image[hdr_offset..][0..len]);

        if (bp.hdr.setup_sects == 0)
            bp.hdr.setup_sects = 4;

        return bp;
    }

    pub fn addE820Entry(self: *BootParams, entry: BootE820Entry) void {
        defer self.e820_entries += 1;
        self.e820_table[self.e820_entries] = entry;
    }
};

/// Linux Boot Protocol header.
///
/// Originally defined in the linux source tree:
/// `linux/arch/x86/include/uapi/asm/bootparam.h`
pub const SetupHeader = extern struct {
    setup_sects: u8 align(1),
    root_flags: u16 align(1),
    syssize: u32 align(1),
    ram_size: u16 align(1),
    vid_mode: u16 align(1),
    root_dev: u16 align(1),
    boot_flag: u16 align(1),
    jump: u16 align(1),
    header: u32 align(1),
    version: u16 align(1),
    realmode_swtch: u32 align(1),
    start_sys_seg: u16 align(1),
    kernel_version: u16 align(1),
    type_of_loader: u8 align(1),
    loadflags: packed struct(u8) {
        loaded_high: bool = false,
        kaslr_flag: bool = false,
        _unused: u3 = 0,
        quiet_flag: bool = false,
        keep_segments: bool = false,
        can_use_heap: bool = false,
    } align(1),
    setup_move_size: u16 align(1),
    code32_start: u32 align(1),
    ramdisk_image: u32 align(1),
    ramdisk_size: u32 align(1),
    bootsect_kludge: u32 align(1),
    heap_end_ptr: u16 align(1),
    ext_loader_ver: u8 align(1),
    ext_loader_type: u8 align(1),
    cmd_line_ptr: u32 align(1),
    initrd_addr_max: u32 align(1),
    kernel_alignment: u32 align(1),
    relocatable_kernel: u8 align(1),
    min_alignment: u8 align(1),
    xloadflags: u16 align(1),
    cmdline_size: u32 align(1),
    hardware_subarch: u32 align(1),
    hardware_subarch_data: u64 align(1),
    payload_offset: u32 align(1),
    payload_length: u32 align(1),
    setup_data: u64 align(1),
    pref_address: u64 align(1),
    init_size: u32 align(1),
    handover_offset: u32 align(1),
    kernel_info_offset: u32 align(1),

    /// sector size, in bytes
    pub const sector_size = 512;

    pub fn from(bytes: []const u8) SetupHeader {
        var hdr = std.mem.bytesToValue(
            @This(),
            bytes[0..@sizeOf(@This())],
        );
        if (hdr.setup_sects == 0)
            hdr.setup_sects = 4;

        return hdr;
    }

    /// Get the offset of the protected-mode kernel code.
    /// Real-mode code consists of the boot sector
    /// plus the setup code (`setup_sects` sectors).
    pub fn protectedCodeOffset(self: *const SetupHeader) usize {
        return (@as(usize, self.setup_sects) + 1) * sector_size;
    }
};

pub const ScreenInfo = extern struct {
    /// 0x00
    orig_x: u8 align(1),
    /// 0x01
    orig_y: u8 align(1),
    /// 0x02
    ext_mem_k: u16 align(1),
    /// 0x04
    orig_video_page: u16 align(1),
    /// 0x06
    orig_video_mode: u8 align(1),
    /// 0x07
    orig_video_cols: u8 align(1),
    /// 0x08
    flags: u8 align(1),
    /// 0x09
    unused2: u8 align(1),
    /// 0x0a
    orig_video_ega_bx: u16 align(1),
    /// 0x0c
    unused3: u16 align(1),
    /// 0x0e
    orig_video_lines: u8 align(1),
    /// 0x0f
    orig_video_is_vga: u8 align(1),
    /// 0x10
    orig_video_points: u16 align(1),

    /// VESA graphic mode -- linear frame buffer
    /// 0x12
    lfb_width: u16 align(1),
    /// 0x14
    lfb_height: u16 align(1),
    /// 0x16
    lfb_depth: u16 align(1),
    /// 0x18
    lfb_base: u32 align(1),
    /// 0x1c
    lfb_size: u32 align(1),
    /// 0x20
    cl_magic: u16 align(1),
    /// 0x22
    cl_offset: u16 align(1),
    /// 0x24
    lfb_linelength: u16 align(1),
    /// 0x26
    red_size: u8 align(1),
    /// 0x27
    red_pos: u8 align(1),
    /// 0x28
    green_size: u8 align(1),
    /// 0x29
    green_pos: u8 align(1),
    /// 0x2a
    blue_size: u8 align(1),
    /// 0x2b
    blue_pos: u8 align(1),
    /// 0x2c
    rsvd_size: u8 align(1),
    /// 0x2d
    rsvd_pos: u8 align(1),
    /// 0x2e
    vesapm_seg: u16 align(1),
    /// 0x30
    vesapm_off: u16 align(1),
    /// 0x32
    pages: u16 align(1),
    /// 0x34
    vesa_attributes: u16 align(1),
    /// 0x36
    capabilities: u32 align(1),
    /// 0x3a
    ext_lfb_base: u32 align(1),
    /// 0x3e
    _reserved: [2]u8 align(1),
};

pub const ApmBiosInfo = extern struct {
    version: u16 align(1),
    cseg: u16 align(1),
    offset: u32 align(1),
    cseg_16: u16 align(1),
    dseg: u16 align(1),
    flags: u16 align(1),
    cseg_len: u16 align(1),
    cseg_16_len: u16 align(1),
    dseg_len: u16 align(1),
};

pub const IstInfo = extern struct {
    signature: u32 align(1),
    command: u32 align(1),
    event: u32 align(1),
    perf_level: u32 align(1),
};

pub const SysDescTable = extern struct {
    length: u16 align(1),
    table: [14]u8 align(1),
};

pub const OlpcOfwHeader = extern struct {
    /// OFW signature
    ofw_magic: u32 align(1),
    ofw_version: u32 align(1),
    /// callback into OFW
    cif_handler: u32 align(1),
    irq_desc_table: u32 align(1),
};

pub const EdidInfo = extern struct {
    dummy: [128]u8 align(1),
};

pub const EfiInfo = extern struct {
    efi_loader_signature: u32 align(1),
    efi_systab: u32 align(1),
    efi_memdesc_size: u32 align(1),
    efi_memdesc_version: u32 align(1),
    efi_memmap: u32 align(1),
    efi_memmap_size: u32 align(1),
    efi_systab_hi: u32 align(1),
    efi_memmap_hi: u32 align(1),
};

/// The E820 types known to the kernel.
///
/// Originally defined in the linux source tree:
/// `linux/arch/x86/include/asm/e820/types.h`
pub const E820Type = enum(u32) {
    ram = 1,
    reserved = 2,
    acpi = 3,
    nvs = 4,
    unusable = 5,
    pmem = 7,
    pram = 12,
    soft_reserved = 0xefffffff,
    reserved_kern = 128,
};

pub const BootE820Entry = extern struct {
    addr: u64 align(1),
    size: u64 align(1),
    type: E820Type align(1),
};

const e820_max_entries_zeropage: usize = 128;

pub const EddDeviceParams = extern struct {
    // TODO: We currently have no plans to support the edd device, and Zig
    // does not (yet) have unnamed/anonymous fields to implement this FFI
    // neatly. So we put a dummy implementation here conforming to the
    // BootParams struct ABI.
    _dummy: [(0xeec - 0xd00) / 6 - 8]u8 align(1),
};

pub const EddInfo = extern struct {
    device: u8 align(1),
    version: u8 align(1),
    interface_support: u16 align(1),
    legacy_max_cylinder: u16 align(1),
    legacy_max_head: u8 align(1),
    legacy_sectors_per_track: u8 align(1),
    params: EddDeviceParams align(1),
};

const edd_mbr_sig_max: usize = 16;
const eddmaxnr: usize = 6;

comptime {
    // the zero page is exactly one 4KiB page, and the kernel finds these by offset
    std.debug.assert(@sizeOf(BootParams) == 0x1000);
    std.debug.assert(@offsetOf(BootParams, "hdr") == 0x1f1);
    std.debug.assert(@offsetOf(BootParams, "e820_entries") == 0x1e8);
    std.debug.assert(@offsetOf(BootParams, "e820_table") == 0x2d0);
    std.debug.assert(@sizeOf(SetupHeader) == 0x7b);
    std.debug.assert(@sizeOf(ScreenInfo) == 0x40);
    std.debug.assert(@sizeOf(BootE820Entry) == 20);
    std.debug.assert(@sizeOf(EddInfo) == 82);
}

fn expectOffset(offset: usize, comptime T: type, comptime field_name: []const u8) !void {
    try testing.expectEqual(offset, @offsetOf(T, field_name));
}

test "screen_info_offsets" {
    try expectOffset(0x00, ScreenInfo, "orig_x");
    try expectOffset(0x01, ScreenInfo, "orig_y");
    try expectOffset(0x02, ScreenInfo, "ext_mem_k");
    try expectOffset(0x04, ScreenInfo, "orig_video_page");
    try expectOffset(0x06, ScreenInfo, "orig_video_mode");
    try expectOffset(0x07, ScreenInfo, "orig_video_cols");
    try expectOffset(0x08, ScreenInfo, "flags");
    try expectOffset(0x09, ScreenInfo, "unused2");
    try expectOffset(0x0a, ScreenInfo, "orig_video_ega_bx");
    try expectOffset(0x0c, ScreenInfo, "unused3");
    try expectOffset(0x0e, ScreenInfo, "orig_video_lines");
    try expectOffset(0x0f, ScreenInfo, "orig_video_is_vga");
    try expectOffset(0x10, ScreenInfo, "orig_video_points");
    try expectOffset(0x12, ScreenInfo, "lfb_width");
    try expectOffset(0x14, ScreenInfo, "lfb_height");
    try expectOffset(0x16, ScreenInfo, "lfb_depth");
    try expectOffset(0x18, ScreenInfo, "lfb_base");
    try expectOffset(0x1c, ScreenInfo, "lfb_size");
    try expectOffset(0x20, ScreenInfo, "cl_magic");
    try expectOffset(0x22, ScreenInfo, "cl_offset");
    try expectOffset(0x24, ScreenInfo, "lfb_linelength");
    try expectOffset(0x26, ScreenInfo, "red_size");
    try expectOffset(0x27, ScreenInfo, "red_pos");
    try expectOffset(0x28, ScreenInfo, "green_size");
    try expectOffset(0x29, ScreenInfo, "green_pos");
    try expectOffset(0x2a, ScreenInfo, "blue_size");
    try expectOffset(0x2b, ScreenInfo, "blue_pos");
    try expectOffset(0x2c, ScreenInfo, "rsvd_size");
    try expectOffset(0x2d, ScreenInfo, "rsvd_pos");
    try expectOffset(0x2e, ScreenInfo, "vesapm_seg");
    try expectOffset(0x30, ScreenInfo, "vesapm_off");
    try expectOffset(0x32, ScreenInfo, "pages");
    try expectOffset(0x34, ScreenInfo, "vesa_attributes");
    try expectOffset(0x36, ScreenInfo, "capabilities");
    try expectOffset(0x3a, ScreenInfo, "ext_lfb_base");
}

test "boot_params_offsets" {
    try expectOffset(0x000, BootParams, "screen_info");
    try expectOffset(0x040, BootParams, "apm_bios_info");
    try expectOffset(0x058, BootParams, "tboot_addr");
    try expectOffset(0x060, BootParams, "ist_info");
    try expectOffset(0x070, BootParams, "acpi_rsdp_addr");
    try expectOffset(0x080, BootParams, "hd0_info");
    try expectOffset(0x090, BootParams, "hd1_info");
    try expectOffset(0x0a0, BootParams, "sys_desc_table");
    try expectOffset(0x0b0, BootParams, "olpc_ofw_header");
    try expectOffset(0x0c0, BootParams, "ext_ramdisk_image");
    try expectOffset(0x0c4, BootParams, "ext_ramdisk_size");
    try expectOffset(0x0c8, BootParams, "ext_cmd_line_ptr");
    try expectOffset(0x13c, BootParams, "cc_blob_address");
    try expectOffset(0x140, BootParams, "edid_info");
    try expectOffset(0x1c0, BootParams, "efi_info");
    try expectOffset(0x1e0, BootParams, "alt_mem_k");
    try expectOffset(0x1e4, BootParams, "scratch");
    try expectOffset(0x1e8, BootParams, "e820_entries");
    try expectOffset(0x1e9, BootParams, "eddbuf_entries");
    try expectOffset(0x1ea, BootParams, "edd_mbr_sig_buf_entries");
    try expectOffset(0x1eb, BootParams, "kbd_status");
    try expectOffset(0x1ec, BootParams, "secure_boot");
    try expectOffset(0x1ef, BootParams, "sentinel");
    try expectOffset(0x1f1, BootParams, "hdr");
    try expectOffset(0x290, BootParams, "edd_mbr_sig_buffer");
    try expectOffset(0x2d0, BootParams, "e820_table");
    try expectOffset(0xd00, BootParams, "eddbuf");
}
