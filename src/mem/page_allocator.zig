const std = @import("std");
const paging = @import("../arch/x86_64/paging.zig");

pub const PhysAddr = u64;
pub const VirtAddr = u64;

pub const PageSize = enum {
    @"1 GB",
    @"2 MB",
    @"4 KB",
};

pub const PageAllocator = struct {
    pub fn alloc(self: *PageAllocator, ps: PageSize) PhysAddr {
        _ = self;
        _ = ps;
        @panic("unimplemented");
    }

    pub fn reserve(self: *PageAllocator, start: PhysAddr, end: PhysAddr) void {
        _ = self;
        _ = start;
        _ = end;
        @panic("unimplemented");
    }

    pub fn free(self: *PageAllocator, paddr: PhysAddr, ps: PageSize) void {
        _ = self;
        _ = paddr;
        _ = ps;
        @panic("unimplemented");
    }
};
