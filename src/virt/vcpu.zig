const std = @import("std");
const hhdm = @import("../mem/hhdm.zig");
const mem_allocator = @import("../mem/allocator.zig");
const debug = @import("../debug.zig");
const msr = @import("msr.zig");
const vmx = @import("vmx.zig");
const vmcs = @import("vmcs.zig");
const ept = @import("ept.zig");
const simulate = @import("simulate.zig");
const rdmsr = msr.rdmsr;
const vmread = vmx.vmread;
const vmwrite = vmx.vmwrite;

/// Everything that belongs to a single logical core of the guest. State shared
/// by all cores lives in `vmx.VMState`.
pub const Vcpu = struct {
    /// the VM this vcpu belongs to
    vm: *vmx.VMState,
    /// position in `vm.cpus`
    index: usize,
    vmxon_region: ept.HostPhys,
    vmcs_region: ept.HostPhys,
    /// virt addr, stack for vmm in VM-Exit state. The top `stack_reserved` bytes
    /// hold the `*Vcpu` that `vmExitHandler` reads to find its vcpu.
    vmm_stack: []align(4096) u8,

    host_msr: msr.MsrArea,
    guest_msr: msr.MsrArea,

    /// the guest's general purpose registers.
    /// while handling a VM-exit this points at the frame `vmExitHandler` pushed.
    regs: *Regs,

    /// where `__vmlaunch` was called from, `__vmReturnSucceed` returns there.
    old_rsp: u64,
    old_rbp: u64,

    /// top of the vmm stack that is reserved for the `*Vcpu` slot
    const stack_reserved = 16;
    /// pushes done by `vmExitHandler`, the distance from its frame to the `*Vcpu` slot
    const exit_frame_size = @sizeOf(Regs);

    pub const Regs = extern struct {
        r15: u64,
        r14: u64,
        r13: u64,
        r12: u64,
        r11: u64,
        r10: u64,
        r9: u64,
        r8: u64,
        rdi: u64,
        rsi: u64,
        rbp: u64,
        rbx: u64,
        rdx: u64,
        rcx: u64,
        rax: u64,

        pub inline fn eax(self: *Regs) *u32 {
            return @ptrCast(&self.rax);
        }
        pub inline fn ebx(self: *Regs) *u32 {
            return @ptrCast(&self.rbx);
        }
        pub inline fn ecx(self: *Regs) *u32 {
            return @ptrCast(&self.rcx);
        }
        pub inline fn edx(self: *Regs) *u32 {
            return @ptrCast(&self.rdx);
        }
        pub inline fn esi(self: *Regs) *u32 {
            return @ptrCast(&self.rsi);
        }
        pub inline fn edi(self: *Regs) *u32 {
            return @ptrCast(&self.rdi);
        }
    };

    /// allocates everything the vcpu owns. executes no vmx instruction.
    pub fn init(self: *Vcpu, vm: *vmx.VMState, index: usize) !void {
        self.vm = vm;
        self.index = index;
        self.old_rsp = 0;
        self.old_rbp = 0;

        self.vmm_stack = try mem_allocator.kalloc.allocPages(1);
        @memset(self.vmm_stack, 0);
        const slot: **Vcpu = @ptrCast(@alignCast(self.vmm_stack.ptr + self.vmm_stack.len - stack_reserved));
        slot.* = self;

        try self.allocVmxonRegion();
        try self.allocVmcsRegion();
    }

    /// value for the VMCS `HOST_RSP` field.
    /// points at the `*Vcpu` slot, so the first push of `vmExitHandler` lands below it.
    pub fn hostRsp(self: *const Vcpu) u64 {
        return @intFromPtr(self.vmm_stack.ptr) + self.vmm_stack.len - stack_reserved;
    }

    /// Prepares the VMXON region. `vmxon()` executes it.
    fn allocVmxonRegion(self: *Vcpu) !void {
        const vmxon_page = try mem_allocator.kalloc.allocPage();
        const vmxon_region_phys = hhdm.physOf(vmxon_page);

        std.log.info("virtual buff addr for VMXON at 0x{x}\n", .{@intFromPtr(vmxon_page)});
        std.log.info("physical buff addr for VMXON at 0x{x}\n", .{vmxon_region_phys.raw()});

        @memset(vmxon_page, 0);
        @as(*volatile u32, @ptrCast(vmxon_page)).* = revisionIdentifier();
        self.vmxon_region = vmxon_region_phys;
    }

    /// Prepares the VMCS region. `vmclear()` and `vmptrld()` activate it, after `vmxon()`.
    fn allocVmcsRegion(self: *Vcpu) !void {
        const vmcs_page = try mem_allocator.kalloc.allocPage();
        const vmcs_region_phys = hhdm.physOf(vmcs_page);

        std.log.info("virtual buff addr for VMCS at 0x{x}\n", .{@intFromPtr(vmcs_page)});
        std.log.info("physical buff addr for VMCS at 0x{x}\n", .{vmcs_region_phys.raw()});

        @memset(vmcs_page, 0);
        @as(*volatile u32, @ptrCast(vmcs_page)).* = revisionIdentifier();

        self.vmcs_region = vmcs_region_phys;
    }

    fn revisionIdentifier() u32 {
        const revision_identifier: u32 = @truncate(rdmsr(.IA32_VMX_BASIC));
        std.log.info("IA32_VMX_BASIC revision identifier: 0x{x}\n", .{revision_identifier});
        return revision_identifier;
    }

    /// executes VMXON with this vcpu's region, entering VMX operation on the current core.
    pub fn vmxon(self: *Vcpu) !void {
        // carry flag result
        var failed: u8 = undefined;
        // zero flag result
        var valid_fail: u8 = undefined;

        asm volatile (
            \\ vmxon (%[vmxon_phys_ptr])
            \\ setc %[failed]
            \\ setz %[valid_fail]
            : [failed] "=qm" (failed),
              [valid_fail] "=qm" (valid_fail),
            : [vmxon_phys_ptr] "r" (&self.vmxon_region),
        );

        if (failed != 0)
            return error.vmxon_failed_cf;

        if (valid_fail != 0) {
            debug.printf("vmxon failed with {d}\n", .{vmx.vmerr()});
            return error.vmxon_failed_with_code;
        }
    }

    /// FIXME: I didn't test it acutally works.
    ///
    /// calls vmclear with the vmcs ptr.
    ///  returns if failed or succeeded
    pub fn vmclear(self: *Vcpu) bool {
        var cf: u8 = undefined;
        var zf: u8 = undefined;

        asm volatile (
            \\ vmclear (%[vmcs_phys_ptr])
            \\ setc %[cf]
            \\ setz %[zf]
            : [cf] "=qm" (cf),
              [zf] "=qm" (zf),
            : [vmcs_phys_ptr] "r" (&self.vmcs_region),
        );

        var failed = false;
        if (cf != 0) {
            std.log.err("vmclear failed (cf=1)\n", .{});
            failed = true;
        }

        if (zf != 0) {
            std.log.err("vmclear failiure error code: {d}\n", .{vmx.vmerr()});
            failed = true;
        }

        return !failed;
    }

    /// sets the current VMCS to `vmcs_region`
    pub fn vmptrld(self: *Vcpu) bool {
        var cf: u8 = undefined;
        var zf: u8 = undefined;

        asm volatile (
            \\ vmptrld (%[vmcs_phys_ptr])
            \\ setc %[cf]
            \\ setz %[zf]
            : [cf] "=qm" (cf),
              [zf] "=qm" (zf),
            : [vmcs_phys_ptr] "r" (&self.vmcs_region),
        );

        if ((cf != 0) or (zf != 0)) {
            std.log.err("vmptrld failed with {s} (zf={d})\n", .{ if (zf == 0) "VMFailInvalid" else "VMFailValid", @intFromBool(zf != 0) });
            if (zf != 0) {
                debug.printf("vmptrld failiure error code: {d}\n", .{vmx.vmerr()});
            }
            return false;
        }
        return true;
    }

    /// allocates and fills the host/guest msr areas, and points the VMCS at them.
    pub fn setupMsrs(self: *Vcpu, alloc: *mem_allocator.KAlloc) error{OutOfMemory}!void {
        self.host_msr = try .init(alloc);
        self.guest_msr = try .init(alloc);

        const hm = &self.host_msr;
        const gm = &self.guest_msr;

        // host msrs
        hm.set(.TSC_AUX, rdmsr(.TSC_AUX));
        hm.set(.STAR, rdmsr(.STAR));
        hm.set(.LSTAR, rdmsr(.LSTAR));
        hm.set(.CSTAR, rdmsr(.CSTAR));
        hm.set(.SYSCALL_MASK, rdmsr(.SYSCALL_MASK));
        hm.set(.KERNEL_GS_BASE, rdmsr(.KERNEL_GS_BASE));

        // guest msrs
        gm.set(.TSC_AUX, 0);
        gm.set(.STAR, 0);
        gm.set(.LSTAR, 0);
        gm.set(.CSTAR, 0);
        gm.set(.SYSCALL_MASK, 0);
        gm.set(.KERNEL_GS_BASE, 0);

        const hm_low: u32 = @truncate(hm.phys().raw());
        const hm_high: u32 = @truncate(hm.phys().raw() >> 32);

        const gm_low: u32 = @truncate(gm.phys().raw());
        const gm_high: u32 = @truncate(gm.phys().raw() >> 32);

        vmwrite(.VM_EXIT_MSR_LOAD_ADDR, hm_low);
        vmwrite(.VM_EXIT_MSR_STORE_ADDR, gm_low);
        vmwrite(.VM_ENTRY_MSR_LOAD_ADDR, gm_low);
        vmwrite(.VM_EXIT_MSR_LOAD_ADDR_HIGH, hm_high);
        vmwrite(.VM_EXIT_MSR_STORE_ADDR_HIGH, gm_high);
        vmwrite(.VM_ENTRY_MSR_LOAD_ADDR_HIGH, gm_high);
    }

    /// refreshes the host msr values and the entry/exit msr counts
    pub fn updateMsrs(self: *Vcpu) void {
        for (self.host_msr.savedMsrs()) |e|
            self.host_msr.setByIndex(e.index, rdmsr(@enumFromInt(e.index)));

        vmwrite(.VM_EXIT_MSR_LOAD_COUNT, self.host_msr.registered_entries);
        vmwrite(.VM_EXIT_MSR_STORE_COUNT, self.guest_msr.registered_entries);
        vmwrite(.VM_ENTRY_MSR_LOAD_COUNT, self.guest_msr.registered_entries);
    }

    /// The guest did something that can't be continued from: it faulted, or it tried
    /// something the hypervisor doesn't support (yet). Not for hypervisor bugs, those panic.
    /// Handlers propagate this up to `mainVmExitHandler`, which stops the vcpu.
    pub fn abort(_: *Vcpu) error{Aborted}!void {
        return error.Aborted;
    }

    /// same as `abort`, printing why first.
    pub fn abortMsg(_: *Vcpu, comptime fmt: []const u8, args: anytype) error{Aborted}!void {
        std.log.err(fmt, args);
        return error.Aborted;
    }

    /// decides what to do about a VM-exit, see `ExitAction`.
    /// fails with `error.Aborted` when the vcpu can't continue, see `abort`.
    fn tryExitReason(self: *Vcpu, exit_reason: vmx.ExitReason, exit_qual: vmx.ExitQualification) error{Aborted}!ExitAction {
        switch (exit_reason) {
            .vmclear,
            .vmptrld,
            .vmptrst,
            .vmread,
            .vmresume,
            .vmwrite,
            .vmxoff,
            .vmxon,
            .vmlaunch,
            => {},

            .msr_read => {
                try simulate.rdmsr(self);
                return .@"resume";
            },
            .msr_write => {
                try simulate.wrmsr(self);
                return .@"resume";
            },

            .cr_access => {
                try simulate.crAccess(self, exit_qual.cr);
                return .@"resume";
            },

            .exception_nmi => {
                const intr_info = vmread(.VM_EXIT_INTR_INFO);
                const vector = intr_info & 0xff;
                const err_valid = (intr_info >> 11) & 1;
                std.log.err(
                    "guest exception: vector {d} (info 0x{x}) err 0x{x}{s} at rip 0x{x}, linear 0x{x}, cr2-ish qual 0x{x}\n",
                    .{
                        vector,
                        intr_info,
                        vmread(.VM_EXIT_INTR_ERROR_CODE),
                        if (err_valid == 0) " (no err code)" else "",
                        vmread(.GUEST_RIP),
                        vmread(.GUEST_LINEAR_ADDRESS),
                        exit_qual.backing_int,
                    },
                );
                return .exit;
            },

            .cpuid => simulate.cpuid(self),
            .hlt => {
                std.log.info("user executed hlt\n", .{});
                return .exit;
            },
            .triple_fault => {
                std.log.err("guest triple faulted at rip 0x{x}; not resuming\n", .{vmread(.GUEST_RIP)});
                return .exit;
            },
            .invalid_guest_state => {
                std.log.err("invalid guest state; not resuming\n", .{});
                return .exit;
            },
            else => {
                std.log.err("unhandled exit reason: {}; not resuming\n", .{exit_reason});
                return .exit;
            },
        }
        return .@"resume";
    }

    /// calls vmlaunch.
    /// ret val indicates success of operation
    ///
    /// returns either if vmlaunch failed
    /// or when after the VM caused an exit (will block)
    pub fn vmlaunch(self: *Vcpu, guest_regs: *Regs) bool {
        self.regs = guest_regs;
        self.updateMsrs();

        const ret = asm volatile ("call __vmlaunch"
            : [ret] "={al}" (-> u8),
            : [regs] "{rdi}" (guest_regs),
              [vcpu] "{rsi}" (self),
            : .{
              .rcx = true,
              .rdx = true,
              .rsi = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .memory = true,
            });
        return ret != 0;
    }
};

/// `rdi` points at the `Regs` the guest should start with, `rsi` at its `Vcpu`
export fn __vmlaunch() callconv(.naked) void {
    asm volatile (std.fmt.comptimePrint(
            \\ push %rbp
            \\ mov %rsp, %rbp
            \\ mov %rbp, {[old_rbp]d}(%rsi)
            \\ mov %rsp, {[old_rsp]d}(%rsi)
            \\
            \\ mov %rdi, %rax
            \\ mov 0(%rax), %r15
            \\ mov 8(%rax), %r14
            \\ mov 16(%rax), %r13
            \\ mov 24(%rax), %r12
            \\ mov 32(%rax), %r11
            \\ mov 40(%rax), %r10
            \\ mov 48(%rax), %r9
            \\ mov 56(%rax), %r8
            \\ mov 80(%rax), %rbp
            \\ mov 88(%rax), %rbx
            \\ mov 96(%rax), %rdx
            \\ mov 104(%rax), %rcx
            \\ mov 72(%rax), %rsi
            \\ mov 64(%rax), %rdi
            \\ mov 112(%rax), %rax
            \\
            \\ vmlaunch
            \\
            \\ call __vmlaunchFailed
            \\ mov $0, %rax
            \\ pop %rbp
            \\ ret
        , .{
            .old_rbp = @offsetOf(Vcpu, "old_rbp"),
            .old_rsp = @offsetOf(Vcpu, "old_rsp"),
        }) ::: .{ .rax = true, .memory = true });
}

export fn __vmlaunchFailed() callconv(.c) void {
    std.log.err("vmlaunch failed with error code: {d}\n", .{vmx.vmerr()});
}

/// Return to the `call __vmlaunch` site after a handled VM-exit.
/// must be naked and entered with `jmp` (not `call`) so there is no C prologue.
/// `rbx` points at the frame pushed by `vmExitHandler`.
export fn __vmReturnSucceed() callconv(.naked) void {
    asm volatile (std.fmt.comptimePrint(
            \\ mov {[vcpu_slot]d}(%rbx), %rax
            \\ mov {[old_rbp]d}(%rax), %rbp
            \\ mov {[old_rsp]d}(%rax), %rsp
            \\ mov $1, %rax
            \\ pop %rbp
            \\ ret
        , .{
            .vcpu_slot = Vcpu.exit_frame_size,
            .old_rbp = @offsetOf(Vcpu, "old_rbp"),
            .old_rsp = @offsetOf(Vcpu, "old_rsp"),
        }) ::: .{ .rax = true, .rbp = true, .rsp = true });
}

pub fn vmExitHandler() callconv(.naked) void {
    asm volatile (std.fmt.comptimePrint(
            \\ push %rax
            \\ push %rcx
            \\ push %rdx
            \\ push %rbx
            \\ push %rbp
            \\ push %rsi
            \\ push %rdi
            \\ push %r8
            \\ push %r9
            \\ push %r10
            \\ push %r11
            \\ push %r12
            \\ push %r13
            \\ push %r14
            \\ push %r15
            \\
            \\ // rbx is callee-saved under SysV.
            \\ mov %rsp, %rbx
            \\ // the `*Vcpu` slot sits right above the pushed frame
            \\ mov {[vcpu_slot]d}(%rbx), %rdi
            \\ mov %rbx, %rsi
            \\
            \\ // force the 16-byte alignment SysV wants
            \\ and $-16, %rsp
            \\ call mainVmExitHandler
            \\
            \\ // al is an `ExitAction`
            \\ // exit(1) => stop and return to kmain
            \\ cmp $1, %al
            \\ je __vmReturnSucceed
            \\
            \\ // resume_at_rip(2) => the handler already set GUEST_RIP
            \\ cmp $2, %al
            \\ je 1f
            \\ call resumeToNextInstruction
            \\1:
            \\ mov %rbx, %rsp
            \\
            \\ pop %r15
            \\ pop %r14
            \\ pop %r13
            \\ pop %r12
            \\ pop %r11
            \\ pop %r10
            \\ pop %r9
            \\ pop %r8
            \\ pop %rdi
            \\ pop %rsi
            \\ pop %rbp
            \\ pop %rbx
            \\ pop %rdx
            \\ pop %rcx
            \\ pop %rax
            \\
            \\ vmresume
            \\
            \\ call vmResumeInstructionFailed
        , .{ .vcpu_slot = Vcpu.exit_frame_size }));
}

/// What `vmExitHandler` does once `mainVmExitHandler` returns. values are matched in its asm.
pub const ExitAction = enum(u8) {
    /// advance RIP past the exiting instruction, then resume the guest
    @"resume" = 0,
    /// leave the guest and return to kmain
    exit = 1,
    /// resume the guest at GUEST_RIP as is, for handlers that set RIP themselves (e.g. an emulated IRET)
    resume_at_rip = 2,
};

/// Returns what the VMM should do next, see `ExitAction`.
/// `vcpu` is the vcpu that exited, `guest_regs` the frame `vmExitHandler` pushed.
export fn mainVmExitHandler(vcpu: *Vcpu, guest_regs: *Vcpu.Regs) callconv(.c) ExitAction {
    vcpu.regs = guest_regs;

    const exit_reason: vmx.ExitReason = @enumFromInt(vmread(.VM_EXIT_REASON) & 0xffff);
    const exit_qual: vmx.ExitQualification = .{
        .backing_int = vmread(.EXIT_QUALIFICATION),
    };

    std.log.info("vm exit! info: .{{ .reason = {s}, .qual = 0x{x}, .addr = 0x{x} }}\n", .{
        @tagName(exit_reason),
        exit_qual.backing_int,
        vmread(.GUEST_RIP),
    });

    return vcpu.tryExitReason(exit_reason, exit_qual) catch |err| switch (err) {
        error.Aborted => {
            std.log.err("vcpu {d} aborted at rip 0x{x}; not resuming\n", .{ vcpu.index, vmread(.GUEST_RIP) });
            return .exit;
        },
    };
}

export fn resumeToNextInstruction() callconv(.c) void {
    const current_rip = vmread(.GUEST_RIP);
    const exit_instr_len = vmread(.VM_EXIT_INSTRUCTION_LEN);
    vmwrite(.GUEST_RIP, current_rip +% exit_instr_len);
}

export fn vmResumeInstructionFailed() callconv(.c) noreturn {
    std.log.err("vmresume failed with error code: {d}\n", .{vmx.vmerr()});

    while (true)
        asm volatile ("hlt");
}
