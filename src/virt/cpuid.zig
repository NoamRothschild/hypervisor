const std = @import("std");
const debug = @import("../debug.zig");
const Vcpu = @import("vcpu.zig").Vcpu;

// TODO: move sig to a move visible place place,
pub const hypervisor_sig = "NoamRTD HV\x00\x00".*;

pub const Leaf = enum(u32) {
    /// Maximum input value for basic CPUID.
    maximum_input = 0x0,
    /// Version and feature information.
    vers_and_feat_info = 0x1,
    /// Thermal and power management.
    thermal_power = 0x6,
    /// Structured extended feature enumeration.
    /// Output depends on the value of ECX.
    ext_feature = 0x7,
    /// Processor extended state enumeration.
    /// Output depends on the ECX input value.
    ext_enumeration = 0xD,
    /// Maximum input value for extended function CPUID information.
    ext_func = 0x80000000,
    /// EAX: Extended processor signature and feature bits.
    ext_proc_signature = 0x80000001,
    /// Hypervisor vendor signature, our own and never the host's.
    hypervisor = 0x40000000,
    /// Unimplemented
    _,

    /// Convert u64 to Leaf.
    pub fn from(eax: u32) Leaf {
        return @enumFromInt(eax);
    }
};

pub const ExtFeatureEbx0 = packed struct(u32) {
    fsgsbase: u1 = 0,
    tsc_adjust: u1 = 0,
    sgx: u1 = 0,
    bmi1: u1 = 0,
    hle: u1 = 0,
    avx2: u1 = 0,
    fdp: u1 = 0,
    smep: u1 = 0,
    bmi2: u1 = 0,
    erms: u1 = 0,
    invpcid: u1 = 0,
    rtm: u1 = 0,
    rdtm: u1 = 0,
    fpucsds: u1 = 0,
    mpx: u1 = 0,
    rdta: u1 = 0,
    avx512f: u1 = 0,
    avx512dq: u1 = 0,
    rdseed: u1 = 0,
    adx: u1 = 0,
    smap: u1 = 0,
    avx512ifma: u1 = 0,
    _reserved1: u1 = 0,
    clflushopt: u1 = 0,
    clwb: u1 = 0,
    pt: u1 = 0,
    avx512pf: u1 = 0,
    avx512er: u1 = 0,
    avx512cd: u1 = 0,
    sha: u1 = 0,
    avx512bw: u1 = 0,
    avx512vl: u1 = 0,
};

var features = debug.CpuFeatures{
    .pcid = 1,
    .hypervisor = 1,
    .fpu = 1,
    .vme = 1,
    .de = 1,
    .pse = 1,
    .msr = 1,
    .pae = 1,
    .cx8 = 1,
    .sep = 1,
    .pge = 1,
    .cmov = 1,
    .pse36 = 1,
    .acpi = 0,
    .fxsr = 1,
    .sse = 1,
    .sse2 = 1,
};

const ext_feature0_ebx = ExtFeatureEbx0{
    .fsgsbase = 0,
    .smep = 1,
    .invpcid = 1,
    .smap = 1,
};

/// calls cpuid on the host with given params
fn rawCpuid(leaf: u32, subleaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );

    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

pub fn cpuid(vcpu: *Vcpu) error{Aborted}!void {
    const guest_regs = vcpu.regs;
    const leaf: u32 = @truncate(guest_regs.rax);
    const subleaf: u32 = @truncate(guest_regs.rcx);

    switch (Leaf.from(leaf)) {
        .maximum_input => {
            const vendor = "GenuineIntel".*;
            guest_regs.eax().* = 0x20; // maximum input value for basic CPUID.
            guest_regs.ebx().* = std.mem.readInt(u32, vendor[0..4], .little);
            guest_regs.ecx().* = std.mem.readInt(u32, vendor[8..12], .little);
            guest_regs.edx().* = std.mem.readInt(u32, vendor[4..8], .little);
        },
        .vers_and_feat_info => {
            const orig = rawCpuid(leaf, subleaf);
            if (debug.getFeatures().pcid == 0)
                features.pcid = 0;

            guest_regs.eax().* = orig.eax; // version information.
            guest_regs.ebx().* = orig.ebx; // brand index / CLFLUSH line size / Addressable IDs / Initial APIC ID
            guest_regs.ecx().* = @truncate(@as(u64, @bitCast(features)));
            guest_regs.edx().* = @truncate(@as(u64, @bitCast(features)) >> 32);
        },
        .ext_func => {
            guest_regs.eax().* = 0x8000_0000 + 1; // maximum input value for extended function CPUID.
            guest_regs.ebx().* = 0; // reserved
            guest_regs.ecx().* = 0; // reserved
            guest_regs.edx().* = 0; // reserved
        },
        .ext_proc_signature => {
            const orig = rawCpuid(leaf, subleaf);
            guest_regs.eax().* = 0; // extended processor signature and feature bits.
            guest_regs.ebx().* = 0; // reserved
            guest_regs.ecx().* = orig.ecx; // LAHF in 64-bit mode / LZCNT / PREFETCHW
            guest_regs.edx().* = orig.edx; // SYSCALL / XD / 1GB large page / RDTSCP and IA32_TSC_AUX / Intel64
        },
        .hypervisor => {
            guest_regs.eax().* = 0x40000000; // maximum input value for hypervisor leaves.
            guest_regs.ebx().* = std.mem.readInt(u32, hypervisor_sig[0..4], .little);
            guest_regs.ecx().* = std.mem.readInt(u32, hypervisor_sig[4..8], .little);
            guest_regs.edx().* = std.mem.readInt(u32, hypervisor_sig[8..12], .little);
        },
        .thermal_power => {
            invalid(vcpu);
        },
        .ext_feature => {
            switch (subleaf) {
                0 => {
                    guest_regs.eax().* = 1; // Maximum input value for supported leaf 7 sub-leaves.
                    guest_regs.ebx().* = @bitCast(ext_feature0_ebx);
                    guest_regs.ecx().* = 0; // unimplemented
                    guest_regs.edx().* = 0; // unimplemented
                },
                1, 2 => invalid(vcpu),
                else => try vcpu.abortMsg("Unhandled CPUID: Leaf=0x{X:0>8}, Sub=0x{X:0>8}\n", .{ guest_regs.rax, guest_regs.rcx }),
            }
        },
        .ext_enumeration => {
            switch (subleaf) {
                1 => invalid(vcpu),
                else => try vcpu.abortMsg("Unhandled CPUID: Leaf=0x{X:0>8}, Sub=0x{X:0>8}\n", .{ guest_regs.rax, guest_regs.rcx }),
            }
        },
        _ => {
            if (leaf > 0x40000000 and leaf <= 0x4fffffff) {
                // hypervisor leaves
                invalid(vcpu);
                return;
            }
            std.log.warn("Unhandled CPUID: Leaf=0x{X:0>8}, Sub=0x{X:0>8}\n", .{ guest_regs.rax, guest_regs.rcx });
            invalid(vcpu);
        },
    }
}

fn invalid(vcpu: *Vcpu) void {
    vcpu.regs.eax().* = 0;
    vcpu.regs.ebx().* = 0;
    vcpu.regs.ecx().* = 0;
    vcpu.regs.edx().* = 0;
}
