const std = @import("std");
const hhdm = @import("hhdm.zig");
const mbt2 = @import("../arch/x86_64/multiboot2.zig");
const paging = @import("../arch/x86_64/paging.zig");

const FreeListAllocator = @import("fla.zig");
const Allocator = std.mem.Allocator;

const KAlloc = struct {
    fla: FreeListAllocator,

    pub fn init() KAlloc {
        const buf: *[1 << 30]u8 = @ptrFromInt(0x0 | hhdm.virt_base);
        var self = KAlloc{
            .fla = .init(@alignCast(buf), .first_fit),
        };

        // Exclude everything `paging`'s boot-time bump allocator has
        // already handed out, kernel image included
        self.fla.reserve(0, paging.bumpBoundary());

        const mmap_tag = mbt2.findTag(.mmap) orelse @panic("unable to find mmap tag in mb2 hdr");
        var it: mbt2.MMAPIterator = .init(@ptrCast(@alignCast(mmap_tag)));
        while (it.next()) |entry| {
            if (entry.addr >= buf.*.len)
                break;

            if (entry.type != .mem_available)
                self.fla.reserve(entry.addr, entry.len);
        }

        return self;
    }

    pub inline fn allocator(self: *KAlloc) Allocator {
        return self.fla.allocator();
    }
};

pub var kalloc: KAlloc = undefined;

/// should be called once on boot
///  then, for any subsequent calls to kalloc,
///  use the pub var `kalloc` instead.
pub fn init() *KAlloc {
    kalloc = .init();
    return &kalloc;
}
