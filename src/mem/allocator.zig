const std = @import("std");
const hhdm = @import("hhdm.zig");
const mbt2 = @import("../arch/x86_64/multiboot2.zig");
const paging = @import("../arch/x86_64/paging.zig");

pub const PhysAddr = u64;
pub const VirtAddr = u64;

const FreeListAllocator = @import("fla.zig");
const BitmapAllocator = @import("bitmap_allocator.zig").BitmapAllocator;
const Allocator = std.mem.Allocator;

const PageBitmap = BitmapAllocator(0x1000);

/// how many 4KB pages the page pool is carved out of the fla for (512KB)
pub const page_pool_pages: usize = 128;

pub const KAlloc = struct {
    pub const page_size = PageBitmap.block_size;

    fla: FreeListAllocator,
    /// 4KB-aligned pool, carved out of `fla` on init
    pages: PageBitmap,

    /// Initializes `self` in place -- the page pool keeps a pointer to
    /// `self.fla`, so a `KAlloc` must not be moved once initialized.
    pub fn init(self: *KAlloc) void {
        const buf: *[1 << 30]u8 = @ptrFromInt(0x0 | hhdm.virt_base);
        self.* = .{
            .fla = .init(@alignCast(buf), .first_fit),
            .pages = undefined,
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

        // the pool itself and the bitmap tracking it both live inside `fla`
        const pool = self.fla.allocator().alignedAlloc(
            u8,
            .fromByteUnits(page_size),
            page_pool_pages * page_size,
        ) catch @panic("kalloc: not enough space for the 4KB page pool");

        self.pages = PageBitmap.init(self.fla.allocator(), hhdm.physOf(pool.ptr), pool.len, .free) catch
            @panic("kalloc: not enough space for the page pool bitmap");
    }

    pub inline fn allocator(self: *KAlloc) Allocator {
        return self.fla.allocator();
    }

    pub inline fn alloc(self: *KAlloc, comptime T: type, n: usize) Allocator.Error![]T {
        return self.allocator().alloc(T, n);
    }

    pub inline fn create(self: *KAlloc, comptime T: type) Allocator.Error!*T {
        return self.allocator().create(T);
    }

    pub inline fn dupe(self: *KAlloc, comptime T: type, m: []const T) Allocator.Error![]T {
        return self.allocator().dupe(T, m);
    }

    pub inline fn free(self: *KAlloc, memory: anytype) void {
        self.allocator().free(memory);
    }

    pub inline fn destroy(self: *KAlloc, ptr: anytype) void {
        self.allocator().destroy(ptr);
    }

    /// Allocates `count` contiguous 4KB pages from the page pool.
    pub fn allocPages(self: *KAlloc, count: usize) Allocator.Error![]align(page_size) u8 {
        const addr = try self.pages.alloc(count);
        const ptr: [*]align(page_size) u8 = @ptrFromInt(hhdm.virtOf(addr));
        return ptr[0 .. count * page_size];
    }

    pub fn freePages(self: *KAlloc, pages: []align(page_size) u8) void {
        self.pages.free(hhdm.physOf(pages.ptr), pages.len / page_size);
    }

    /// single page out of the pool
    pub fn allocPage(self: *KAlloc) Allocator.Error!*align(page_size) [page_size]u8 {
        return @ptrCast((try self.allocPages(1)).ptr);
    }

    pub fn freePage(self: *KAlloc, page: *align(page_size) [page_size]u8) void {
        self.freePages(page);
    }
};

pub var kalloc: KAlloc = undefined;

/// should be called once on boot
///  then, for any subsequent calls to kalloc,
///  use the pub var `kalloc`.
pub fn init() void {
    kalloc.init();
}
