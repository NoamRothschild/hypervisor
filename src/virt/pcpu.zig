const std = @import("std");
const hhdm = @import("../mem/hhdm.zig");
const mem_allocator = @import("../mem/allocator.zig");
const debug = @import("../debug.zig");
const msr = @import("msr.zig");
const vmx = @import("vmx.zig");
const ept = @import("ept.zig");
const lapic = @import("smp/lapic.zig");
const tsc = @import("../arch/x86_64/tsc.zig");
const pic_hw = @import("../arch/x86_64/pic.zig");
const Vcpu = @import("vcpu.zig").Vcpu;

/// Everything that belongs to a physical core the hypervisor runs on, rather than
/// to a vcpu: VMX operation is entered once per core, a core has one current VMCS,
/// and it time-shares the vcpus it was given (`add`) between them.
pub const Pcpu = struct {
    vmxon_region: ept.HostPhys,
    /// the vcpu whose VMCS is current on this core (`vmptrld`), null before the first `load`
    current: ?*Vcpu,
    /// the vcpus this core runs, `vcpus[0..vcpu_count]`
    vcpus: [max_vcpus]*Vcpu,
    vcpu_count: usize,
    /// round-robin position, where `pickNext` looks for a vcpu first
    next: usize,
    /// when the running vcpu has to make way for another runnable one
    slice_end_tsc: u64,
    /// the VMX-preemption timer counts down once every 2^shift TSC cycles (IA32_VMX_MISC[4:0])
    preemption_timer_shift: u5,

    pub const max_vcpus = 16;
    /// how long a vcpu runs before another runnable one gets its turn
    const slice_ms = 1;

    /// enters VMX operation on the calling core
    pub fn init(self: *Pcpu) !void {
        self.current = null;
        self.vcpu_count = 0;
        self.next = 0;
        self.slice_end_tsc = 0;
        self.preemption_timer_shift = @truncate(msr.rdmsr(.IA32_VMX_MISC));

        enableFxsave();
        vmx.enableOperation();
        std.log.info("vmx enabled\n", .{});

        try self.allocVmxonRegion();
        self.vmxon() catch |err| {
            std.log.err("VMXON failed: {s}\n", .{@errorName(err)});
            return err;
        };
        std.log.info("VMXON succeeded\n", .{});
    }

    /// makes this core run `vcpu`, from the next `run` on
    pub fn add(self: *Pcpu, vcpu: *Vcpu) error{TooManyVcpus}!void {
        if (self.vcpu_count == max_vcpus) return error.TooManyVcpus;
        self.vcpus[self.vcpu_count] = vcpu;
        self.vcpu_count += 1;
    }

    /// makes `vcpu`'s VMCS the current one, every vmread and vmwrite goes to it,
    /// and swaps the guest state the cpu holds outside the VMCS (`Vcpu.fpu`) to it.
    pub fn load(self: *Pcpu, vcpu: *Vcpu) !void {
        if (self.current == vcpu) return;
        // errors are logged inside
        if (!vcpu.vmptrld())
            return error.VmcsLoadFailed;
        if (self.current) |prev| prev.saveCpuState();
        vcpu.restoreCpuState();
        self.current = vcpu;
    }

    /// Runs the vcpus until none of them is runnable anymore.
    pub fn run(self: *Pcpu) void {
        // IRQs from before the guests existed aren't theirs to receive
        _ = pic_hw.takeReceived();

        while (self.pickNext()) |vcpu| {
            self.load(vcpu) catch {
                vcpu.state = .stopped;
                continue;
            };
            vcpu.prepareEntry();
            self.armPreemptionTimer();
            if (!vcpu.enter())
                vcpu.state = .stopped
            else
                vcpu.handleExit();
        }
    }

    /// The vcpu to enter next: one whose LAPIC timer is overdue, so its interrupt
    /// isn't late by a whole slice, then the current one until its slice ends, then
    /// the next runnable one round-robin. null when no vcpu is runnable.
    ///
    /// only a round-robin pick starts a new slice. an overdue vcpu runs in what is
    /// left of the current one: two vcpus whose timers keep expiring while the other
    /// runs would otherwise hand slices back and forth, and starve the rest.
    fn pickNext(self: *Pcpu) ?*Vcpu {
        const now = tsc.read();
        if (self.overdue(now)) |vcpu| return vcpu;
        if (self.current) |cur| {
            if (cur.state == .runnable and now < self.slice_end_tsc)
                return cur;
        }

        const vcpus = self.vcpus[0..self.vcpu_count];
        for (0..vcpus.len) |i| {
            const idx = (self.next + i) % vcpus.len;
            const vcpu = vcpus[idx];
            if (vcpu.state != .runnable) continue;

            self.next = (idx + 1) % vcpus.len;
            self.slice_end_tsc = now + tsc.hz * slice_ms / 1000;
            return vcpu;
        }
        return null;
    }

    /// A runnable vcpu, other than the current one, whose LAPIC timer expired by `now`.
    /// entering it fires the timer (`Vcpu.prepareEntry`) and moves the deadline on.
    fn overdue(self: *Pcpu, now: u64) ?*Vcpu {
        for (self.vcpus[0..self.vcpu_count]) |vcpu| {
            if (vcpu == self.current or vcpu.state != .runnable) continue;
            const deadline = lapic.timerDeadline(vcpu) orelse continue;
            if (deadline <= now) return vcpu;
        }
        return null;
    }

    /// The earliest LAPIC timer expiry among this core's vcpus that is still ahead
    /// of `now`, null if none is. an expired one of another vcpu is left out:
    /// counting it would arm the preemption timer to 0, which exits before the
    /// current vcpu runs a single instruction. `pickNext` switches to that vcpu at
    /// the next exit instead.
    fn nextDeadline(self: *Pcpu, now: u64) ?u64 {
        var earliest: ?u64 = null;
        for (self.vcpus[0..self.vcpu_count]) |vcpu| {
            if (vcpu.state != .runnable) continue;
            const deadline = lapic.timerDeadline(vcpu) orelse continue;
            if (vcpu != self.current and deadline <= now) continue;
            if (earliest == null or deadline < earliest.?) earliest = deadline;
        }
        return earliest;
    }

    /// whether a vcpu other than the current one waits to run
    fn othersRunnable(self: *Pcpu) bool {
        for (self.vcpus[0..self.vcpu_count]) |vcpu| {
            if (vcpu != self.current and vcpu.state == .runnable) return true;
        }
        return false;
    }

    /// Makes the current vcpu exit by the next LAPIC timer expiry of any vcpu (so
    /// it's delivered on time), or by the end of its slice when another vcpu waits.
    fn armPreemptionTimer(self: *Pcpu) void {
        const now = tsc.read();
        var until: ?u64 = self.nextDeadline(now);
        if (self.othersRunnable()) {
            if (until == null or self.slice_end_tsc < until.?) until = self.slice_end_tsc;
        }

        const ticks: u64 = if (until) |t|
            (t -| now) >> self.preemption_timer_shift
        else
            std.math.maxInt(u32);
        vmx.vmwrite(.VMX_PREEMPTION_TIMER_VALUE, @min(ticks, std.math.maxInt(u32)));
    }

    /// Lets the host run the fxsave/fxrstor that swap the guests' x87/SSE state
    /// (`Vcpu.saveCpuState`): CR0.EM and CR0.TS would fault them, and without
    /// CR4.OSFXSR they may skip the XMM registers. The hypervisor is built without
    /// SSE, so none of this changes how it runs. must happen before the VMCSs take
    /// their HOST_CR0 and HOST_CR4 (`vmcs.setup`).
    fn enableFxsave() void {
        const cr0_em: u64 = 1 << 2;
        const cr0_ts: u64 = 1 << 3;
        const cr4_osfxsr: u64 = 1 << 9;

        var cr0 = asm volatile ("mov %%cr0, %[cr0]"
            : [cr0] "=r" (-> u64),
        );
        cr0 &= ~(cr0_em | cr0_ts);
        asm volatile ("mov %[cr0], %%cr0"
            :
            : [cr0] "r" (cr0),
            : .{ .memory = true });

        var cr4 = asm volatile ("mov %%cr4, %[cr4]"
            : [cr4] "=r" (-> u64),
        );
        cr4 |= cr4_osfxsr;
        asm volatile ("mov %[cr4], %%cr4"
            :
            : [cr4] "r" (cr4),
            : .{ .memory = true });
    }

    /// Prepares the VMXON region. `vmxon()` executes it.
    fn allocVmxonRegion(self: *Pcpu) !void {
        const vmxon_page = try mem_allocator.kalloc.allocPage();
        const vmxon_region_phys = hhdm.physOf(vmxon_page);

        std.log.info("virtual buff addr for VMXON at 0x{x}\n", .{@intFromPtr(vmxon_page)});
        std.log.info("physical buff addr for VMXON at 0x{x}\n", .{vmxon_region_phys.raw()});

        @memset(vmxon_page, 0);
        @as(*volatile u32, @ptrCast(vmxon_page)).* = vmx.revisionIdentifier();
        self.vmxon_region = vmxon_region_phys;
    }

    /// executes VMXON with this core's region, entering VMX operation.
    fn vmxon(self: *Pcpu) !void {
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
};
