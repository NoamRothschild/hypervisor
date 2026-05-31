file ./zig-out/bin/kernel.elf
target remote localhost:1234
b _start
b realMode64
c
layout asm
si
