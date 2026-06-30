# NOTE: use gf instead!
file ./zig-out/bin/kernel.elf
target remote localhost:1234
hb kmain
c
layout asm
si
si
