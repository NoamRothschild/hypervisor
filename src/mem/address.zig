//! Distinct types for the kinds of 64-bit addresses the hypervisor juggles,
//! so mixing them up is a compile error instead of a silent bug.
//!
//! A host virtual address that is known to be mapped is always passed around as a
//! pointer. `HostVirt` is only for addresses that may not be mapped (yet).

pub const Kind = enum {
    /// physical address in the host's address space
    host_phys,
    /// virtual address in the host's address space, that isn't necessarily mapped
    host_virt,
    /// physical address in the guest's address space, translated by EPT
    guest_phys,
    /// virtual address in the guest's address space, translated by the guest's own page tables
    guest_virt,
};

/// A 64-bit address of one `Kind`. Each kind is its own type.
pub fn Address(comptime kind: Kind) type {
    return enum(u64) {
        _,

        /// a container that doesn't capture its comptime arguments is deduplicated
        /// into one type, and `HostPhys == GuestPhys` would silently hold.
        pub const address_kind = kind;

        /// construct addr from a u64
        pub inline fn from(addr: u64) @This() {
            return @enumFromInt(addr);
        }

        /// get the backing int of the addr
        pub inline fn raw(self: @This()) u64 {
            return @intFromEnum(self);
        }

        /// the address `n` bytes further
        pub inline fn offset(self: @This(), n: u64) @This() {
            return from(self.raw() +% n);
        }
    };
}

pub const HostPhys = Address(.host_phys);
pub const HostVirt = Address(.host_virt);

comptime {
    // guards the dedup pitfall described in `Address`
    const kinds = [_]type{ Address(.host_phys), Address(.host_virt), Address(.guest_phys), Address(.guest_virt) };
    for (kinds, 0..) |a, i|
        for (kinds[i + 1 ..]) |b|
            if (a == b) @compileError("address kinds must be distinct types");
}
