const std = @import("std");
const mbt2 = @import("../arch/x86_64/multiboot2.zig");

const Allocator = std.mem.Allocator;
const PhysAddr = @import("allocator.zig").PhysAddr;
const BitmapAllocator = @import("bitmap_allocator.zig").BitmapAllocator;

/// Hands out whole, contiguous 1GB blocks of physical RAM to back guest memory.
pub const GuestAllocator = struct {
    const Bitmap = BitmapAllocator(1 << 30);
    pub const block_size = Bitmap.block_size;
    /// only the first 512GB are reachable through the HHDM
    const max_len = 512 * block_size;

    bitmap: Bitmap,

    /// `backing` only holds the bookkeeping bitset (use the kernel allocator).
    pub fn init(backing: Allocator) Allocator.Error!GuestAllocator {
        const mmap_tag = mbt2.findTag(.mmap) orelse @panic("unable to find mmap tag in mb2 hdr");
        var it: mbt2.MMAPIterator = .init(@ptrCast(@alignCast(mmap_tag)));

        var ram_end: u64 = 0;
        while (it.next()) |e| ram_end = @max(ram_end, e.addr + e.len);
        it.reset();

        var bitmap: Bitmap = try .init(backing, 0, @min(ram_end, max_len), .used);
        while (it.next()) |e| if (e.type == .mem_available) bitmap.markFree(e.addr, e.len);
        // the first GB is the kernel allocator's heap (see allocator.zig)
        bitmap.markUsed(0, block_size);

        return .{ .bitmap = bitmap };
    }

    pub fn deinit(self: *GuestAllocator) void {
        self.bitmap.deinit();
    }

    /// Reserves `count` physically contiguous blocks, returning the first one's address.
    pub fn alloc(self: *GuestAllocator, count: usize) Allocator.Error!PhysAddr {
        return self.bitmap.alloc(count);
    }

    pub fn free(self: *GuestAllocator, base: PhysAddr, count: usize) void {
        self.bitmap.free(base, count);
    }

    pub fn freeBlocks(self: *const GuestAllocator) usize {
        return self.bitmap.freeBlocks();
    }

    /// Hands out HHDM-mapped slices, each rounded up to whole blocks.
    pub fn allocator(self: *GuestAllocator) Allocator {
        return self.bitmap.allocator();
    }
};
