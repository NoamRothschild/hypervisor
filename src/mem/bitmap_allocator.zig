const std = @import("std");
const hhdm = @import("hhdm.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const PhysAddr = @import("allocator.zig").PhysAddr;

/// Hands out contiguous runs of `size`-byte blocks from the physical region
/// `[base, base + capacity * size)`. Bookkeeping is one bit per block,
/// stored in `backing`.
pub fn BitmapAllocator(comptime size: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(size));

    return struct {
        const Self = @This();

        pub const block_size = size;
        pub const State = enum { free, used };

        backing: Allocator,
        base: PhysAddr,
        /// set - free block, clear - used / unusable block
        avail: std.DynamicBitSetUnmanaged,

        /// Manages every whole block of `[base, base + len)`; `base` must be block aligned.
        pub fn init(backing: Allocator, base: PhysAddr, len: usize, initial: State) Allocator.Error!Self {
            std.debug.assert(base % block_size == 0);
            const avail: std.DynamicBitSetUnmanaged = switch (initial) {
                .free => try .initFull(backing, len / block_size),
                .used => try .initEmpty(backing, len / block_size),
            };
            return .{ .backing = backing, .base = base, .avail = avail };
        }

        pub fn deinit(self: *Self) void {
            self.avail.deinit(self.backing);
        }

        /// Marks free every block lying entirely inside `[addr, addr + len)`.
        pub fn markFree(self: *Self, addr: PhysAddr, len: usize) void {
            self.markRegion(addr, len, .free);
        }

        /// Marks used every block touching `[addr, addr + len)`.
        pub fn markUsed(self: *Self, addr: PhysAddr, len: usize) void {
            self.markRegion(addr, len, .used);
        }

        pub fn alloc(self: *Self, count: usize) Allocator.Error!PhysAddr {
            return self.allocAligned(count, .fromByteUnits(block_size));
        }

        /// Reserves `count` contiguous blocks whose first address is `alignment` aligned.
        pub fn allocAligned(self: *Self, count: usize, alignment: Alignment) Allocator.Error!PhysAddr {
            std.debug.assert(count > 0);
            var start = self.alignedIndex(0, alignment);
            while (start + count <= self.avail.capacity()) {
                start = for (start..start + count) |i| {
                    if (!self.avail.isSet(i)) break self.alignedIndex(i + 1, alignment);
                } else {
                    self.avail.setRangeValue(.{ .start = start, .end = start + count }, false);
                    return self.addrOf(start);
                };
            }
            return error.OutOfMemory;
        }

        pub fn free(self: *Self, addr: PhysAddr, count: usize) void {
            std.debug.assert(addr % block_size == 0);
            const first = self.indexOf(addr);
            for (first..first + count) |i| std.debug.assert(!self.avail.isSet(i)); // double free
            self.avail.setRangeValue(.{ .start = first, .end = first + count }, true);
        }

        pub fn availBlocks(self: *const Self) usize {
            return self.avail.count();
        }

        /// Hands out HHDM-mapped slices, each rounded up to whole blocks.
        pub fn allocator(self: *Self) Allocator {
            return .{ .ptr = self, .vtable = &.{
                .alloc = vAlloc,
                .resize = vResize,
                .remap = vRemap,
                .free = vFree,
            } };
        }

        fn end(self: *const Self) PhysAddr {
            return self.addrOf(self.avail.capacity());
        }

        fn addrOf(self: *const Self, index: usize) PhysAddr {
            return self.base + index * block_size;
        }

        fn indexOf(self: *const Self, addr: PhysAddr) usize {
            return (addr - self.base) / block_size;
        }

        /// first block index >= `index` whose address is `alignment` aligned
        fn alignedIndex(self: *const Self, index: usize, alignment: Alignment) usize {
            return self.indexOf(alignment.forward(self.addrOf(index)));
        }

        /// `.free` rounds the region inwards, `.used` rounds it outwards
        fn markRegion(self: *Self, addr: PhysAddr, len: usize, state: State) void {
            const lo = std.math.clamp(addr, self.base, self.end());
            const hi = std.math.clamp(addr +| len, self.base, self.end());
            const start, const stop = switch (state) {
                .free => .{ std.mem.alignForward(PhysAddr, lo, block_size), std.mem.alignBackward(PhysAddr, hi, block_size) },
                .used => .{ std.mem.alignBackward(PhysAddr, lo, block_size), std.mem.alignForward(PhysAddr, hi, block_size) },
            };
            if (start < stop)
                self.avail.setRangeValue(.{ .start = self.indexOf(start), .end = self.indexOf(stop) }, state == .free);
        }

        fn blocksFor(len: usize) usize {
            return std.math.divCeil(usize, len, block_size) catch unreachable;
        }

        fn vAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const addr = self.allocAligned(blocksFor(len), alignment) catch return null;
            return @ptrFromInt(hhdm.virtOf(addr));
        }

        /// in place only while the block count stays the same
        fn vResize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
            return blocksFor(memory.len) == blocksFor(new_len);
        }

        fn vRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            return if (vResize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
        }

        fn vFree(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.free(hhdm.physOf(memory.ptr), blocksFor(memory.len));
        }
    };
}

const Page4K = BitmapAllocator(0x1000);

test "alloc hands out contiguous runs and free reclaims them" {
    var ba: Page4K = try .init(std.testing.allocator, 0x10000, 4 * 0x1000, .free);
    defer ba.deinit();

    try std.testing.expectEqual(0x10000, try ba.alloc(1));
    try std.testing.expectEqual(0x11000, try ba.alloc(3));
    try std.testing.expectError(error.OutOfMemory, ba.alloc(1));

    ba.free(0x11000, 3);
    try std.testing.expectEqual(0x11000, try ba.alloc(2));
    try std.testing.expectEqual(1, ba.availBlocks());
}

test "allocAligned skips misaligned candidate runs" {
    var ba: Page4K = try .init(std.testing.allocator, 0x1000, 0x10000, .free);
    defer ba.deinit();

    try std.testing.expectEqual(0x4000, try ba.allocAligned(2, .fromByteUnits(0x4000)));
    try std.testing.expectEqual(0x8000, try ba.allocAligned(2, .fromByteUnits(0x4000)));
}

test "markFree rounds inwards, markUsed rounds outwards" {
    var ba: Page4K = try .init(std.testing.allocator, 0, 8 * 0x1000, .used);
    defer ba.deinit();

    ba.markFree(0x800, 0x3000); // only [0x1000, 0x3000) is whole
    try std.testing.expectEqual(2, ba.availBlocks());

    ba.markUsed(0x2fff, 1); // touches [0x2000, 0x3000)
    try std.testing.expectEqual(1, ba.availBlocks());

    ba.markFree(0x7000, 0x100000); // clamped to the managed region
    try std.testing.expectEqual(2, ba.availBlocks());
}
