//! Intel MultiProcessor tables, the legacy firmware tables Linux reads the
//! CPU list from when there is no ACPI MADT (or with `acpi=off`).
//!
//! source: http://www.intel.com/design/pentium/datashts/24201606.pdf
//! ported from firecracker's `src/vmm/src/arch/x86_64/mptable.rs`
const std = @import("std");
const vmx = @import("../vmx.zig");
const ept = @import("../ept.zig");
const address = @import("../../mem/address.zig");
const assert = std.debug.assert;

const hypervisor_sig = @import("../cpuid.zig").hypervisor_sig;

/// A guest physical address, as the MP tables store them.
pub const GuestPhys32 = address.Address(.guest_phys, .{ .backing = u32 });

/// Where the tables are written: the last kilobyte of base memory (639KB),
/// one of the places Linux scans for the floating pointer.
/// Must be left out of the guest's E820 RAM.
pub const base: GuestPhys32 = .from(0x9_FC00);
/// Bytes available at `base`, up to the start of the VGA hole (0xA0000).
pub const max_size = 0xA_0000 - base.raw();

/// Local APIC MMIO base. source: linux/arch/x86/include/asm/apicdef.h
pub const lapic_base: GuestPhys32 = .from(0xFEE0_0000);
/// I/O APIC MMIO base. source: linux/arch/x86/include/asm/apicdef.h
pub const ioapic_base: GuestPhys32 = .from(0xFEC0_0000);
/// Local APIC version reported for every CPU (and the I/O APIC), as an integrated 82489DX successor.
const apic_version = 0x14;
/// Number of legacy ISA IRQs routed to the I/O APIC.
const isa_irq_count = 16;

/// This structure must be stored in at least one of the following
/// memory locations, because the operating system searches for the MP
/// floating pointer structure in the order described below
///
/// a. In the first kilobyte of Extended BIOS Data Area (EBDA)
/// b. Within the last kilobyte of system base memory
/// c. In the BIOS ROM address space between 0F0000h and 0FFFFFh
pub const FloatingPointer = extern struct {
    sig: [4]u8 = "_MP_".*,
    /// ptr to the mp config table, or null if does not exist, see `ConfigTable`
    config_table: GuestPhys32 = .null,
    /// length of this struct in paragraph (16-byte) units.
    len: u8 = 1,
    /// The version number of the MP specification supported.
    spec_rev: SpecRev = .@"1.4",
    /// A checksum of the complete pointer structure.
    /// All bytes specified by the length field, including
    /// CHECKSUM and reserved bytes, must add up to zero
    checksum: u8 = 0,
    /// feature byte 1 nonzero means one of the spec's default configurations
    /// and no config table, we always provide a table.
    feature_bytes: [5]u8 = @splat(0),
};

pub const SpecRev = enum(u8) {
    @"1.1" = 1,
    @"1.4" = 4,
};

/// The MP configuration table header, followed by `entry_count` entries.
pub const ConfigTable = extern struct {
    sig: [4]u8 = "PCMP".*,
    /// length of the header and all the entries, in bytes.
    len: u16,
    spec_rev: SpecRev = .@"1.4",
    /// all `len` bytes must add up to zero.
    checksum: u8 = 0,
    oem_id: [8]u8 = "NoamRTD ".*,
    product_id: [12]u8 = hypervisor_sig.*,
    oem_table_ptr: GuestPhys32 = .null,
    oem_table_size: u16 = 0,
    entry_count: u16,
    lapic_addr: GuestPhys32 = lapic_base,
    ext_table_len: u16 = 0,
    ext_table_checksum: u8 = 0,
    _reserved: u8 = 0,
};

comptime {
    assert(@sizeOf(FloatingPointer) == 16);
    assert(@sizeOf(ConfigTable) == 44);
}

pub const Entry = extern struct {
    type: EntryType align(1),
    data: DataVariant align(1),

    // names must match DataVariant names
    pub const EntryType = enum(u8) {
        processor = 0,
        bus = 1,
        ioapic = 2,
        io_interrupt = 3,
        local_interrupt = 4,
    };

    pub const DataVariant = extern union {
        processor: Processor,
        bus: Bus,
        ioapic: IoApic,
        io_interrupt: IoInterrupt,
        local_interrupt: LocalInterrupt,

        pub const Processor = extern struct {
            lapic_id: u8,
            lapic_version: u8 = apic_version,
            flags: packed struct(u8) {
                enabled: bool = true,
                /// set on exactly one CPU, the one that boots the OS.
                bsp: bool,
                _: u6 = 0,
            },
            /// CPUID.1:EAX of the processor
            signature: u32 align(1) = 0x600,
            /// CPUID.1:EDX of the processor
            features: u32 align(1) = cpu_feature_fpu | cpu_feature_apic,
            _reserved: [2]u32 align(1) = @splat(0),

            const cpu_feature_fpu = 1 << 0;
            const cpu_feature_apic = 1 << 9;
        };

        pub const Bus = extern struct {
            id: u8,
            /// space padded bus type name
            bus_type: [6]u8,
        };

        pub const IoApic = extern struct {
            id: u8,
            version: u8 = apic_version,
            flags: packed struct(u8) {
                usable: bool = true,
                _: u7 = 0,
            } = .{},
            addr: GuestPhys32 align(1) = ioapic_base,
        };

        pub const InterruptType = enum(u8) {
            /// vectored interrupt, the vector comes from the APIC redirection table
            intr = 0,
            nmi = 1,
            smi = 2,
            /// vectored interrupt, the vector comes from an external 8259 PIC
            ext_int = 3,
        };

        /// polarity and trigger mode, 0 = conforms to the bus spec
        pub const InterruptFlags = packed struct(u16) {
            polarity: u2 = 0,
            trigger: u2 = 0,
            _: u12 = 0,
        };

        /// An I/O interrupt assignment, which I/O APIC pin a bus IRQ is wired to.
        pub const IoInterrupt = extern struct {
            intr_type: InterruptType,
            flags: InterruptFlags align(1) = .{},
            src_bus_id: u8,
            src_bus_irq: u8,
            dst_ioapic_id: u8,
            dst_ioapic_pin: u8,
        };

        /// A local interrupt assignment, which local APIC LINTn pin a source is wired to.
        pub const LocalInterrupt = extern struct {
            int_type: InterruptType,
            flags: InterruptFlags align(1) = .{},
            src_bus_id: u8,
            src_bus_irq: u8,
            /// 0xFF means all local APICs
            dst_lapic_id: u8,
            dst_lapic_pin: u8,
        };

        comptime {
            assert(sizeOf(.processor) == 20);
            assert(sizeOf(.bus) == 8);
            assert(sizeOf(.ioapic) == 8);
            assert(sizeOf(.io_interrupt) == 8);
            assert(sizeOf(.local_interrupt) == 8);
        }
    };

    /// In-memory size of an entry of type `tag`, including the type byte.
    pub fn sizeOf(tag: EntryType) usize {
        return switch (tag) {
            inline else => |t| @sizeOf(EntryType) + @sizeOf(@FieldType(DataVariant, @tagName(t))),
        };
    }

    pub fn size(self: *const @This()) usize {
        return sizeOf(self.type);
    }

    pub inline fn proc(data: DataVariant.Processor) Entry {
        return Entry{
            .type = .processor,
            .data = .{ .processor = data },
        };
    }

    pub inline fn bus(data: DataVariant.Bus) Entry {
        return Entry{
            .type = .bus,
            .data = .{ .bus = data },
        };
    }

    pub inline fn ioapic(data: DataVariant.IoApic) Entry {
        return Entry{
            .type = .ioapic,
            .data = .{ .ioapic = data },
        };
    }

    pub inline fn ioIntr(data: DataVariant.IoInterrupt) Entry {
        return Entry{
            .type = .io_interrupt,
            .data = .{ .io_interrupt = data },
        };
    }

    pub inline fn localIntr(data: DataVariant.LocalInterrupt) Entry {
        return Entry{
            .type = .local_interrupt,
            .data = .{ .local_interrupt = data },
        };
    }
};

pub const Options = struct {
    /// processors listed, with local APIC IDs 0..cpu_count-1. CPU 0 is the BSP.
    /// Each vCPU must report the same ID in CPUID.1:EBX[31:24].
    cpu_count: u8,
    /// Also list an I/O APIC at `ioapic_base` with ISA IRQs 0-15 wired 1:1 to its pins.
    /// Only enable once the I/O APIC is emulated: when Linux finds one, it routes
    /// device IRQs through it instead of the 8259 PIC.
    /// Without it, Linux runs the PIC in virtual wire mode through the BSP's LINT0.
    ioapic: bool = false,
};

/// Number of bytes the tables take for `opts`.
pub fn size(opts: Options) usize {
    var n = @sizeOf(FloatingPointer) +
        @sizeOf(ConfigTable) +
        Entry.sizeOf(.processor) * @as(usize, opts.cpu_count) +
        Entry.sizeOf(.bus) +
        Entry.sizeOf(.local_interrupt) * 2;
    if (opts.ioapic)
        n += Entry.sizeOf(.ioapic) + Entry.sizeOf(.io_interrupt) * isa_irq_count;
    return n;
}

/// Byte sum that makes `bytes` add up to zero.
fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return 0 -% sum;
}

/// Builds the floating pointer followed by the config table into `buf`,
/// as they are to be placed at guest physical `at`. Returns the used part of `buf`.
pub fn build(buf: []u8, at: GuestPhys32, opts: Options) error{ NoCpus, TooManyCpus }![]u8 {
    if (opts.cpu_count == 0) return error.NoCpus;
    // the I/O APIC takes the ID after the last CPU, and xAPIC IDs are 8-bit with 0xFF broadcast
    if (opts.cpu_count > 254 or size(opts) > buf.len) return error.TooManyCpus;

    const ioapic_id = opts.cpu_count;
    const isa_bus_id = 0;

    // Appends data to a byte buffer.
    const Builder = struct {
        buf: []u8,
        len: usize = 0,

        fn extendAny(self: *@This(), entry: anytype) void {
            const bytes = std.mem.asBytes(&entry);
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }

        fn extend(self: *@This(), entry: Entry) void {
            const bytes: [*]const u8 = @ptrCast(&entry);
            const entry_size = entry.size();
            @memcpy(self.buf[self.len .. self.len + entry_size], bytes[0..entry_size]);
            self.len += entry_size;
        }
    };

    var b: Builder = .{ .buf = buf };
    b.extendAny(FloatingPointer{ .config_table = at.offset(@sizeOf(FloatingPointer)) });
    const table_start = b.len;

    // filled in once the entries are counted
    b.extendAny(ConfigTable{ .len = undefined, .entry_count = undefined });
    var entry_count: u16 = 0;

    for (0..opts.cpu_count) |i| {
        b.extend(.proc(.{
            .lapic_id = @truncate(i),
            .flags = .{ .bsp = i == 0 },
        }));
        entry_count += 1;
    }

    b.extend(.bus(.{ .id = isa_bus_id, .bus_type = "ISA   ".* }));
    entry_count += 1;

    if (opts.ioapic) {
        b.extend(.ioapic(.{ .id = ioapic_id }));
        entry_count += 1;
        // same routing as kvm_setup_default_irq_routing()
        for (0..isa_irq_count) |irq| {
            b.extend(.ioIntr(.{
                .intr_type = .intr,
                .src_bus_id = isa_bus_id,
                .src_bus_irq = @truncate(irq),
                .dst_ioapic_id = ioapic_id,
                .dst_ioapic_pin = @truncate(irq),
            }));
            entry_count += 1;
        }
    }

    // the 8259 PIC output is wired to the BSP's LINT0
    b.extend(.localIntr(.{
        .int_type = .ext_int,
        .src_bus_id = isa_bus_id,
        .src_bus_irq = 0,
        .dst_lapic_id = 0,
        .dst_lapic_pin = 0,
    }));
    // NMI is wired to every CPU's LINT1
    b.extend(.localIntr(.{
        .int_type = .nmi,
        .src_bus_id = isa_bus_id,
        .src_bus_irq = 0,
        .dst_lapic_id = 0xFF,
        .dst_lapic_pin = 1,
    }));
    entry_count += 2;

    const table = buf[table_start..b.len];
    const hdr: *align(1) ConfigTable = @ptrCast(table.ptr);
    hdr.* = .{ .len = @intCast(table.len), .entry_count = entry_count };
    hdr.checksum = checksum(table);

    const fp: *align(1) FloatingPointer = @ptrCast(buf.ptr);
    fp.checksum = checksum(buf[0..@sizeOf(FloatingPointer)]);

    return buf[0..b.len];
}

/// Writes the MP tables to `base` in the guest's memory.
/// The guest's E820 map must not list `base`..`base + max_size` as RAM.
pub fn write(guest_state: *vmx.VMState, opts: Options) !void {
    var buf: [max_size]u8 = undefined;
    const tables = try build(&buf, base, opts);
    try ept.writeGuest(guest_state, tables, .from(base.raw()));
}

test "build: layout and checksums" {
    var buf: [max_size]u8 = undefined;
    const tables = try build(&buf, base, .{ .cpu_count = 2 });
    try std.testing.expectEqual(size(.{ .cpu_count = 2 }), tables.len);

    const fp: *align(1) const FloatingPointer = @ptrCast(tables.ptr);
    try std.testing.expectEqualSlices(u8, "_MP_", &fp.sig);
    try std.testing.expectEqual(base.raw() + 16, fp.config_table.raw());
    try std.testing.expectEqual(0, checksum(tables[0..16]));

    const table = tables[16..];
    const hdr: *align(1) const ConfigTable = @ptrCast(table.ptr);
    try std.testing.expectEqualSlices(u8, "PCMP", &hdr.sig);
    try std.testing.expectEqual(table.len, hdr.len);
    // 2 cpus, bus, 2 local interrupts
    try std.testing.expectEqual(5, hdr.entry_count);
    try std.testing.expectEqual(0, checksum(table));

    // processor data follows each entry's type byte
    const cpu0: *align(1) const Entry.DataVariant.Processor = @ptrCast(table[45..].ptr);
    const cpu1: *align(1) const Entry.DataVariant.Processor = @ptrCast(table[65..].ptr);
    try std.testing.expectEqual(0x03, table[44 + 3]); // enabled | bsp
    try std.testing.expectEqual(0, cpu0.lapic_id);
    try std.testing.expectEqual(1, cpu1.lapic_id);
    try std.testing.expect(!cpu1.flags.bsp);
}

test "build: with ioapic" {
    var buf: [max_size]u8 = undefined;
    const opts: Options = .{ .cpu_count = 4, .ioapic = true };
    const tables = try build(&buf, base, opts);
    try std.testing.expectEqual(size(opts), tables.len);
    const hdr: *align(1) const ConfigTable = @ptrCast(tables[16..].ptr);
    try std.testing.expectEqual(4 + 1 + 1 + 16 + 2, hdr.entry_count);
    try std.testing.expectEqual(0, checksum(tables[16..]));
}

test "build: rejects what doesn't fit" {
    var buf: [max_size]u8 = undefined;
    try std.testing.expectError(error.NoCpus, build(&buf, base, .{ .cpu_count = 0 }));
    try std.testing.expectError(error.TooManyCpus, build(&buf, base, .{ .cpu_count = 100 }));
}
