//! QEMU's fw_cfg, the files QEMU hands to the firmware (`-fw_cfg name=opt/...,string=...`).
//! ref: https://www.qemu.org/docs/master/specs/fw_cfg.html
const std = @import("std");
const debug = @import("../../debug.zig");

const selector_port: u16 = 0x510;
const data_port: u16 = 0x511;
const signature_key: u16 = 0x00;
const file_dir_key: u16 = 0x19;

fn read(buf: []u8) void {
    for (buf) |*byte| byte.* = debug.inb(data_port);
}

/// whether QEMU was given the file `name`. false without fw_cfg, outside QEMU
pub fn has(name: []const u8) bool {
    debug.outw(selector_port, signature_key);
    var signature: [4]u8 = undefined;
    read(&signature);
    if (!std.mem.eql(u8, &signature, "QEMU")) return false;

    debug.outw(selector_port, file_dir_key);
    var count: [4]u8 = undefined;
    read(&count);
    for (0..std.mem.readInt(u32, &count, .big)) |_| {
        // size: u32, select: u16, reserved: u16, name: [56]u8, all big-endian
        var entry: [64]u8 = undefined;
        read(&entry);
        if (std.mem.eql(u8, std.mem.sliceTo(entry[8..], 0), name)) return true;
    }
    return false;
}
