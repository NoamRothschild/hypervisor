const std = @import("std");
const hhdm = @import("../mem/hhdm.zig");
const mem_allocator = @import("../mem/allocator.zig");
const debug = @import("../debug.zig");
const msr = @import("msr.zig");
const vmx = @import("vmx.zig");
const vmcs = @import("vmcs.zig");
const ept = @import("ept.zig");
const io = @import("io.zig");
const simulate = @import("simulate.zig");
const pic_hw = @import("../arch/x86_64/pic.zig");
const lapic = @import("smp/lapic.zig");
const rdmsr = msr.rdmsr;
const vmread = vmx.vmread;
const vmwrite = vmx.vmwrite;
const tsc = @import("../arch/x86_64/tsc.zig");

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
    /// software-only MSR values. not in `guest_msr`, that area is loaded into the real MSRs on entry.
    shadow_msrs: struct {
        tsc_adjust: u64 = 0,
        /// locked with nothing enabled: VMX is hidden from the guest, so VMXON stays disabled
        feature_control: u64 = 1,
    },

    virt_lapic: [1024]u32 = @splat(0),
    /// TSC when the guest last wrote the APIC timer's initial count, see `lapic.timerCurrentCount`
    lapic_timer_start_tsc: u64,
    /// TSC at which the APIC timer next fires, 0 when it doesn't. see `lapic.timerPoll`
    lapic_timer_deadline_tsc: u64,
    /// the VMX-preemption timer counts down once every 2^shift TSC cycles (IA32_VMX_MISC[4:0])
    preemption_timer_shift: u5,

    serial: io.Serial,
    pic: io.Pic,
    /// host IRQs not yet injected into the guest, bit n is IRQ n. filled from `pic.takeReceived`.
    pending_irq: u16,

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
        self.shadow_msrs = .{};
        self.serial = .{};
        self.pic = .init;
        self.pending_irq = 0;
        self.virt_lapic = @splat(0);
        self.lapic_timer_start_tsc = 0;
        self.lapic_timer_deadline_tsc = 0;
        self.preemption_timer_shift = @truncate(rdmsr(.IA32_VMX_MISC));
        {
            // set ID in lapic
            self.virt_lapic[0x20 / 4] = @as(u32, @truncate(index)) << 24;
            // set VERSION in lapic
            self.virt_lapic[0x30 / 4] = 0x0005_0014; // version 0x14, maximum LVT index 5
            self.virt_lapic[0xE0 / 4] = 0xFFFF_FFFF;
            self.virt_lapic[0xF0 / 4] = 0x0000_00FF;
            // 0x2F0 CMCI, 0x320 timer, 0x330 thermal, 0x340 perfmon, 0x350 LINT0, 0x360 LINT1, 0x370 error
            for (&[_]u32{ 0x2F0, 0x320, 0x330, 0x340, 0x350, 0x360, 0x370 }) |lvt|
                self.virt_lapic[@divFloor(lvt, 4)] = 0x0001_0000;
        }

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

            .ept_violation => {
                const violating_addr: ept.GuestPhys = .from(vmread(.GUEST_PHYSICAL_ADDRESS));
                switch (violating_addr.raw()) {
                    0xfee00000...0xfee00fff => try lapic.eptViolation(self, violating_addr),
                    else => try self.abort(),
                }

                // The CPU doesn't fill VM_EXIT_INSTRUCTION_LEN for EPT violations
                return .resume_at_rip;
            },

            .msr_read, .msr_write => if (msr.isAbsent(@enumFromInt(self.regs.ecx().*)))
                return self.injectGp()
            else if (exit_reason == .msr_read)
                try simulate.rdmsr(self)
            else
                try simulate.wrmsr(self),
            .cr_access => try simulate.crAccess(self, exit_qual.cr),
            .io_instruction => try simulate.handleIo(self, exit_qual.io),

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

            .cpuid => try simulate.cpuid(self),
            .external_interrupt => {
                // no ack-on-exit, so the IRQ is still pending in the PIC, and IF is 0 after
                // any VM-exit. open a window for the host to take it: `pic.irqHandler` records
                // it and sends the EOI, `prepareEntry` picks it up.
                asm volatile ("sti; nop; cli");
                return .resume_at_rip;
            },
            // nothing to do here, `prepareEntry` injects whatever is pending and re-arms both
            .pending_virt_intr, .vmx_preemption_timer_expired => return .resume_at_rip,
            .hlt => {
                if (vmread(.GUEST_RFLAGS) & rflags_if == 0) {
                    std.log.info("guest halted with interrupts disabled\n", .{});
                    return .exit;
                }
                // the hlt is stepped over on resume, so an `sti; hlt` shadow ends with it
                vmwrite(.GUEST_INTERRUPTIBILITY_INFO, 0);
                // the guest sleeps in VMX non-root until something exits it: a host IRQ or
                // the preemption timer. `prepareEntry` wakes it when it injects an interrupt.
                vmwrite(.GUEST_ACTIVITY_STATE, @intFromEnum(ActivityState.hlt));
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

    /// Runs before every VM entry. Injects the highest pending interrupt if the guest
    /// can take one now, otherwise asks for an exit as soon as it can (interrupt-window
    /// exiting), and arms the preemption timer for the next LAPIC timer expiry.
    fn prepareEntry(self: *Vcpu) void {
        lapic.timerPoll(self);
        self.pending_irq |= pic_hw.takeReceived();

        // a handler or `reinjectInterruptedEvent` already injects something this entry
        const entry_busy = vmread(.VM_ENTRY_INTR_INFO_FIELD) & entry_intr_valid != 0;
        if (!entry_busy and canTakeInterrupt()) {
            if (self.takePendingInterrupt()) |vector| {
                const info: vmx.EntryIntrInfo = .{
                    .vector = vector,
                    .type = .external,
                    .ec_available = false,
                    .valid = true,
                };
                vmwrite(.VM_ENTRY_INTR_INFO_FIELD, @as(u32, @bitCast(info)));
                // a halted guest wakes to take it
                vmwrite(.GUEST_ACTIVITY_STATE, @intFromEnum(ActivityState.active));
            }
        }

        // whatever is still pending goes in on the first entry the guest can take it
        var ctls = vmread(.CPU_BASED_VM_EXEC_CONTROL);
        const window: u64 = @intFromEnum(vmcs.VmExecutionControl.CPU_BASED_VIRTUAL_INTR_PENDING);
        if (self.hasPendingInterrupt()) ctls |= window else ctls &= ~window;
        vmwrite(.CPU_BASED_VM_EXEC_CONTROL, ctls);

        const preemption_ticks: u64 = if (lapic.timerDeadline(self)) |deadline|
            (deadline -| tsc.read()) >> self.preemption_timer_shift
        else
            std.math.maxInt(u32);
        vmwrite(.VMX_PREEMPTION_TIMER_VALUE, @min(preemption_ticks, std.math.maxInt(u32)));
    }

    /// IF is set and there is no STI or MOV SS blocking, VM entry fails if an
    /// interrupt is injected during either.
    fn canTakeInterrupt() bool {
        return vmread(.GUEST_RFLAGS) & rflags_if != 0 and
            vmread(.GUEST_INTERRUPTIBILITY_INFO) & 0b11 == 0;
    }

    fn hasPendingInterrupt(self: *Vcpu) bool {
        return lapic.pendingVector(self) != null or self.pendingPicIrq() != null;
    }

    /// marks the highest priority pending interrupt as delivered and returns its vector.
    fn takePendingInterrupt(self: *Vcpu) ?u8 {
        if (lapic.pendingVector(self)) |vector| {
            lapic.acceptVector(self, vector);
            return vector;
        }
        const irq = self.pendingPicIrq() orelse return null;
        self.pending_irq &= ~(@as(u16, 1) << irq);
        return if (irq < 8) self.pic.primary_base + irq else self.pic.secondary_base + (irq - 8);
    }

    /// the lowest unmasked IRQ waiting in the virtual PIC, if the guest set it up.
    /// the host already sent the EOI, so the guest's own EOIs are dropped (see `io.zig`).
    fn pendingPicIrq(self: *Vcpu) ?u4 {
        const pic = &self.pic;
        if (self.pending_irq == 0) return null;
        // no vector base from the guest yet
        if (pic.primary_phase != .initialized) return null;
        // the PIC's output reaches the cpu through LINT0
        if (!lapic.acceptsExtInt(self)) return null;

        const secondary_masked = pic.primary_mask & (1 << pic_hw.cascade_irq) != 0;
        const masked: u16 = @as(u16, if (secondary_masked) 0xff else pic.secondary_mask) << 8 | pic.primary_mask;
        const injectable = self.pending_irq & ~masked;
        if (injectable == 0) return null;
        return @intCast(@ctz(injectable));
    }

    /// An event the CPU was delivering to the guest when the VM-exit happened (an
    /// injected interrupt whose delivery hit an EPT violation, say) never reached
    /// the guest. Inject it again on the next entry, or it is lost.
    fn reinjectInterruptedEvent() void {
        var info: vmx.EntryIntrInfo = @bitCast(@as(u32, @truncate(vmread(.IDT_VECTORING_INFO_FIELD))));
        if (!info.valid) return;
        // bit 12 is undefined in IDT-vectoring info, and reserved in entry info
        info.rsvd = 0;
        vmwrite(.VM_ENTRY_INTR_INFO_FIELD, @as(u32, @bitCast(info)));
        if (info.ec_available)
            vmwrite(.VM_ENTRY_EXCEPTION_ERROR_CODE, vmread(.IDT_VECTORING_ERROR_CODE));
        switch (info.type) {
            // `int n`, `int3`, `into` and `int1` restart after the instruction
            .sw_interrupt, .priv_sw_exception, .sw_exception => vmwrite(.VM_ENTRY_INSTRUCTION_LEN, vmread(.VM_EXIT_INSTRUCTION_LEN)),
            else => {},
        }
    }

    /// makes the next VM-entry raise #GP(0) in the guest, as hardware does for an
    /// instruction it refuses.
    pub fn injectGp(_: *Vcpu) ExitAction {
        const info: vmx.EntryIntrInfo = .{
            .vector = 13, // #GP
            .type = .hw_exception,
            .ec_available = true,
            .valid = true,
        };
        vmwrite(.VM_ENTRY_EXCEPTION_ERROR_CODE, 0);
        vmwrite(.VM_ENTRY_INTR_INFO_FIELD, @as(u32, @bitCast(info)));
        return .resume_at_rip;
    }

    /// calls vmlaunch.
    /// ret val indicates success of operation
    ///
    /// returns either if vmlaunch failed
    /// or when after the VM caused an exit (will block)
    pub fn vmlaunch(self: *Vcpu, guest_regs: *Regs) bool {
        self.regs = guest_regs;
        self.updateMsrs();
        // IRQs from before the guest existed aren't its to receive
        _ = pic_hw.takeReceived();

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

const rflags_if: u64 = 1 << 9;
/// `VM_ENTRY_INTR_INFO_FIELD` holds an event to inject, cleared by every VM-exit
const entry_intr_valid: u64 = 1 << 31;

/// values of `GUEST_ACTIVITY_STATE`
const ActivityState = enum(u64) {
    active = 0,
    hlt = 1,
};

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

    const old_debug_enable = debug.logging_enabled;
    defer debug.logging_enabled = old_debug_enable;
    switch (exit_reason) {
        .io_instruction,
        .cr_access,
        .external_interrupt,
        .hlt,
        .pending_virt_intr,
        .vmx_preemption_timer_expired,
        // every timer tick is an EOI write and often a count read: logging them makes each
        // interrupt take longer than the timer period, and the guest never leaves its handler
        .ept_violation,
        // FS_BASE is written on every context switch between user processes
        .msr_write,
        .msr_read,
        => debug.logging_enabled = false,
        else => {},
    }

    std.log.info("vm exit! info: .{{ .reason = {s}, .qual = 0x{x}, .addr = 0x{x} }}\n", .{
        @tagName(exit_reason),
        exit_qual.backing_int,
        vmread(.GUEST_RIP),
    });

    Vcpu.reinjectInterruptedEvent();
    const action = vcpu.tryExitReason(exit_reason, exit_qual) catch |err| switch (err) {
        error.Aborted => {
            std.log.err("vcpu {d} aborted at rip 0x{x} after {s} (0x{x}); not resuming\n", .{
                vcpu.index,
                vmread(.GUEST_RIP),
                @tagName(exit_reason),
                exit_qual.backing_int,
            });
            return .exit;
        },
    };
    if (action != .exit) vcpu.prepareEntry();
    return action;
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
