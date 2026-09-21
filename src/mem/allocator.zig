const std = @import("std");
const hhdm = @import("hhdm.zig");
const mbt2 = @import("../arch/x86_64/multiboot2.zig");
const paging = @import("../arch/x86_64/paging.zig");
const PhysAddr = @import("address.zig").HostPhys;

const FreeListAllocator = @import("fla.zig");
const BitmapAllocator = @import("bitmap_allocator.zig").BitmapAllocator;
const Allocator = std.mem.Allocator;

const PageBitmap = BitmapAllocator(0x1000);

/// how many 4KB pages the page pool is carved out of the fla for (768KB)
pub const page_pool_pages: usize = 192;

pub const KAlloc = struct {
    pub const page_size = PageBitmap.block_size;

    fla: FreeListAllocator,
    /// 4KB-aligned pool, carved out of `fla` on init
    pages: PageBitmap,

    /// A physical range kept out of the free list, in `fla`-relative bytes.
    const Range = struct {
        start: u64,
        end: u64,

        fn lessThan(_: void, a: Range, b: Range) bool {
            return a.start < b.start;
        }
    };

    /// bump region + multiboot info + firmware mmap holes + bootloader modules
    const max_reserved_ranges = 64;

    /// Clamps `[start, start + len)` to the arena and appends it, dropping
    /// anything empty. Overflowing the array would silently hand reserved
    /// memory to the allocator, so it is fatal.
    fn addRange(list: *[max_reserved_ranges]Range, count: *usize, start: PhysAddr, len: u64, limit: u64) void {
        const s = @min(start.raw(), limit);
        const e = @min(start.raw() +| len, limit);
        if (e <= s) return;

        if (count.* == list.len)
            @panic("kalloc: too many reserved ranges");

        list[count.*] = .{ .start = s, .end = e };
        count.* += 1;
    }

    /// Initializes `self` in place -- the page pool keeps a pointer to
    /// `self.fla`, so a `KAlloc` must not be moved once initialized.
    pub fn init(self: *KAlloc) void {
        const buf = hhdm.virtOf(*[1 << 30]u8, .from(0));
        self.* = .{
            .fla = .init(@alignCast(buf), .first_fit),
            .pages = undefined,
        };

        // Every range has to be known before any of them is carved out.
        // `reserve` writes its bookkeeping node into the first free byte
        // following a carved range, so reserving an overlapping range later
        // leaves that node sitting inside memory that was meant to stay
        // untouched.
        var ranges: [max_reserved_ranges]Range = undefined;
        var range_count: usize = 0;

        // everything `paging`'s boot-time bump allocator has already handed
        // out, kernel image included
        addRange(&ranges, &range_count, .from(0), paging.bumpBoundary().raw(), buf.len);

        // the multiboot info struct sits wherever GRUB dropped it, which is
        // regularly inside this region and past bumpBoundary().
        const mbi = mbt2.mbd();
        addRange(&ranges, &range_count, hhdm.physOf(mbi), @as(*const u32, @ptrCast(mbi)).*, buf.len);

        const mmap_tag = mbt2.findTag(.mmap) orelse @panic("unable to find mmap tag in mb2 hdr");
        var it: mbt2.MMAPIterator = .init(@ptrCast(@alignCast(mmap_tag)));
        while (it.next()) |entry| {
            if (entry.addr >= buf.*.len)
                break;

            if (entry.type != .mem_available)
                addRange(&ranges, &range_count, .from(entry.addr), entry.len, buf.len);
        }

        var tags: mbt2.TagIterator = .init();
        while (tags.next()) |tag| {
            if (tag.type != .module) continue;

            const mod: *const mbt2.TagType.Module = @ptrCast(@alignCast(tag));
            addRange(&ranges, &range_count, .from(mod.mod_start), mod.len(), buf.len);
        }

        std.mem.sort(Range, ranges[0..range_count], {}, Range.lessThan);

        var i: usize = 0;
        while (i < range_count) : (i += 1) {
            const start = ranges[i].start;
            var end = ranges[i].end;
            // fold in every range overlapping or touching this one, so the
            // node written at `end` cannot land inside a later reservation
            while (i + 1 < range_count and ranges[i + 1].start <= end) {
                i += 1;
                end = @max(end, ranges[i].end);
            }
            self.fla.reserve(start, end - start);
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
        const ptr = hhdm.virtOf([*]align(page_size) u8, addr);
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
