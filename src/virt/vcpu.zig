const std = @import("std");
const hhdm = @import("../mem/hhdm.zig");
const mem_allocator = @import("../mem/allocator.zig");
const debug = @import("../debug.zig");
const msr = @import("msr.zig");
const vmx = @import("vmx.zig");
const vmcs = @import("vmcs.zig");
const ept = @import("ept.zig");
const simulate = @import("simulate.zig");
const pic_hw = @import("../arch/x86_64/pic.zig");
const lapic = @import("smp/lapic.zig");
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
    /// whether the scheduler (`Pcpu.run`) may enter the vcpu
    state: State,
    vmcs_region: ept.HostPhys,
    /// whether the VMCS was launched, the next entry is a `vmresume` then
    launched: bool,

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

    /// guest state to (re)start from, written into the VMCS by the next `prepareEntry`.
    /// set by `start`.
    pending_start: ?vmcs.GuestStart,

    /// the guest's general purpose registers, except RSP which lives in the VMCS.
    /// `__vmEnter` loads them into the cpu, `__vmExit` stores them back.
    regs: Regs,

    pub const State = enum {
        /// entered whenever the scheduler picks it. a halted guest sleeps inside
        /// VMX non-root (the HLT activity state), so it is still runnable
        runnable,
        /// not started yet (`start`), or stopped for good: aborted, faulted or shut down
        stopped,
    };

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
        self.state = .stopped;
        self.launched = false;
        self.regs = std.mem.zeroes(Regs);
        self.shadow_msrs = .{};
        self.pending_start = null;
        self.virt_lapic = @splat(0);
        self.lapic_timer_start_tsc = 0;
        self.lapic_timer_deadline_tsc = 0;
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

        try self.allocVmcsRegion();
    }

    /// makes the vcpu runnable, starting from `start_state` on its next entry
    pub fn start(self: *Vcpu, start_state: vmcs.GuestStart) void {
        self.pending_start = start_state;
        self.state = .runnable;
    }

    /// Prepares the VMCS region. `vmclear()` and `vmptrld()` activate it, after `Pcpu.init`.
    fn allocVmcsRegion(self: *Vcpu) !void {
        const vmcs_page = try mem_allocator.kalloc.allocPage();
        const vmcs_region_phys = hhdm.physOf(vmcs_page);

        std.log.info("virtual buff addr for VMCS at 0x{x}\n", .{@intFromPtr(vmcs_page)});
        std.log.info("physical buff addr for VMCS at 0x{x}\n", .{vmcs_region_phys.raw()});

        @memset(vmcs_page, 0);
        @as(*volatile u32, @ptrCast(vmcs_page)).* = vmx.revisionIdentifier();

        self.vmcs_region = vmcs_region_phys;
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
    /// Handlers propagate this up to `handleExit`, which stops the vcpu.
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

    /// Runs before every VM entry, with the VMCS current. Applies a pending start state,
    /// injects the highest pending interrupt if the guest can take one now, otherwise
    /// asks for an exit as soon as it can (interrupt-window exiting).
    /// the preemption timer is armed by `Pcpu.run`, it knows the other vcpus' timers too.
    pub fn prepareEntry(self: *Vcpu) void {
        if (self.pending_start) |start_state| {
            vmcs.setGuestStart(start_state);
            self.pending_start = null;
        }
        if (!self.launched) self.updateMsrs();

        lapic.timerPoll(self);
        self.vm.pending_irq |= pic_hw.takeReceived();

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
        const pic = &self.vm.pic;
        self.vm.pending_irq &= ~(@as(u16, 1) << irq);
        return if (irq < 8) pic.primary_base + irq else pic.secondary_base + (irq - 8);
    }

    /// the lowest unmasked IRQ waiting in the virtual PIC, if the guest set it up.
    /// the host already sent the EOI, so the guest's own EOIs are dropped (see `io.zig`).
    fn pendingPicIrq(self: *Vcpu) ?u4 {
        const pic = &self.vm.pic;
        // the PIC's INTR line is wired to the BSP's LINT0 only, as a BIOS leaves it
        if (self.index != 0) return null;
        if (self.vm.pending_irq == 0) return null;
        // no vector base from the guest yet
        if (pic.primary_phase != .initialized) return null;
        // the PIC's output reaches the cpu through LINT0
        if (!lapic.acceptsExtInt(self)) return null;

        const secondary_masked = pic.primary_mask & (1 << pic_hw.cascade_irq) != 0;
        const masked: u16 = @as(u16, if (secondary_masked) 0xff else pic.secondary_mask) << 8 | pic.primary_mask;
        const injectable = self.vm.pending_irq & ~masked;
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

    /// Enters the guest with `vmlaunch` or `vmresume`, and returns at its next VM-exit
    /// with `regs` holding its registers. false if the VM entry itself failed.
    /// the VMCS must be current (`Pcpu.load`) and prepared (`prepareEntry`).
    pub fn enter(self: *Vcpu) bool {
        const ret = asm volatile ("call __vmEnter"
            : [ret] "={al}" (-> u8),
            : [vcpu] "{rdi}" (self),
            : .{
              .rax = true,
              .rcx = true,
              .rdx = true,
              .rsi = true,
              .rdi = true,
              .r8 = true,
              .r9 = true,
              .r10 = true,
              .r11 = true,
              .memory = true,
              .cc = true,
            });
        if (ret == 0) {
            std.log.err("{s} failed with error code: {d}\n", .{
                if (self.launched) "vmresume" else "vmlaunch",
                vmx.vmerr(),
            });
            return false;
        }
        self.launched = true;
        return true;
    }

    /// Handles the VM-exit that just happened, so the next entry resumes the guest
    /// where it should. Stops the vcpu if the guest can't continue.
    pub fn handleExit(self: *Vcpu) void {
        switch (self.exitAction()) {
            .exit => self.state = .stopped,
            .@"resume" => resumeToNextInstruction(),
            .resume_at_rip => {},
        }
    }

    /// Decides what to do about the VM-exit that just happened, see `ExitAction`.
    fn exitAction(self: *Vcpu) ExitAction {
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

        reinjectInterruptedEvent();
        return self.tryExitReason(exit_reason, exit_qual) catch |err| switch (err) {
            error.Aborted => {
                std.log.err("vcpu {d} aborted at rip 0x{x} after {s} (0x{x}); not resuming\n", .{
                    self.index,
                    vmread(.GUEST_RIP),
                    @tagName(exit_reason),
                    exit_qual.backing_int,
                });
                return .exit;
            },
        };
    }
};

/// The registers `__vmEnter` and `__vmExit` move between the cpu and `Vcpu.regs`,
/// all but `rdi`, which holds the `*Vcpu` and is moved last.
fn regMoves(comptime dir: enum { to_cpu, from_cpu }) []const u8 {
    comptime {
        var code: []const u8 = "";
        for (@typeInfo(Vcpu.Regs).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, "rdi")) continue;
            const offset = @offsetOf(Vcpu, "regs") + @offsetOf(Vcpu.Regs, field.name);
            code = code ++ switch (dir) {
                .to_cpu => std.fmt.comptimePrint("mov {d}(%rdi), %{s}\n", .{ offset, field.name }),
                .from_cpu => std.fmt.comptimePrint("mov %{s}, {d}(%rdi)\n", .{ field.name, offset }),
            };
        }
        return code;
    }
}

const regs_rdi_offset = @offsetOf(Vcpu, "regs") + @offsetOf(Vcpu.Regs, "rdi");

/// `rdi` points at the `Vcpu` to enter. Returns 1 in `al` at its next VM-exit
/// (through `__vmExit`) and 0 if the entry failed.
///
/// it pushes the host's callee-saved registers and then the `*Vcpu`, and points
/// `HOST_RSP` at that, so `__vmExit` finds the vcpu on top of the stack.
export fn __vmEnter() callconv(.naked) void {
    asm volatile (std.fmt.comptimePrint(
            \\ push %rbp
            \\ push %rbx
            \\ push %r12
            \\ push %r13
            \\ push %r14
            \\ push %r15
            \\ push %rdi
            \\
            \\ mov ${[host_rsp]d}, %rax
            \\ vmwrite %rsp, %rax
            \\
            \\ // the movs below leave the flags alone, `jne` still sees this
            \\ cmpb $0, {[launched]d}(%rdi)
            \\
        , .{
            .host_rsp = @intFromEnum(vmx.SelectorField.HOST_RSP),
            .launched = @offsetOf(Vcpu, "launched"),
        }) ++ regMoves(.to_cpu) ++ std.fmt.comptimePrint(
            \\ mov {[rdi]d}(%rdi), %rdi
            \\
            \\ jne 1f
            \\ vmlaunch
            \\ jmp 2f
            \\1:
            \\ vmresume
            \\2:
            \\ // the entry failed, the guest's registers are only in `Vcpu.regs`
            \\ add $8, %rsp
            \\ pop %r15
            \\ pop %r14
            \\ pop %r13
            \\ pop %r12
            \\ pop %rbx
            \\ pop %rbp
            \\ xor %eax, %eax
            \\ ret
        , .{ .rdi = regs_rdi_offset }));
}

/// `HOST_RIP`, a VM-exit lands here with the stack `__vmEnter` left: the `*Vcpu`
/// on top, the host's callee-saved registers under it. Stores the guest's registers
/// in `Vcpu.regs` and returns 1 from `__vmEnter`.
pub export fn __vmExit() callconv(.naked) void {
    asm volatile (
        \\ push %rdi
        \\ mov 8(%rsp), %rdi
        \\
    ++ regMoves(.from_cpu) ++ std.fmt.comptimePrint(
        \\ pop %rax
        \\ mov %rax, {[rdi]d}(%rdi)
        \\
        \\ add $8, %rsp
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %rbx
        \\ pop %rbp
        \\ mov $1, %eax
        \\ ret
    , .{ .rdi = regs_rdi_offset }));
}

const rflags_if: u64 = 1 << 9;
/// `VM_ENTRY_INTR_INFO_FIELD` holds an event to inject, cleared by every VM-exit
const entry_intr_valid: u64 = 1 << 31;

/// values of `GUEST_ACTIVITY_STATE`
const ActivityState = enum(u64) {
    active = 0,
    hlt = 1,
};

/// What `Vcpu.handleExit` does once a VM-exit is decided on.
pub const ExitAction = enum {
    /// advance RIP past the exiting instruction, then resume the guest
    @"resume",
    /// stop the vcpu, the scheduler never enters it again
    exit,
    /// resume the guest at GUEST_RIP as is, for handlers that set RIP themselves (e.g. an emulated IRET)
    resume_at_rip,
};

fn resumeToNextInstruction() void {
    const current_rip = vmread(.GUEST_RIP);
    const exit_instr_len = vmread(.VM_EXIT_INSTRUCTION_LEN);
    vmwrite(.GUEST_RIP, current_rip +% exit_instr_len);
}
