const std = @import("std");
const assert = std.debug.assert;
const Vcpu = @import("vcpu.zig").Vcpu;
const vmx = @import("vmx.zig");
const ept = @import("ept.zig");

pub const MmioInstr = struct {
    /// bytes to skip
    len: u8,
    kind: Kind,
    /// the width of the memory access in bytes: 1, 2, 4 (or 8 with REX.W)
    size: u8,
    /// ModRM.reg + REX.R, for load/store_reg
    reg: enum(u4) { rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15 } = .rax,
    /// the register operand is ah, ch, dh or bh, `reg` names the full register.
    /// only with `size == 1` and no REX prefix
    high_byte: bool = false,
    /// a load that zero extends to the whole register (movzx), instead of keeping the upper bits
    zero_extend: bool = false,
    /// for store_imm. sign-extended to 64 bits when `size` is 8
    imm: u32 = 0,

    pub const Kind = enum { load, store_reg, store_imm };

    fn getReg(self: MmioInstr, vcpu: *Vcpu) u64 {
        return switch (self.reg) {
            .rsp => vmx.vmread(.GUEST_RSP),
            inline else => |reg| @field(vcpu.regs, @tagName(reg)),
        };
    }

    fn setReg(self: MmioInstr, vcpu: *Vcpu, val: u64) void {
        switch (self.reg) {
            .rsp => vmx.vmwrite(.GUEST_RSP, val),
            inline else => |reg| @field(vcpu.regs, @tagName(reg)) = val,
        }
    }

    /// the bits of a register that an access of `size` bytes covers, before `high_byte`
    fn mask(self: MmioInstr) u64 {
        return if (self.size == 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(8 * self.size)) - 1;
    }

    /// writes the low `size` bytes of `val` into the register operand, the way the CPU does:
    /// 8 and 16 bit writes keep the other bits, 32 bit writes and movzx zero the rest.
    /// asserts that `self.kind == .load`
    pub fn write(self: MmioInstr, vcpu: *Vcpu, val: u64) void {
        assert(self.kind == .load);
        if (self.zero_extend or self.size == 4)
            return self.setReg(vcpu, val & self.mask());

        const shift: u6 = if (self.high_byte) 8 else 0;
        const keep = ~(self.mask() << shift);
        self.setReg(vcpu, (self.getReg(vcpu) & keep) | ((val & self.mask()) << shift));
    }

    /// reads the value from the instruction, truncated to `size` bytes (to 32 bits when `size` is 8)
    /// asserts that `self.kind == .store_*`
    pub fn read(self: MmioInstr, vcpu: *Vcpu) u32 {
        assert(self.kind != .load);
        if (self.kind == .store_imm)
            return self.imm;

        const shift: u6 = if (self.high_byte) 8 else 0;
        return @truncate((self.getReg(vcpu) >> shift) & self.mask());
    }
};

/// longest legal x86 instruction
pub const max_len = 15;

/// decodes the instr at the loaded guest's RIP
pub fn decodeGuestRip(vcpu: *Vcpu) !MmioInstr {
    const guest_addr = vmx.vmread(.GUEST_RIP);
    const bytes = try ept.readGuestVirt([max_len]u8, vcpu.vm, vmx.vmread(.GUEST_CR3), guest_addr);
    return decode(bytes[0..]);
}

/// decodes the instruction at the start of `bytes`, one of:
/// mov r/m, r (88, 89), mov r, r/m (8A, 8B), mov r/m, imm (C6, C7) with a memory operand,
/// at 8, 16 (66 prefix), 32 and 64 (REX.W) bits, and movzx r32, r/m8 or r/m16 (0F B6, 0F B7)
pub fn decode(bytes: []const u8) error{Unsupported}!MmioInstr {
    var r: Reader = .{ .bytes = bytes[0..@min(bytes.len, max_len)] };

    var op = r.byte();
    const opsize16 = op == 0x66;
    if (opsize16) op = r.byte();

    var rex: Rex = .{};
    const has_rex = op & 0xf0 == 0x40;
    if (has_rex) {
        rex = @bitCast(@as(u4, @truncate(op)));
        op = r.byte();
    }

    var size: u8 = if (rex.w) 8 else if (opsize16) 2 else 4;
    var zero_extend = false;
    const kind: MmioInstr.Kind = switch (op) {
        0x88 => blk: { // mov r/m8, r8
            size = 1;
            break :blk .store_reg;
        },
        0x89 => .store_reg, // mov r/m, r
        0x8a => blk: { // mov r8, r/m8
            size = 1;
            break :blk .load;
        },
        0x8b => .load, // mov r, r/m
        0xc6 => blk: { // mov r/m8, imm8
            size = 1;
            break :blk .store_imm;
        },
        0xc7 => .store_imm, // mov r/m, imm
        0x0f => blk: {
            // movzx to a 16 bit register keeps the upper bits, not supported
            if (opsize16) return error.Unsupported;
            zero_extend = true;
            switch (r.byte()) {
                0xb6 => size = 1, // movzx r32, r/m8
                0xb7 => size = 2, // movzx r32, r/m16
                else => return error.Unsupported,
            }
            break :blk .load;
        },
        else => return error.Unsupported,
    };

    const modrm: ModRm = @bitCast(r.byte());
    // a register operand, not a memory access
    if (modrm.mod == 0b11) return error.Unsupported;
    // C6/C7 /0 is mov, the other /n are undefined
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
    const imm: u32 = if (kind != .store_imm) 0 else switch (size) {
        1 => r.byte(),
        2 => std.mem.readInt(u16, r.take(2), .little),
        else => std.mem.readInt(u32, r.take(4), .little),
    };

    // without a REX prefix, byte registers 4..7 are ah, ch, dh and bh
    const high_byte = size == 1 and !zero_extend and !has_rex and kind != .store_imm and modrm.reg >= 4;
    const reg_index: u4 = if (high_byte) modrm.reg - 4 else @as(u4, @intFromBool(rex.r)) << 3 | modrm.reg;

    return .{
        .len = @intCast(r.pos),
        .kind = kind,
        .size = size,
        .reg = if (kind == .store_imm) .rax else @enumFromInt(reg_index),
        .high_byte = high_byte,
        .zero_extend = zero_extend,
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

test "decode: byte load" {
    // mov al, byte ptr [rdi + 0x100]
    try expectDecode(.{ .len = 6, .kind = .load, .size = 1, .reg = .rax }, &.{ 0x8a, 0x87, 0x00, 0x01, 0x00, 0x00 });
    // mov sil, byte ptr [rax], the REX prefix makes it sil, not dh
    try expectDecode(.{ .len = 3, .kind = .load, .size = 1, .reg = .rsi }, &.{ 0x40, 0x8a, 0x30 });
}

test "decode: high byte register" {
    // mov ch, byte ptr [rax]
    try expectDecode(.{ .len = 2, .kind = .load, .size = 1, .reg = .rcx, .high_byte = true }, &.{ 0x8a, 0x28 });
}

test "decode: word access" {
    // mov ax, word ptr [rdx]
    try expectDecode(.{ .len = 3, .kind = .load, .size = 2, .reg = .rax }, &.{ 0x66, 0x8b, 0x02 });
    // mov word ptr [rdx], cx
    try expectDecode(.{ .len = 3, .kind = .store_reg, .size = 2, .reg = .rcx }, &.{ 0x66, 0x89, 0x0a });
}

test "decode: byte and word immediate stores" {
    // mov byte ptr [rdx], 0x12
    try expectDecode(.{ .len = 3, .kind = .store_imm, .size = 1, .imm = 0x12 }, &.{ 0xc6, 0x02, 0x12 });
    // mov word ptr [rdx], 0x1234
    try expectDecode(.{ .len = 5, .kind = .store_imm, .size = 2, .imm = 0x1234 }, &.{ 0x66, 0xc7, 0x02, 0x34, 0x12 });
}

test "decode: movzx" {
    // movzx eax, byte ptr [rdx]
    try expectDecode(.{ .len = 3, .kind = .load, .size = 1, .reg = .rax, .zero_extend = true }, &.{ 0x0f, 0xb6, 0x02 });
    // movzx ecx, word ptr [rdx]
    try expectDecode(.{ .len = 3, .kind = .load, .size = 2, .reg = .rcx, .zero_extend = true }, &.{ 0x0f, 0xb7, 0x0a });
}
