//! The time stamp counter, and its frequency measured once against the PIT at boot.
//! Under QEMU, CPUID leaves 0x15 and 0x16 are zero, so there is no way to ask for it.
const debug = @import("../../debug.zig");
const outb = debug.outb;
const inb = debug.inb;

/// TSC ticks per second, 0 until `calibrate` ran
pub var hz: u64 = 0;

pub fn read() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

const pit_hz = 1_193_182;
/// the longest a 16-bit PIT count lasts is ~55ms
const window_ms = 50;
const port_61 = 0x61;
/// port 0x61 bit 0: channel 2's gate
const gate2 = 1 << 0;
/// port 0x61 bit 1: connect channel 2 to the speaker
const speaker = 1 << 1;
/// port 0x61 bit 5: channel 2's output
const out2 = 1 << 5;

/// Counts TSC ticks while PIT channel 2 counts down `window_ms`, the way Linux
/// calibrates on bare metal. Channel 2's gate and output sit in port 0x61, so it
/// can be polled without touching channel 0, which drives IRQ0.
pub fn calibrate() void {
    const count: u16 = pit_hz * window_ms / 1000;
    const old_61 = inb(port_61);
    outb(port_61, (old_61 & ~@as(u8, speaker)) | gate2);

    // channel 2, lobyte then hibyte, mode 0: the output goes high once the count reaches 0
    outb(0x43, 0b10_11_000_0);
    outb(0x42, @truncate(count));
    outb(0x42, @truncate(count >> 8));

    const start = read();
    while (inb(port_61) & out2 == 0) {}
    const end = read();

    outb(port_61, old_61);
    hz = (end - start) * 1000 / window_ms;
}
