const std = @import("std");
const vmx = @import("vmx.zig");
const ept = @import("ept.zig");
const paging = @import("../arch/x86_64/paging.zig");
const assert = std.debug.assert;

pub fn init() !void {
    assert(vmx.supportsVirtualization());
}
