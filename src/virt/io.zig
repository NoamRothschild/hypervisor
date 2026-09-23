///! ref: https://hv.smallkirby.com/en/vmm/io
const std = @import("std");
const debug = @import("../debug.zig");
const vmx = @import("vmx.zig");
const Vcpu = @import("vcpu.zig").Vcpu;
const IoQual = vmx.ExitQualification.Io;

pub fn handleIo(vcpu: *Vcpu, qual: IoQual) error{Aborted}!void {
    return switch (qual.direction) {
        .in => handleIoIn(vcpu, qual),
        .out => handleIoOut(vcpu, qual),
    };
}

pub fn handleIoIn(vcpu: *Vcpu, qual: IoQual) error{Aborted}!void {
    return switch (qual.port) {
        0x0020...0x0021 => try handlePicIn(vcpu, qual),
        0x0040...0x0047 => {}, // PIT ports, current set to passthrough
        0x0060...0x0064 => vcpu.regs.rax = 0, // PS/2, unimplemented
        0x0070...0x0071 => vcpu.regs.rax = 0, // RTC, unimplemented
        0x0080...0x008F => {}, // DMA, unimplemented
        0x00A0...0x00A1 => try handlePicIn(vcpu, qual),
        0x02E8...0x02EF => {}, // fourth serial port, ignore
        0x02F8...0x02FF => {}, // second serial port, ignore
        0x03B0...0x03DF => vcpu.regs.rax = 0, // VGA, unimplemented
        0x03E8...0x03EF => {}, // third serial port, ignore
        0x03F8...0x03FF => try handleSerialIn(vcpu, qual),
        0x0CF8...0x0CFF => vcpu.regs.rax = 0, // PCI, unimplemented
        0xC000...0xCFFF => {}, // Old PCI, ignore
        else => vcpu.abortMsg("Unhandled I/O-in port: 0x{X}\n", .{qual.port}),
    };
}

pub fn handleIoOut(vcpu: *Vcpu, qual: IoQual) error{Aborted}!void {
    return switch (qual.port) {
        0x0020...0x0021 => try handlePicOut(vcpu, qual),
        0x0040...0x0047 => {}, // PIT ports, current set to passthrough
        0x0060...0x0064 => {}, // PS/2, unimplemented
        0x0070...0x0071 => {}, // RTC, unimplemented
        0x0080...0x008F => {}, // DMA, unimplemented
        0x00A0...0x00A1 => try handlePicOut(vcpu, qual),
        0x02E8...0x02EF => {}, // fourth serial port, ignore
        0x02F8...0x02FF => {}, // second serial port, ignore
        0x03B0...0x03DF => {}, // VGA, unimplemented
        0x03F8...0x03FF => try handleSerialOut(vcpu, qual),
        0x03E8...0x03EF => {}, // third serial port, ignore
        0x0CF8...0x0CFF => {}, // PCI, unimplemented
        0xC000...0xCFFF => {}, // Old PCI, ignore
        else => vcpu.abortMsg("Unhandled I/O-out port: 0x{X}\n", .{qual.port}),
    };
}

pub const Serial = struct {
    /// Interrupt Enable Register
    ier: u8 = 0,
    /// Modem Control Register
    mcr: u8 = 0,
};

pub fn handleSerialIn(vcpu: *Vcpu, qual: IoQual) error{Aborted}!void {
    switch (qual.port) {
        // COM1 PORTS: 0x03F8 - 0x3FF

        // Receive buffer
        0x3F8 => vcpu.regs.rax = debug.inb(qual.port), // pass-through
        // Interrupt Enable Register (DLAB=1) / Divisor Latch High Register (DLAB=0)
        0x3F9 => vcpu.regs.rax = vcpu.serial.ier,
        // Interrupt Identification Register
        0x3FA => vcpu.regs.rax = debug.inb(qual.port), // pass-through
        // Line Control Register (MSB is DLAB)
        0x3FB => vcpu.regs.rax = 0x00,
        // Modem Control Register
        0x3FC => vcpu.regs.rax = vcpu.serial.mcr,
        // Line Status Register
        0x3FD => vcpu.regs.rax = debug.inb(qual.port), // pass-through
        // Modem Status Register
        0x3FE => vcpu.regs.rax = debug.inb(qual.port), // pass-through
        // Scratch Register
        0x3FF => vcpu.regs.rax = 0, // 8250
        else => try vcpu.abortMsg("Unsupported I/O-in to the first serial port: 0x{X}\n", .{qual.port}),
    }
}

fn handleSerialOut(vcpu: *Vcpu, qual: IoQual) error{Aborted}!void {
    switch (qual.port) {
        // COM1 PORTS: 0x03F8 - 0x3FF

        // Transmit buffer
        0x3F8 => debug.outb(debug.COM1, @truncate(vcpu.regs.rax)),
        // Interrupt Enable Register
        0x3F9 => vcpu.serial.ier = @truncate(vcpu.regs.rax),
        // FIFO control registers
        0x3FA => {}, // ignore
        // Line Control Register (MSB is DLAB)
        0x3FB => {}, // ignore
        // Modem Control Register
        0x3FC => vcpu.serial.mcr = @truncate(vcpu.regs.rax),
        // Scratch Register
        0x3FF => {}, // ignore
        else => try vcpu.abortMsg("Unsupported I/O-out to the first serial port: 0x{X}\n", .{qual.port}),
    }
}

pub const Pic = struct {
    /// Mask of the primary PIC
    primary_mask: u8,
    /// Mask of the secondary PIC
    secondary_mask: u8,
    /// Initialization phase of the primary PIC
    primary_phase: InitPhase = .uninitialized,
    /// Initialization phase of the secondary PIC
    secondary_phase: InitPhase = .uninitialized,
    /// Vector offset of the primary PIC
    primary_base: u8 = 0,
    /// Vector offset of the secondary PIC
    secondary_base: u8 = 0,

    const InitPhase = enum {
        uninitialized, // ICW1 before sent
        phase1, // ICW1
        phase2, // ICW2
        phase3, // ICW3
        initialized, // ICW4 sent and init completed
    };

    pub const init: @This() = .{
        .primary_mask = 0xff,
        .secondary_mask = 0xff,
    };
};

fn handlePicIn(vcpu: *Vcpu, qual: IoQual) error{Aborted}!void {
    const pic = &vcpu.pic;

    switch (qual.port) {
        // Primary PIC data
        0x21 => switch (pic.primary_phase) {
            .uninitialized, .initialized => vcpu.regs.rax = pic.primary_mask,
            else => try vcpu.abort(),
        },
        // Secondary PIC data
        0xA1 => switch (pic.secondary_phase) {
            .uninitialized, .initialized => vcpu.regs.rax = pic.secondary_mask,
            else => try vcpu.abort(),
        },
        else => try vcpu.abort(),
    }
}

fn handlePicOut(vcpu: *Vcpu, qual: IoQual) error{Aborted}!void {
    const regs = vcpu.regs;
    const pic = &vcpu.pic;
    const dx: u8 = @truncate(regs.rax);

    switch (qual.port) {
        // Primary PIC command
        0x20 => switch (dx) {
            0x11 => pic.primary_phase = .phase1,
            // Specific-EOI
            // It's Ymir's responsibility to send EOI, so guests are not allowed to send EOI
            0x60...0x67 => {},
            else => try vcpu.abort(),
        },
        // Primary PIC data
        0x21 => switch (pic.primary_phase) {
            .uninitialized, .initialized => pic.primary_mask = dx,
            .phase1 => {
                std.log.info("Primary PIC vector offset: 0x{X}\n", .{dx});
                pic.primary_base = dx;
                pic.primary_phase = .phase2;
            },
            .phase2 => {
                if (dx != (1 << 2))
                    try vcpu.abort();
                pic.primary_phase = .phase3;
            },
            .phase3 => pic.primary_phase = .initialized,
        },

        // Secondary PIC command
        0xA0 => switch (dx) {
            0x11 => pic.secondary_phase = .phase1,
            // Specific-EOI
            // It's Ymir's responsibility to send EOI, so guests are not allowed to send EOI
            0x60...0x67 => {},
            else => try vcpu.abort(),
        },
        // Secondary PIC data
        0xA1 => switch (pic.secondary_phase) {
            .uninitialized, .initialized => pic.secondary_mask = dx,
            .phase1 => {
                std.log.info("Secondary PIC vector offset: 0x{X}\n", .{dx});
                pic.secondary_base = dx;
                pic.secondary_phase = .phase2;
            },
            .phase2 => {
                if (dx != 2)
                    try vcpu.abort();
                pic.secondary_phase = .phase3;
            },
            .phase3 => pic.secondary_phase = .initialized,
        },
        else => try vcpu.abort(),
    }
}
