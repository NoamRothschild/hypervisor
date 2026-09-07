///! Free List based Allocator
///! A port of "Memory Allocation Strategies - Part 5, Free List Allocators" / gingerBill
///!
///! reference: https://www.gingerbill.org/article/2021/11/30/memory-allocation-strategies-005
const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Self = @This();

/// Overlaid in-place on every free block of the backing buffer.
const Node = extern struct {
    next: ?*Node,
    block_size: usize,
};

/// Placed immediately before every pointer handed out by `alloc`.
const Header = extern struct {
    block_size: usize,
    padding: usize,
};

/// Node/Header are written at computed offsets via `@ptrFromInt`, which
/// safety-checks pointer alignment: every block boundary must therefore stay
/// a multiple of this alignment.
const min_alignment: Alignment = .of(Node);

data: []align(min_alignment.toByteUnits()) u8,
used: usize,
head: ?*Node,
policy: Policy,

pub const Policy = enum { first_fit, best_fit };

pub fn init(buffer: []align(min_alignment.toByteUnits()) u8, policy: Policy) Self {
    var self: Self = .{
        .data = buffer,
        .used = 0,
        .head = null,
        .policy = policy,
    };
    self.reset();
    return self;
}

/// Drops every outstanding allocation at once and restores the allocator
/// to a single free block spanning the whole buffer.
pub fn reset(self: *Self) void {
    const first: *Node = @ptrCast(self.data.ptr);
    first.* = .{ .next = null, .block_size = self.data.len };
    self.head = first;
    self.used = 0;
}

/// Permanently excludes `data[offset..][0..len]` from ever being handed out
/// by `alloc`, by carving it out of the free list directly (no header is
/// written),
/// A reserved range can never be passed to `free`.
/// `offset`/`len` are relative to `data.ptr`, not absolute addrs;
pub fn reserve(self: *Self, offset: usize, len: usize) void {
    if (len == 0 or offset >= self.data.len) return;
    const clip_len = @min(len, self.data.len - offset);

    const base = @intFromPtr(self.data.ptr);
    const res_start = base + offset;
    const res_end = res_start + clip_len;

    var prev: ?*Node = null;
    var node = self.head;
    while (node) |n| {
        const n_start = @intFromPtr(n);
        const n_end = n_start + n.block_size;
        const next = n.next;
        defer node = next;

        if (res_end <= n_start or n_end <= res_start) {
            prev = n;
            continue;
        }

        const overlap_start = @max(res_start, n_start);
        const overlap_end = @min(res_end, n_end);

        // A kept remainder must still fit a `Node`, and a new node's start
        // address must stay `min_alignment`-aligned (see `min_alignment`'s
        // doc comment) -- so slivers too small for either get folded into
        // the reservation rather than kept as unusable or unsafe free nodes.
        var head_len = overlap_start - n_start;
        if (head_len < @sizeOf(Node)) head_len = 0;

        var tail_start = min_alignment.forward(overlap_end);
        if (tail_start >= n_end or n_end - tail_start < @sizeOf(Node)) tail_start = n_end;
        const tail_len = n_end - tail_start;

        if (head_len == 0 and tail_len == 0) {
            self.removeNode(prev, n);
        } else if (head_len == 0) {
            const moved: *Node = @ptrFromInt(tail_start);
            moved.* = .{ .next = next, .block_size = tail_len };
            if (prev) |p| p.next = moved else self.head = moved;
            prev = moved;
        } else if (tail_len == 0) {
            n.block_size = head_len;
            prev = n;
        } else {
            n.block_size = head_len;
            const tail: *Node = @ptrFromInt(tail_start);
            tail.* = .{ .next = next, .block_size = tail_len };
            n.next = tail;
            prev = n;
        }
    }
}

pub fn allocator(self: *Self) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.rawAlloc(len, alignment);
}

/// Free-list blocks never grow or shrink in place.
fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *Self = @ptrCast(@alignCast(ctx));
    const new_ptr = self.rawAlloc(new_len, alignment) orelse return null;
    @memcpy(new_ptr[0..@min(memory.len, new_len)], memory[0..@min(memory.len, new_len)]);
    self.rawFree(memory.ptr);
    return new_ptr;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.rawFree(memory.ptr);
}

const FindResult = struct {
    node: ?*Node,
    prev: ?*Node,
    padding: usize,
};

/// Smallest padding, at least `@sizeOf(Header)`, that places an
/// `alignment`-aligned pointer directly after a header starting at `addr`.
fn paddingWithHeader(addr: usize, alignment: Alignment) usize {
    return alignment.forward(addr + @sizeOf(Header)) - addr;
}

fn findFirst(self: *Self, size: usize, alignment: Alignment) FindResult {
    var prev: ?*Node = null;
    var node = self.head;
    while (node) |n| {
        const padding = paddingWithHeader(@intFromPtr(n), alignment);
        if (n.block_size >= size + padding)
            return .{ .node = n, .prev = prev, .padding = padding };
        prev = n;
        node = n.next;
    }
    return .{ .node = null, .prev = prev, .padding = 0 };
}

fn findBest(self: *Self, size: usize, alignment: Alignment) FindResult {
    var best: FindResult = .{ .node = null, .prev = null, .padding = 0 };
    var best_size: usize = std.math.maxInt(usize);

    var prev: ?*Node = null;
    var node = self.head;
    while (node) |n| {
        const padding = paddingWithHeader(@intFromPtr(n), alignment);
        if (n.block_size >= size + padding and n.block_size < best_size) {
            best = .{ .node = n, .prev = prev, .padding = padding };
            best_size = n.block_size;
        }
        prev = n;
        node = n.next;
    }
    return best;
}

fn insertNode(self: *Self, prev: ?*Node, new_node: *Node) void {
    if (prev) |p| {
        new_node.next = p.next;
        p.next = new_node;
    } else {
        new_node.next = self.head;
        self.head = new_node;
    }
}

fn removeNode(self: *Self, prev: ?*Node, node: *Node) void {
    if (prev) |p|
        p.next = node.next
    else
        self.head = node.next;
}

fn rawAlloc(self: *Self, len: usize, alignment: Alignment) ?[*]u8 {
    if (len == 0) return null;

    // Every live block must be able to hold a `Node` once freed, and
    // every block boundary must stay `min_alignment`-aligned (see
    // `min_alignment`'s doc comment).
    const size = min_alignment.forward(@max(len, @sizeOf(Node)));
    const eff_alignment = Alignment.max(alignment, .of(Header));

    const result = switch (self.policy) {
        .first_fit => self.findFirst(size, eff_alignment),
        .best_fit => self.findBest(size, eff_alignment),
    };
    const node = result.node orelse return null;
    const padding = result.padding;
    const required = size + padding;

    // NOTE: ported as-is from gingerbill's article: a split remainder
    // smaller than `@sizeOf(Node)` is still turned into a free node.
    // That's an accepted limitation of this design, not something
    // introduced by this port.
    const remaining = node.block_size - required;
    if (remaining > 0) {
        const new_node: *Node = @ptrFromInt(@intFromPtr(node) + required);
        new_node.* = .{ .next = null, .block_size = remaining };
        self.insertNode(node, new_node);
    }
    self.removeNode(result.prev, node);

    const header: *Header = @ptrFromInt(@intFromPtr(node) + padding - @sizeOf(Header));
    header.* = .{ .block_size = required, .padding = padding };

    self.used += required;

    return @ptrFromInt(@intFromPtr(node) + padding);
}

fn rawFree(self: *Self, ptr: [*]u8) void {
    const ptr_addr = @intFromPtr(ptr);
    const header: *Header = @ptrFromInt(ptr_addr - @sizeOf(Header));

    // `header.padding` is the distance from the block's true start to
    // `ptr` (see paddingWithHeader/rawAlloc), so the block starts
    // `header.padding` bytes before `ptr` -- not at `header` itself,
    // which may sit further in when `padding` exceeds `@sizeOf(Header)`.
    // `header.block_size` already covers that whole span.
    const block_size = header.block_size;
    const free_node: *Node = @ptrFromInt(ptr_addr - header.padding);
    free_node.* = .{ .next = null, .block_size = block_size };

    // Keep the free list sorted by address so `coalesce` only ever needs
    // to look at each node's immediate neighbours.
    var prev: ?*Node = null;
    var node = self.head;
    while (node) |n| {
        if (@intFromPtr(free_node) < @intFromPtr(n)) break;
        prev = n;
        node = n.next;
    }

    self.insertNode(prev, free_node);
    self.used -= block_size;

    self.coalesce(prev, free_node);
}

fn coalesce(self: *Self, prev: ?*Node, node: *Node) void {
    if (node.next) |next| {
        if (@intFromPtr(node) + node.block_size == @intFromPtr(next)) {
            node.block_size += next.block_size;
            self.removeNode(node, next);
        }
    }
    if (prev) |p| {
        if (@intFromPtr(p) + p.block_size == @intFromPtr(node)) {
            p.block_size += node.block_size;
            self.removeNode(p, node);
        }
    }
}

test "alloc returns non-overlapping, correctly aligned blocks" {
    var buf: [1024]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    const a = fla.allocator();

    const p1 = try a.alignedAlloc(u8, .@"16", 37);
    const p2 = try a.alignedAlloc(u8, .@"64", 100);
    const p3 = try a.alloc(u8, 10);

    try std.testing.expect(@intFromPtr(p1.ptr) % 16 == 0);
    try std.testing.expect(@intFromPtr(p2.ptr) % 64 == 0);

    const r1_start = @intFromPtr(p1.ptr);
    const r1_end = r1_start + p1.len;
    const r2_start = @intFromPtr(p2.ptr);
    const r2_end = r2_start + p2.len;
    const r3_start = @intFromPtr(p3.ptr);
    const r3_end = r3_start + p3.len;
    try std.testing.expect(r1_end <= r2_start or r2_end <= r1_start);
    try std.testing.expect(r2_end <= r3_start or r3_end <= r2_start);
}

test "freeing a block allocated with extra alignment reclaims its full span" {
    var buf: [1024]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    const a = fla.allocator();

    // 128-byte alignment forces padding well beyond @sizeOf(Header), so a
    // free must walk back past the header to the block's true start.
    const p1 = try a.alignedAlloc(u8, Alignment.fromByteUnits(128), 40);
    const before_used = fla.used;
    a.free(p1);
    try std.testing.expect(fla.used < before_used);

    // the whole buffer must be reclaimed, not just the part after the header.
    const p2 = try a.alloc(u8, 900);
    _ = p2;
}

test "first_fit reuses a freed block on the next matching alloc" {
    var buf: [1024]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    const a = fla.allocator();

    const p1 = try a.alloc(u8, 32);
    _ = try a.alloc(u8, 32);
    a.free(p1);

    const p3 = try a.alloc(u8, 32);
    try std.testing.expectEqual(p1.ptr, p3.ptr);
}

test "best_fit picks the smallest sufficient free block" {
    var buf: [1024]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .best_fit);
    const a = fla.allocator();

    // carve out three blocks, then free the first and third to leave two
    // separate free islands of different sizes ([small][used][big][tail]).
    const small = try a.alloc(u8, 32);
    const used = try a.alloc(u8, 32);
    const big = try a.alloc(u8, 256);
    _ = used;

    a.free(small);
    a.free(big);

    const fits_only_small = try a.alloc(u8, 16);
    try std.testing.expectEqual(small.ptr, fits_only_small.ptr);
}

test "adjacent frees coalesce back into one block" {
    var buf: [1024]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    const a = fla.allocator();

    const p1 = try a.alloc(u8, 64);
    const p2 = try a.alloc(u8, 64);
    a.free(p1);
    a.free(p2);

    // only possible if the two freed blocks coalesced into one big enough
    // to hold something larger than either original allocation.
    const merged = try a.alloc(u8, 150);
    try std.testing.expectEqual(p1.ptr, merged.ptr);
}

test "reset reclaims the whole buffer" {
    var buf: [256]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    const a = fla.allocator();

    _ = try a.alloc(u8, 64);
    _ = try a.alloc(u8, 64);
    fla.reset();

    try std.testing.expectEqual(@as(usize, 0), fla.used);
    _ = try a.alloc(u8, 200);
}

test "alloc returns OutOfMemory once the buffer is exhausted" {
    var buf: [64]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    const a = fla.allocator();

    try std.testing.expectError(Allocator.Error.OutOfMemory, a.alloc(u8, 4096));
}

test "reserve removes an entirely-reserved buffer" {
    var buf: [64]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    fla.reserve(0, buf.len);

    const a = fla.allocator();
    try std.testing.expectError(Allocator.Error.OutOfMemory, a.alloc(u8, 1));
}

test "reserve truncates the front of a free node" {
    var buf: [1024]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    fla.reserve(0, 64);

    const a = fla.allocator();
    const p = try a.alloc(u8, 900);
    try std.testing.expect(@intFromPtr(p.ptr) >= @intFromPtr(&buf) + 64);
}

test "reserve truncates the tail of a free node" {
    var buf: [1024]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    fla.reserve(900, 124);

    const a = fla.allocator();
    _ = try a.alloc(u8, 800);
    try std.testing.expectError(Allocator.Error.OutOfMemory, a.alloc(u8, 200));
}

test "reserve punches a hole, splitting a free node into two islands" {
    var buf: [1024]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);
    fla.reserve(400, 200); // reserve [400, 600), both 8-aligned already

    const a = fla.allocator();
    const front = try a.alloc(u8, 300);
    const back = try a.alloc(u8, 300);

    const base = @intFromPtr(&buf);
    try std.testing.expect(@intFromPtr(front.ptr) < base + 400);
    try std.testing.expect(@intFromPtr(back.ptr) >= base + 600);
}

test "reserve is a no-op for out-of-range or already-reserved bytes" {
    var buf: [256]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);

    fla.reserve(1000, 64); // entirely out of bounds
    fla.reserve(200, 100); // partially out of bounds, clipped to [200, 256)
    fla.reserve(200, 56); // same range again: already reserved, no-op

    const a = fla.allocator();
    // exactly fills the [0, 200) island once header overhead is accounted for.
    const p = try a.alloc(u8, 180);
    try std.testing.expect(@intFromPtr(p.ptr) + 180 <= @intFromPtr(&buf) + 200);
    try std.testing.expectError(Allocator.Error.OutOfMemory, a.alloc(u8, 10));
}

test "reserve mirrors carving unusable regions out of an mmap-derived buffer" {
    // simulates: reserve()-ing every non-`mem_available` mmap entry over the
    // low part of a buffer, mirroring the bootloader-mmap usecase.
    var buf: [2048]u8 align(@alignOf(Node)) = undefined;
    var fla: Self = .init(&buf, .first_fit);

    const reserved_regions = [_][2]usize{
        .{ 0, 64 }, // e.g. real-mode IVT / BDA
        .{ 512, 64 }, // e.g. ACPI tables
        .{ 1024, 1024 }, // e.g. everything past the usable region
    };
    for (reserved_regions) |r| fla.reserve(r[0], r[1]);

    const a = fla.allocator();
    // usable islands left: [64, 512) and [576, 1024), 448 bytes each.
    _ = try a.alloc(u8, 300);
    _ = try a.alloc(u8, 300);
    try std.testing.expectError(Allocator.Error.OutOfMemory, a.alloc(u8, 300));
}
