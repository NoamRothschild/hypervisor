const paging = @import("paging.zig");
const kmain = @import("../../main.zig").kmain;

const multiboot2_header_magic = 0xe85250d6;
const grub_multiboot_architecture_i386 = 0;

pub const MultiBootHeaderV2 = extern struct {
    magic: u32 = multiboot2_header_magic,
    arch: u32 = grub_multiboot_architecture_i386,
    len: u32 = @sizeOf(MultiBootHeaderV2),
    checksum: u32 = 0x100000000 - (multiboot2_header_magic + grub_multiboot_architecture_i386 + @sizeOf(MultiBootHeaderV2)),
    end_tag: u64 = 8 << 32,
};

export const multiboot_header: MultiBootHeaderV2 align(4) linksection(".multiboot") = .{};

/// gets called at the end of entry.asm
export fn realMode64() linksection(".text.boot") callconv(.c) void {
    // TODO: set up paging properly.
    //  use the externed symbols from the linker.ld file like kernel_physical_start, kernel_physical_end
    paging.init();
    kmain();
}

// var PML4T: [512]u64 align(0x1000) = [_]u64{0} ** 512;
// var PDPT: [512]u64 align(0x1000) = [_]u64{0} ** 512;
// var PDT: [512]u64 align(0x1000) = [_]u64{0} ** 512;
// var PT: [512]u64 align(0x1000) = [_]u64{0} ** 512;
//
// const PT_ADDR_MASK = 0xffffffffff000;
// const PT_PRESENT = 1;
// const PT_READABLE = 2; // r+w
//
// const PAGE_SIZE = 0x1000;

// comptime {
//     @export(&entry_trampoline, .{ .name = "_start" });
// }
// fn entry_trampoline() align(16) linksection(".boot") callconv(.naked) noreturn {
//     asm volatile ("jmp %[start:P]"
//         :
//         : [start] "i" (&start),
//     );
// }
//
// pub fn start() callconv(.c) void {
//     // TODO: check for existence of CPUID, if exists check for long mode support
//     // for now we assume they both exist
//
//     PML4T[0] = @intFromPtr(&PDPT) & PT_ADDR_MASK | PT_PRESENT | PT_READABLE;
//     PDPT[0] = @intFromPtr(&PDT) & PT_ADDR_MASK | PT_PRESENT | PT_READABLE;
//     PDT[0] = @intFromPtr(&PT) & PT_ADDR_MASK | PT_PRESENT | PT_READABLE;
//
//     for (&PT, 0..) |*pte, i| {
//         pte.* = PAGE_SIZE * i + PT_PRESENT | PT_READABLE;
//     }
//
//     asm volatile (
//         \\ mov %cr4, %eax
//         \\ or $0x20, %eax
//         \\ mov %eax, %cr4
//         :: .{ .eax = true });
//
//     asm volatile (
//         \\ mov $0x144, %eax
//         \\ mov $0x144, %eax
//     );
// }
