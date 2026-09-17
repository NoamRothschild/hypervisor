const std = @import("std");
const hhdm = @import("../../mem/hhdm.zig");

export var mbd_raw: u32 linksection(".bss.boot") = undefined;
pub var magic: u32 = undefined;

comptime {
    @export(&magic, .{ .name = "mbt2_magic", .section = ".bss.boot" });
}

/// This should be in %eax.
pub const bootloader_magic = 0x36d76289;

pub inline fn mbd() *align(4) anyopaque {
    return @ptrFromInt(hhdm.virtOf(@as(u64, mbd_raw)));
}

pub const TagType = enum(u32) {
    end = 0,
    cmdline = 1,
    boot_loader_name = 2,
    module = 3,
    basic_meminfo = 4,
    bootdev = 5,
    mmap = 6,
    vbe = 7,
    framebuffer = 8,
    elf_sections = 9,
    apm = 10,
    efi32 = 11,
    efi64 = 12,
    smbios = 13,
    acpi_old = 14,
    acpi_new = 15,
    network = 16,
    efi_mmap = 17,
    efi_bs = 18,
    efi32_ih = 19,
    efi64_ih = 20,
    load_base_addr = 21,

    // struct multiboot_tag
    // {
    //   multiboot_uint32_t type;
    //   multiboot_uint32_t size;
    // };
    pub const Tag = extern struct {
        type: TagType,
        size: u32,
    };

    // struct multiboot_tag_mmap
    // {
    //   multiboot_uint32_t type;
    //   multiboot_uint32_t size;
    //   multiboot_uint32_t entry_size;
    //   multiboot_uint32_t entry_version;
    //   struct multiboot_mmap_entry entries[0];
    // };
    pub const MMAP = extern struct {
        type: TagType,
        size: u32,
        entry_size: u32,
        entry_version: u32,

        pub fn entries(self: *const @This()) [*]MMAPEntry {
            return @ptrFromInt(@intFromPtr(self) + @sizeOf(@This()));
        }
    };

    // struct multiboot_tag_module
    // {
    //   multiboot_uint32_t type;
    //   multiboot_uint32_t size;
    //   multiboot_uint32_t mod_start;
    //   multiboot_uint32_t mod_end;
    //   char cmdline[0];
    // };
    pub const Module = extern struct {
        type: TagType,
        size: u32,
        /// physical, inclusive
        mod_start: u32,
        /// physical, exclusive
        mod_end: u32,
        // a NUL-terminated cmdline follows

        pub fn len(self: *const @This()) usize {
            return self.mod_end - self.mod_start;
        }

        /// whatever was written after the path in `module2 <path> <cmdline>`
        pub fn cmdline(self: *const @This()) []const u8 {
            const str: [*:0]const u8 = @ptrFromInt(@intFromPtr(self) + @sizeOf(@This()));
            return std.mem.span(str);
        }

        /// the module's bytes. GRUB drops modules wherever it likes, which is
        /// regularly outside the window `paging_init` maps, so go through the HHDM.
        pub fn data(self: *const @This()) []const u8 {
            const ptr: [*]const u8 = @ptrFromInt(hhdm.virtOf(@as(u64, self.mod_start)));
            return ptr[0..self.len()];
        }
    };
};

// struct multiboot_mmap_entry
// {
//   multiboot_uint64_t addr;
//   multiboot_uint64_t len;
// #define MULTIBOOT_MEMORY_AVAILABLE              1
// #define MULTIBOOT_MEMORY_RESERVED               2
// #define MULTIBOOT_MEMORY_ACPI_RECLAIMABLE       3
// #define MULTIBOOT_MEMORY_NVS                    4
// #define MULTIBOOT_MEMORY_BADRAM                 5
//   multiboot_uint32_t type;
//   multiboot_uint32_t zero;
// };
pub const MMAPEntry = extern struct {
    addr: u64,
    len: u64,
    type: enum(u32) {
        mem_available = 1,
        mem_reserved = 2,
        mem_acpi_reclaimable = 3,
        mem_nvs = 4,
        mem_badram = 5,
    },
    zero: u32,
};

pub const TagIterator = struct {
    tag: *TagType.Tag,
    end: usize,

    pub fn init() TagIterator {
        const base = @intFromPtr(mbd());
        return .{
            .tag = @ptrFromInt(base + 8),
            .end = base + @as(*u32, @ptrCast(mbd())).*,
        };
    }

    pub fn next(self: *TagIterator) ?*TagType.Tag {
        @setRuntimeSafety(false);
        if (@intFromPtr(self.tag) >= self.end) return null;

        const curr = self.tag;
        if (curr.type == .end) return null;

        // Tags are always aligned on 8-byte boundaries.
        self.tag = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(curr) + curr.size, 8));
        return curr;
    }
};

/// Returns the first tag of the given type
pub fn findTag(wanted_type: TagType) ?*TagType.Tag {
    var it: TagIterator = .init();
    while (it.next()) |tag| {
        if (tag.type == wanted_type)
            return tag;
    }
    return null;
}

/// Looks a module up by the cmdline it was given in grub.cfg.
pub fn findModule(name: []const u8) ?*TagType.Module {
    var it: TagIterator = .init();
    while (it.next()) |tag| {
        if (tag.type != .module) continue;

        const mod: *TagType.Module = @ptrCast(@alignCast(tag));
        if (std.mem.eql(u8, mod.cmdline(), name))
            return mod;
    }
    return null;
}

pub const MMAPIterator = struct {
    curr_entry: *const MMAPEntry,
    mmap_tag: *const TagType.MMAP,

    const Self = @This();
    pub fn init(mmap_tag: *const TagType.MMAP) Self {
        return Self{
            .mmap_tag = mmap_tag,
            .curr_entry = &mmap_tag.entries()[0],
        };
    }

    pub fn next(self: *Self) ?*const MMAPEntry {
        if (@intFromPtr(self.curr_entry) >= @intFromPtr(self.mmap_tag) + self.mmap_tag.size)
            return null;

        defer self.curr_entry = @ptrFromInt(
            @intFromPtr(self.curr_entry) + self.mmap_tag.entry_size,
        );

        return self.curr_entry;
    }

    pub fn reset(self: *Self) void {
        self.curr_entry = &self.mmap_tag.entries()[0];
    }
};
