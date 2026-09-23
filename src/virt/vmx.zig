const std = @import("std");
const hhdm = @import("../mem/hhdm.zig");
const mem_allocator = @import("../mem/allocator.zig");
const ept = @import("ept.zig");
const msr = @import("msr.zig");
const debug = @import("../debug.zig");
const vmcs = @import("vmcs.zig");
const GuestAllocator = @import("../mem/guest_allocator.zig");
const Vcpu = @import("vcpu.zig").Vcpu;
const rdmsr = msr.rdmsr;
const wrmsr = msr.wrmsr;

pub inline fn supportsVirtualization() bool {
    if (!std.mem.eql(u8, &debug.getVendor(), "GenuineIntel"))
        return false;

    if (debug.getFeatures().vmx != 1)
        return false;

    var fc_msr: msr.IA32_FEATURE_CONTROL = @bitCast(rdmsr(.IA32_FEATURE_CONTROL));
    if (fc_msr.lock == 0) {
        fc_msr.lock = 1;
        fc_msr.enable_vmxon = 1;
        wrmsr(.IA32_FEATURE_CONTROL, @bitCast(fc_msr));
    } else if (fc_msr.enable_vmxon == 0) {
        std.log.err("VMX locked off in BIOS", .{});
        return false;
    }

    return true;
}

/// Sets CR0/CR4 to values required for VMX operation (including VMXE).
pub fn enableOperation() void {
    var cr0: u64 = undefined;
    var cr4: u64 = undefined;

    asm volatile ("mov %%cr0, %[cr0]"
        : [cr0] "=r" (cr0),
    );
    asm volatile ("mov %%cr4, %[cr4]"
        : [cr4] "=r" (cr4),
    );

    adjustCr0(&cr0);
    adjustCr4(&cr4);

    asm volatile ("mov %[cr0], %%cr0"
        :
        : [cr0] "r" (cr0),
        : .{ .memory = true });
    asm volatile ("mov %[cr4], %%cr4"
        :
        : [cr4] "r" (cr4),
        : .{ .memory = true });
}

pub const VMState = struct {
    /// guest-physical addr of the guest's own PML4
    guest_cr3: ept.GuestPhys,
    /// total guest RAM, identity-mapped from guest-physical 0
    guest_ram_block_count: u64,
    /// msr bitmap virt addr, shared by the VMCS of every vcpu
    msr_bitmap: *[4096]u8,
    /// msr bitmap phys addr
    msr_bitmap_phys: ept.HostPhys,
    /// io bitmaps, shared by the VMCS of every vcpu
    io_bitmap: struct {
        /// covers ports 0x0000-0x7fff
        first: *[4096]u8,
        /// covers ports 0x8000-0xffff
        second: *[4096]u8,

        /// makes the specified port get passed through to hardware
        /// instead of causing a VMEXIT
        pub fn passPort(self: *@This(), port: u16) void {
            const bitmap = if (port < 0x8000) self.first else self.second;
            const local_port = port % 0x8000;
            bitmap[local_port / 8] &= ~(@as(u8, 1) << @truncate(local_port % 8));
        }
    },
    guest_pml4: *align(4096) [512]ept.EPT_PML4E,
    /// `.len` is always greater than 0
    guest_mem_pages: []*align(0x1000) [1 << 30]u8,
    /// per-core state, one entry per logical core of the guest
    cpus: []Vcpu,

    pub const VMConfig = struct {
        os: enum { linux, windows } = .linux,
        vcpu_count: usize = 1,
        /// each block size is 1GB
        ram_block_count: usize = 2,
    };

    /// initializes the given VMState, as long as
    /// - initializing a basic EPT
    /// - creating each vcpu: calling vmxon, setting up its vmcs, and loading
    ///   the vmcs into the cpu (vmptrld)
    ///
    /// vmx operation must be enabled (`enableOperation`) on the calling core.
    pub fn prepare(self: *VMState, guest_allocator: *GuestAllocator, config: VMConfig) !void {
        if (config.vcpu_count != 1)
            @panic("vmx.VMState.prepare: vcpu count is more than 1 (unimplemented)");

        self.guest_ram_block_count = config.ram_block_count;

        const eptp = try ept.init(self, guest_allocator, config.ram_block_count);

        const msr_bitmap_page = try mem_allocator.kalloc.allocPage();
        self.msr_bitmap = msr_bitmap_page;
        self.msr_bitmap_phys = hhdm.physOf(msr_bitmap_page);
        @memset(msr_bitmap_page.*[0..], 0xff);

        // trap every port, then pass through the ones `io.zig` forwards to real
        // hardware in both directions (a bitmap bit can't distinguish in/out)
        self.io_bitmap = .{
            .first = try mem_allocator.kalloc.allocPage(),
            .second = try mem_allocator.kalloc.allocPage(),
        };
        @memset(self.io_bitmap.first.*[0..], 0xff);
        @memset(self.io_bitmap.second.*[0..], 0xff);
        // COM1 data register
        self.io_bitmap.passPort(debug.COM1);
        // PIT ports;  FIXME: this should be virtualized!
        for (0x0040..0x0047 + 1) |port|
            self.io_bitmap.passPort(@truncate(port));

        self.cpus = try mem_allocator.kalloc.alloc(Vcpu, config.vcpu_count);

        // TODO: run this for each cpu, on that cpu
        for (self.cpus, 0..) |*vcpu, i| {
            try vcpu.init(self, i);

            vcpu.vmxon() catch |err| {
                std.log.err("VMXON failed: {s}\n", .{@errorName(err)});
                return err;
            };
            std.log.info("VMXON succeeded\n", .{});

            // errors are logged inside the functions
            if (!vcpu.vmclear())
                return error.clear_vmcs_failed;
            if (!vcpu.vmptrld())
                return error.vmcs_load_failed;
            std.log.info("VMPTRLD succeeded\n", .{});

            try vmcs.setup(vcpu, &mem_allocator.kalloc, eptp);
        }
    }
};

pub fn vmxoff() void {
    std.log.info("terminating vmx...\n", .{});
    asm volatile ("vmxoff");
}

/// reads the instruction error field to get the error code
pub fn vmerr() u64 {
    return vmread(.VM_INSTRUCTION_ERROR);
}

pub fn vmread(field: SelectorField) u64 {
    var ret: u64 = 0;
    asm volatile ("vmread %[field], %[ret]"
        : [ret] "=rm" (ret),
        : [field] "r" (@intFromEnum(field)),
    );
    return ret;
}

/// calls vmwrite for the given selector with the given value
pub inline fn vmwrite(selector: SelectorField, value: u64) void {
    asm volatile ("vmwrite %rbx, %rax"
        :
        : [value] "{rbx}" (value),
          [selector] "{rax}" (@intFromEnum(selector)),
        : .{ .rbx = true, .rax = true });
}

pub fn adjustCr0(cr0: *u64) void {
    const cr0_fixed0 = rdmsr(.IA32_VMX_CR0_FIXED0);
    const cr0_fixed1 = rdmsr(.IA32_VMX_CR0_FIXED1);

    cr0.* |= cr0_fixed0;
    cr0.* &= cr0_fixed1;
}

pub fn adjustCr4(cr4: *u64) void {
    const cr4_fixed4 = rdmsr(.IA32_VMX_CR4_FIXED0);
    const cr4_fixed1 = rdmsr(.IA32_VMX_CR4_FIXED1);

    cr4.* |= cr4_fixed4;
    cr4.* &= cr4_fixed1;
}

pub const ExitQualification = packed union(u64) {
    backing_int: u64,
    cr: Cr,
    io: Io,

    pub const Io = packed struct(u64) {
        /// Size of access.
        size: Size,
        /// Direction of the attempted access.
        direction: Direction,
        /// String instruction.
        string: bool,
        /// Rep prefix.
        rep: bool,
        /// Operand encoding.
        operand_encoding: OperandEncoding,
        /// Not used.
        rsvd2: u9,
        /// Port number.
        port: u16,
        /// Not used.
        rsvd3: u32,

        const Size = enum(u3) {
            /// Byte.
            byte = 0,
            /// Word.
            word = 1,
            /// Dword.
            dword = 3,
        };

        const Direction = enum(u1) {
            out = 0,
            in = 1,
        };

        const OperandEncoding = enum(u1) {
            /// I/O instruction uses DX register as port number.
            dx = 0,
            /// I/O instruction uses immediate value as port number.
            imm = 1,
        };
    };

    pub const Cr = packed struct(u64) {
        index: u4,
        access_type: AccessType,
        lmsw_type: LmswOperandType,
        rsvd1: u1,
        reg: Register,
        rsvd2: u4,
        lmsw_source: u16,
        rsvd3: u32,

        const AccessType = enum(u2) {
            mov_to = 0,
            mov_from = 1,
            clts = 2,
            lmsw = 3,
        };
        const LmswOperandType = enum(u1) {
            reg = 0,
            mem = 1,
        };
        const Register = enum(u4) {
            rax = 0,
            rcx = 1,
            rdx = 2,
            rbx = 3,
            rsp = 4,
            rbp = 5,
            rsi = 6,
            rdi = 7,
            r8 = 8,
            r9 = 9,
            r10 = 10,
            r11 = 11,
            r12 = 12,
            r13 = 13,
            r14 = 14,
            r15 = 15,
        };

        /// writes `value` into the register the exiting `mov to cr` read from
        pub fn setVal(self: @This(), vcpu: *Vcpu, value: u64) void {
            switch (self.reg) {
                .rsp => vmwrite(.GUEST_RSP, value),
                inline else => |reg| @field(vcpu.regs.*, @tagName(reg)) = value,
            }
        }

        /// reads the reg indicated by the `Register` field
        pub fn getVal(self: @This(), vcpu: *Vcpu) u64 {
            return switch (self.reg) {
                .rsp => vmread(.GUEST_RSP),
                inline else => |v| @field(vcpu.regs.*, @tagName(v)),
            };
        }
    };
};

pub const ExitReason = enum(u64) {
    exception_nmi = 0,
    external_interrupt = 1,
    triple_fault = 2,
    init = 3,
    sipi = 4,
    io_smi = 5,
    other_smi = 6,
    pending_virt_intr = 7,
    pending_virt_nmi = 8,
    task_switch = 9,
    cpuid = 10,
    getsec = 11,
    hlt = 12,
    invd = 13,
    invlpg = 14,
    rdpmc = 15,
    rdtsc = 16,
    rsm = 17,
    vmcall = 18,
    vmclear = 19,
    vmlaunch = 20,
    vmptrld = 21,
    vmptrst = 22,
    vmread = 23,
    vmresume = 24,
    vmwrite = 25,
    vmxoff = 26,
    vmxon = 27,
    cr_access = 28,
    dr_access = 29,
    io_instruction = 30,
    msr_read = 31,
    msr_write = 32,
    invalid_guest_state = 33,
    msr_loading = 34,
    mwait_instruction = 36,
    monitor_trap_flag = 37,
    monitor_instruction = 39,
    pause_instruction = 40,
    mce_during_vmentry = 41,
    tpr_below_threshold = 43,
    apic_access = 44,
    access_gdtr_or_idtr = 46,
    access_ldtr_or_tr = 47,
    ept_violation = 48,
    ept_misconfig = 49,
    invept = 50,
    rdtscp = 51,
    vmx_preemption_timer_expired = 52,
    invvpid = 53,
    wbinvd = 54,
    xsetbv = 55,
    apic_write = 56,
    rdrand = 57,
    invpcid = 58,
    rdseed = 61,
    pml_full = 62,
    xsaves = 63,
    xrstors = 64,
    pcommit = 65,
};

pub const SelectorField = enum(u64) {
    GUEST_ES_SELECTOR = 0x00000800,
    GUEST_CS_SELECTOR = 0x00000802,
    GUEST_SS_SELECTOR = 0x00000804,
    GUEST_DS_SELECTOR = 0x00000806,
    GUEST_FS_SELECTOR = 0x00000808,
    GUEST_GS_SELECTOR = 0x0000080a,
    GUEST_LDTR_SELECTOR = 0x0000080c,
    GUEST_TR_SELECTOR = 0x0000080e,
    HOST_ES_SELECTOR = 0x00000c00,
    HOST_CS_SELECTOR = 0x00000c02,
    HOST_SS_SELECTOR = 0x00000c04,
    HOST_DS_SELECTOR = 0x00000c06,
    HOST_FS_SELECTOR = 0x00000c08,
    HOST_GS_SELECTOR = 0x00000c0a,
    HOST_TR_SELECTOR = 0x00000c0c,
    IO_BITMAP_A = 0x00002000,
    IO_BITMAP_A_HIGH = 0x00002001,
    IO_BITMAP_B = 0x00002002,
    IO_BITMAP_B_HIGH = 0x00002003,
    MSR_BITMAP = 0x00002004,
    MSR_BITMAP_HIGH = 0x00002005,
    VM_EXIT_MSR_STORE_ADDR = 0x00002006,
    VM_EXIT_MSR_STORE_ADDR_HIGH = 0x00002007,
    VM_EXIT_MSR_LOAD_ADDR = 0x00002008,
    VM_EXIT_MSR_LOAD_ADDR_HIGH = 0x00002009,
    VM_ENTRY_MSR_LOAD_ADDR = 0x0000200a,
    VM_ENTRY_MSR_LOAD_ADDR_HIGH = 0x0000200b,
    TSC_OFFSET = 0x00002010,
    TSC_OFFSET_HIGH = 0x00002011,
    VIRTUAL_APIC_PAGE_ADDR = 0x00002012,
    VIRTUAL_APIC_PAGE_ADDR_HIGH = 0x00002013,
    VMFUNC_CONTROLS = 0x00002018,
    VMFUNC_CONTROLS_HIGH = 0x00002019,
    EPT_POINTER = 0x0000201A,
    EPT_POINTER_HIGH = 0x0000201B,
    EPTP_LIST = 0x00002024,
    EPTP_LIST_HIGH = 0x00002025,
    GUEST_PHYSICAL_ADDRESS = 0x2400,
    GUEST_PHYSICAL_ADDRESS_HIGH = 0x2401,
    VMCS_LINK_POINTER = 0x00002800,
    VMCS_LINK_POINTER_HIGH = 0x00002801,
    GUEST_IA32_DEBUGCTL = 0x00002802,
    GUEST_IA32_DEBUGCTL_HIGH = 0x00002803,
    GUEST_IA32_EFER = 0x00002806,
    GUEST_IA32_EFER_HIGH = 0x00002807,
    HOST_IA32_EFER = 0x00002C02,
    PIN_BASED_VM_EXEC_CONTROL = 0x00004000,
    CPU_BASED_VM_EXEC_CONTROL = 0x00004002,
    EXCEPTION_BITMAP = 0x00004004,
    PAGE_FAULT_ERROR_CODE_MASK = 0x00004006,
    PAGE_FAULT_ERROR_CODE_MATCH = 0x00004008,
    CR3_TARGET_COUNT = 0x0000400a,
    VM_EXIT_CONTROLS = 0x0000400c,
    VM_EXIT_MSR_STORE_COUNT = 0x0000400e,
    VM_EXIT_MSR_LOAD_COUNT = 0x00004010,
    VM_ENTRY_CONTROLS = 0x00004012,
    VM_ENTRY_MSR_LOAD_COUNT = 0x00004014,
    VM_ENTRY_INTR_INFO_FIELD = 0x00004016,
    VM_ENTRY_EXCEPTION_ERROR_CODE = 0x00004018,
    VM_ENTRY_INSTRUCTION_LEN = 0x0000401a,
    TPR_THRESHOLD = 0x0000401c,
    SECONDARY_VM_EXEC_CONTROL = 0x0000401e,
    VM_INSTRUCTION_ERROR = 0x00004400,
    VM_EXIT_REASON = 0x00004402,
    VM_EXIT_INTR_INFO = 0x00004404,
    VM_EXIT_INTR_ERROR_CODE = 0x00004406,
    IDT_VECTORING_INFO_FIELD = 0x00004408,
    IDT_VECTORING_ERROR_CODE = 0x0000440a,
    VM_EXIT_INSTRUCTION_LEN = 0x0000440c,
    VMX_INSTRUCTION_INFO = 0x0000440e,
    GUEST_ES_LIMIT = 0x00004800,
    GUEST_CS_LIMIT = 0x00004802,
    GUEST_SS_LIMIT = 0x00004804,
    GUEST_DS_LIMIT = 0x00004806,
    GUEST_FS_LIMIT = 0x00004808,
    GUEST_GS_LIMIT = 0x0000480a,
    GUEST_LDTR_LIMIT = 0x0000480c,
    GUEST_TR_LIMIT = 0x0000480e,
    GUEST_GDTR_LIMIT = 0x00004810,
    GUEST_IDTR_LIMIT = 0x00004812,
    GUEST_ES_AR_BYTES = 0x00004814,
    GUEST_CS_AR_BYTES = 0x00004816,
    GUEST_SS_AR_BYTES = 0x00004818,
    GUEST_DS_AR_BYTES = 0x0000481a,
    GUEST_FS_AR_BYTES = 0x0000481c,
    GUEST_GS_AR_BYTES = 0x0000481e,
    GUEST_LDTR_AR_BYTES = 0x00004820,
    GUEST_TR_AR_BYTES = 0x00004822,
    GUEST_INTERRUPTIBILITY_INFO = 0x00004824,
    GUEST_ACTIVITY_STATE = 0x00004826,
    GUEST_SM_BASE = 0x00004828,
    GUEST_SYSENTER_CS = 0x0000482A,
    HOST_IA32_SYSENTER_CS = 0x00004c00,
    CR0_GUEST_HOST_MASK = 0x00006000,
    CR4_GUEST_HOST_MASK = 0x00006002,
    CR0_READ_SHADOW = 0x00006004,
    CR4_READ_SHADOW = 0x00006006,
    CR3_TARGET_VALUE0 = 0x00006008,
    CR3_TARGET_VALUE1 = 0x0000600a,
    CR3_TARGET_VALUE2 = 0x0000600c,
    CR3_TARGET_VALUE3 = 0x0000600e,
    EXIT_QUALIFICATION = 0x00006400,
    GUEST_LINEAR_ADDRESS = 0x0000640a,
    GUEST_CR0 = 0x00006800,
    GUEST_CR3 = 0x00006802,
    GUEST_CR4 = 0x00006804,
    GUEST_ES_BASE = 0x00006806,
    GUEST_CS_BASE = 0x00006808,
    GUEST_SS_BASE = 0x0000680a,
    GUEST_DS_BASE = 0x0000680c,
    GUEST_FS_BASE = 0x0000680e,
    GUEST_GS_BASE = 0x00006810,
    GUEST_LDTR_BASE = 0x00006812,
    GUEST_TR_BASE = 0x00006814,
    GUEST_GDTR_BASE = 0x00006816,
    GUEST_IDTR_BASE = 0x00006818,
    GUEST_DR7 = 0x0000681a,
    GUEST_RSP = 0x0000681c,
    GUEST_RIP = 0x0000681e,
    GUEST_RFLAGS = 0x00006820,
    GUEST_PENDING_DBG_EXCEPTIONS = 0x00006822,
    GUEST_SYSENTER_ESP = 0x00006824,
    GUEST_SYSENTER_EIP = 0x00006826,
    HOST_CR0 = 0x00006c00,
    HOST_CR3 = 0x00006c02,
    HOST_CR4 = 0x00006c04,
    HOST_FS_BASE = 0x00006c06,
    HOST_GS_BASE = 0x00006c08,
    HOST_TR_BASE = 0x00006c0a,
    HOST_GDTR_BASE = 0x00006c0c,
    HOST_IDTR_BASE = 0x00006c0e,
    HOST_IA32_SYSENTER_ESP = 0x00006c10,
    HOST_IA32_SYSENTER_EIP = 0x00006c12,
    HOST_RSP = 0x00006c14,
    HOST_RIP = 0x00006c16,
};
