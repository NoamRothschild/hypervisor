const std = @import("std");
const Vcpu = @import("../vcpu.zig").Vcpu;
const vmx = @import("../vmx.zig");
const ept = @import("../ept.zig");

pub const MmioInstr = struct {
    /// bytes to skip
    len: u8,
    kind: Kind,
    /// 4 (or 8 with REX.W)
    size: u8,
    /// ModRM.reg + REX.R, for load/store_reg
    reg: enum(u4) { rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15 } = .rax,
    /// for store_imm. sign-extended to 64 bits when `size` is 8
    imm: u32 = 0,

    pub const Kind = enum { load, store_reg, store_imm };
};

/// longest legal x86 instruction
pub const max_len = 15;

/// decodes the instr at the loaded guest's RIP
pub fn decodeGuestRip(vcpu: *Vcpu) !MmioInstr {
    const guest_addr = vmx.vmread(.GUEST_RIP);
    const bytes = try ept.readGuestVirt([max_len]u8, vcpu.vm, .from(vmx.vmread(.GUEST_CR3)), .from(guest_addr));
    return decode(bytes[0..]);
}

/// decodes the instruction at the start of `bytes`
pub fn decode(bytes: []const u8) error{Unsupported}!MmioInstr {
    var r: Reader = .{ .bytes = bytes[0..@min(bytes.len, max_len)] };

    var op = r.byte();
    var rex: Rex = .{};
    if (op & 0xf0 == 0x40) {
        rex = @bitCast(@as(u4, @truncate(op)));
        op = r.byte();
    }

    const kind: MmioInstr.Kind = switch (op) {
        0x89 => .store_reg, // mov r/m32, r32
        0x8b => .load, // mov r32, r/m32
        0xc7 => .store_imm, // mov r/m32, imm32
        else => return error.Unsupported,
    };

    const modrm: ModRm = @bitCast(r.byte());
    // a register operand, not a memory access
    if (modrm.mod == 0b11) return error.Unsupported;
    // C7 /0 is mov, the other /n are undefined
    if (kind == .store_imm and modrm.reg != 0) return error.Unsupported;

    var disp_len: usize = switch (modrm.mod) {
        0b00 => 0,
        0b01 => 1,
        0b10 => 4,
        0b11 => unreachable,
    };
    if (modrm.rm == 0b100) {
        const sib: Sib = @bitCast(r.byte());
        // no base register, a disp32 instead
        if (modrm.mod == 0b00 and sib.base == 0b101) disp_len = 4;
    } else if (modrm.mod == 0b00 and modrm.rm == 0b101) {
        // rip-relative disp32
        disp_len = 4;
    }
    r.skip(disp_len);

    // the immediate stays 32 bits under REX.W
    const imm: u32 = if (kind == .store_imm) std.mem.readInt(u32, r.take(4), .little) else 0;

    return .{
        .len = @intCast(r.pos),
        .kind = kind,
        .size = if (rex.w) 8 else 4,
        .reg = if (kind == .store_imm) .rax else @enumFromInt(@as(u4, @intFromBool(rex.r)) << 3 | modrm.reg),
        .imm = imm,
    };
}

/// 0100WRXB, X and B only extend the address registers, which aren't decoded
const Rex = packed struct(u4) {
    b: bool = false,
    x: bool = false,
    r: bool = false,
    w: bool = false,
};

const ModRm = packed struct(u8) {
    rm: u3,
    reg: u3,
    mod: u2,
};

const Sib = packed struct(u8) {
    base: u3,
    index: u3,
    scale: u2,
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, comptime n: usize) *const [n]u8 {
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    fn skip(self: *Reader, n: usize) void {
        self.pos += n;
    }

    fn byte(self: *Reader) u8 {
        return self.take(1)[0];
    }
};

fn expectDecode(expected: MmioInstr, bytes: []const u8) !void {
    try std.testing.expectEqual(expected, try decode(bytes));
}

test "decode: load with disp32" {
    // mov eax, dword ptr [rdi - 0xa04000], the first LAPIC access of Linux
    try expectDecode(.{ .len = 6, .kind = .load, .size = 4, .reg = .rax }, &.{ 0x8b, 0x87, 0x00, 0xc0, 0x5f, 0xff });
}

test "decode: store, no displacement" {
    // mov dword ptr [rdx], ecx
    try expectDecode(.{ .len = 2, .kind = .store_reg, .size = 4, .reg = .rcx }, &.{ 0x89, 0x0a });
}

test "decode: REX.R and SIB" {
    // mov dword ptr [rsp], r8d
    try expectDecode(.{ .len = 4, .kind = .store_reg, .size = 4, .reg = .r8 }, &.{ 0x44, 0x89, 0x04, 0x24 });
}

test "decode: REX.W and rip-relative" {
    // mov rax, qword ptr [rip + 0x12345678]
    try expectDecode(.{ .len = 7, .kind = .load, .size = 8, .reg = .rax }, &.{ 0x48, 0x8b, 0x05, 0x78, 0x56, 0x34, 0x12 });
}

test "decode: SIB without base" {
    // mov eax, dword ptr [0xfee00020]
    try expectDecode(.{ .len = 7, .kind = .load, .size = 4, .reg = .rax }, &.{ 0x8b, 0x04, 0x25, 0x20, 0x00, 0xe0, 0xfe });
}

test "decode: immediate store" {
    // mov dword ptr [rax + 0x10], 0x12345678
    try expectDecode(.{ .len = 7, .kind = .store_imm, .size = 4, .imm = 0x12345678 }, &.{ 0xc7, 0x40, 0x10, 0x78, 0x56, 0x34, 0x12 });
    // mov dword ptr [rax + 0xb0], 0
    try expectDecode(.{ .len = 10, .kind = .store_imm, .size = 4, .imm = 0 }, &.{ 0xc7, 0x80, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
}

test "decode: ignores bytes after the instruction" {
    try expectDecode(.{ .len = 2, .kind = .store_reg, .size = 4, .reg = .rcx }, &.{ 0x89, 0x0a, 0xcc, 0xcc });
}

test "decode: rejects what isn't a memory mov" {
    // mov eax, eax
    try std.testing.expectError(error.Unsupported, decode(&.{ 0x89, 0xc0 }));
    // add dword ptr [rdx], eax
    try std.testing.expectError(error.Unsupported, decode(&.{ 0x01, 0x02 }));
    // C7 /1 is undefined
    try std.testing.expectError(error.Unsupported, decode(&.{ 0xc7, 0x48, 0x10, 0x00, 0x00, 0x00, 0x00 }));
}
