const std = @import("std");
const log = std.log;
const debug = @import("../../debug.zig");
const outb = debug.outb;
const divident = 1193180;
var tick: usize = 0;

// called when IRQ0 is called in the idt. see pic.zig
pub fn callback() void {
    tick +%= 1;
    // log.debug("T{d} ", .{tick});
}

// https://web.archive.org/web/20220723171914/http://www.jamesmolloy.co.uk/tutorial_html/5.-IRQs%20and%20the%20PIT.html
pub fn init(frequency: u32) void {
    const divisor: u16 = @truncate(divident / frequency);
    // sending command byte
    outb(0x43, 0x36);

    // sending frequency divisor
    const l: u8 = @truncate(divisor & 0xff);
    const h: u8 = @truncate((divisor >> 8) & 0xff);
    outb(0x40, l);
    outb(0x40, h);
}
