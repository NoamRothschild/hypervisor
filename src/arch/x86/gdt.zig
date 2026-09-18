///! slightly modified version of
///! https://github.com/NoamRothschild/Mini-OS/blob/506930d81a0448bdd321b3b63701413d00060800/src/arch/x86/gdt.zig
const std = @import("std");

const Access = packed struct {
    // Accessed (CPU sets to 1 when segment is accessed)
    a: u1 = 0,
    // Readable (for code segments) / Writable (for data segments)
    //  Code: 1 = readable, 0 = exec-only
    //  Data: 1 = writable, 0 = read-only
    rw: u1 = 0,
    // Direction (for data) / Conforming (for code)
    //  Data: 0 = grows up, 1 = grows down
    //  Code: 0 = only at same privilege, 1 = lower privilege allowed
    dc: u1 = 0,
    // Executable (0 = data segment, 1 = code segment)
    e: u1 = 0,
    // Descriptor type (0 = system, 1 = code/data)
    s: u1 = 0,
    // Descriptor Privilege Level (0 = kernel, 3 = user)
    dpl: u2 = 0,
    // Present bit (1 = segment is present in memory)
    p: u1 = 0,
};

const kernel_code_access: Access = .{ .p = 1, .dpl = 0, .s = 1, .e = 1, .dc = 0, .rw = 1, .a = 0 };
const kernel_data_access: Access = .{ .p = 1, .dpl = 0, .s = 1, .e = 0, .dc = 0, .rw = 1, .a = 0 };
const task_state_access: Access = .{ .p = 1, .dpl = 0, .s = 0, .e = 1, .dc = 0, .rw = 0, .a = 1 };

const Flags = packed struct(u4) {
    // Available for system software (the CPU ignores it)
    avl: u1 = 0,
    // Long mode (1 = 64-bit code segment). Must be 0 when `db` is 1.
    l: u1 = 0,
    // Default operand/address size (0 = 16-bit, 1 = 32-bit)
    db: u1 = 0,
    // Granularity (0 = limit counts bytes, 1 = limit counts 4KB pages)
    g: u1 = 0,
};

pub const SegmentDescriptor = packed struct {
    limit_low: u16,
    base_low: u24,
    access: Access,
    limit_high: u4,
    flags: Flags,
    base_high: u8,
};

pub const Tss = packed struct {
    link: u16,
    _reserved1: u16,
    esp0: u32,
    ss0: u16,
    _reserved2: u16,
    esp1: u32,
    ss1: u16,
    _reserved3: u16,
    esp2: u32,
    ss2: u16,
    _reserved4: u16,
    cr3: u32,
    eip: u32,
    eflags: u32,
    eax: u32,
    ecx: u32,
    edx: u32,
    ebx: u32,
    esp: u32,
    ebp: u32,
    esi: u32,
    edi: u32,
    es: u16,
    _reserved5: u16,
    cs: u16,
    _reserved6: u16,
    ss: u16,
    _reserved7: u16,
    ds: u16,
    _reserved8: u16,
    fs: u16,
    _reserved9: u16,
    gs: u16,
    _reserved10: u16,
    ldtr: u16,
    _reserved11: u32,
    iopb: u16,
    ssp: u32,
};

pub const Descriptor = packed struct {
    size: u16,
    start: u32,
};

pub const offsets = struct {
    nulld: usize = 0,
    kernel_codeseg: usize = 1,
    kernel_dataseg: usize = 2,
    tss: usize = 3,
}{};

fn tableOffsetOf(offset: usize) usize {
    return offset * 8;
}

// FROM THE LINUX BOOT PROTOCOL:
//
// a GDT must be loaded with the descriptors for selectors
// __BOOT_CS(0x10) and __BOOT_DS(0x18);
// both descriptors must be 4G flat segment;
// __BOOT_CS must have execute/read permission, and __BOOT_DS must have read/write permission;
// CS must be __BOOT_CS and DS, ES, SS must be __BOOT_DS;

pub const code_selector: u16 = 0x10;
pub const data_selector: u16 = 0x18;

/// returns a valid GDT for the linux 32-bit boot protocol
pub fn flatProtectedMode() [4]SegmentDescriptor {
    const null_descriptor: SegmentDescriptor = @bitCast(@as(u64, 0));
    var entries = [_]SegmentDescriptor{null_descriptor} ** 4;

    entries[code_selector >> 3] = makeState(.{
        .base = 0,
        .limit = 0xFFFFF,
        .access = .{
            .p = 1,
            .dpl = 0,
            .s = 1,
            .e = 1,
            .dc = 0,
            .rw = 1,
            // accessed is on so cpu never has to write back to descriptor
            .a = 1,
        },
        .flags = .{ .g = 1, .db = 1 },
    });

    entries[data_selector >> 3] = makeState(.{
        .base = 0,
        .limit = 0xFFFFF,
        .access = .{
            .p = 1,
            .dpl = 0,
            .s = 1,
            .e = 0,
            .dc = 0,
            .rw = 1,
            // accessed is on so cpu never has to write back to descriptor
            .a = 1,
        },
        .flags = .{ .g = 1, .db = 1 },
    });

    return entries;
}

fn makeState(config: struct { limit: u20, base: u32, access: Access, flags: Flags }) SegmentDescriptor {
    return SegmentDescriptor{
        .base_low = @truncate(config.base),
        .base_high = @truncate(config.base >> 24),
        .limit_low = @truncate(config.limit),
        .limit_high = @truncate(config.limit >> 16),
        .access = config.access,
        .flags = config.flags,
    };
}
