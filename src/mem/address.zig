//! Names for the kinds of addresses the hypervisor juggles. They are plain
//! aliases: they document intent in signatures, but the compiler won't catch a mix-up.
//!
//! A host virtual address that is known to be mapped is always passed around as a
//! pointer. `HostVirt` is only for addresses that may not be mapped (yet).

/// physical address in the host's address space
pub const HostPhys = u64;
/// virtual address in the host's address space, that isn't necessarily mapped
pub const HostVirt = u64;
/// physical address in the guest's address space, translated by EPT
pub const GuestPhys = u64;
/// physical address in the guest's address space, as the MP tables store them
pub const GuestPhys32 = u32;
/// virtual address in the guest's address space, translated by the guest's own page tables
pub const GuestVirt = u64;
