section .bss.boot nobits alloc

ENTRY_COUNT equ 512
ENTRY_BYTE_SIZE equ 8

PML4T: resq ENTRY_COUNT
PDPT: resq ENTRY_COUNT
PDT: resq ENTRY_COUNT
PT1: resq ENTRY_COUNT
PT2: resq ENTRY_COUNT

section .data.boot

; Access bits
GDT_PRESENT        equ 1 << 7
GDT_NOT_SYS        equ 1 << 4
GDT_EXEC           equ 1 << 3
GDT_DC             equ 1 << 2
GDT_RW             equ 1 << 1
GDT_ACCESSED       equ 1 << 0

; Flags bits
GRAN_4K       equ 1 << 7
SZ_32         equ 1 << 6
LONG_MODE     equ 1 << 5

GDT:
    .Null: equ $ - GDT
        dq 0
    .Code: equ $ - GDT
        .Code.limit_lo: dw 0xffff
        .Code.base_lo: dw 0
        .Code.base_mid: db 0
        .Code.access: db GDT_PRESENT | GDT_NOT_SYS | GDT_EXEC | GDT_RW
        .Code.flags: db GRAN_4K | LONG_MODE | 0xF   ; Flags & Limit (high, bits 16-19)
        .Code.base_hi: db 0
    .Data: equ $ - GDT
        .Data.limit_lo: dw 0xffff
        .Data.base_lo: dw 0
        .Data.base_mid: db 0
        .Data.access: db GDT_PRESENT | GDT_NOT_SYS | GDT_RW
        .Data.Flags: db GRAN_4K | SZ_32 | 0xF       ; Flags & Limit (high, bits 16-19)
        .Data.base_hi: db 0
    .Pointer:
        dw $ - GDT - 1
        dq GDT


section .text.boot exec alloc

PTE_SIZE equ ENTRY_BYTE_SIZE

PT_ADDR_MASK equ 0xffffffffff000
PT_PRESENT equ 1
PT_READABLE equ 2
PAGE_SIZE equ 0x1000
PAGE_TABLE_SIZE equ ENTRY_BYTE_SIZE * ENTRY_COUNT

CR4_PAE_ENABLE equ 1 << 5
CR0_PM_ENABLE equ 1 << 0
CR0_PG_ENABLE equ 1 << 31

extern realMode64
global _start
_start:
  [BITS 32]
  ; TODO: check for existence of CPUID, if exists check for long mode support
  ; for now we assume they both exist

  mov edi, PML4T
  mov cr3, edi

  xor eax, eax
  mov ecx, PAGE_TABLE_SIZE
  rep stosd ; writes 4 * PAGE_TABLE_SIZE null bytes, clearing all our tables.
  mov ecx, PAGE_TABLE_SIZE
  rep stosb ; writes PAGE_TABLE_SIZE null bytes, clearing all our tables.

  mov edi, PML4T
  mov eax, PDPT
  and eax, PT_ADDR_MASK
  or eax, PT_PRESENT | PT_READABLE
  mov dword [edi], eax

  mov edi, PDPT
  mov eax, PDT
  and eax, PT_ADDR_MASK
  or eax, PT_PRESENT | PT_READABLE
  mov dword [edi], eax

  mov edi, PDT
  mov eax, PT1
  and eax, PT_ADDR_MASK
  or eax, PT_PRESENT | PT_READABLE
  mov dword [edi], eax

  mov edi, PDT + ENTRY_BYTE_SIZE
  mov eax, PT2
  and eax, PT_ADDR_MASK
  or eax, PT_PRESENT | PT_READABLE
  mov dword [edi], eax

  mov edi, PT1
  mov ebx, PT_PRESENT | PT_READABLE
  mov ecx, ENTRY_COUNT

.setEntry1:
  mov dword [edi], ebx
  add ebx, PAGE_SIZE
  add edi, PTE_SIZE
  loop .setEntry1

  mov edi, PT2
  ; ebx = last used
  mov ecx, ENTRY_COUNT

.setEntry2:
  mov dword [edi], ebx
  add ebx, PAGE_SIZE
  add edi, PTE_SIZE
  loop .setEntry2

.enablePae:
  mov eax, cr4
  or eax, CR4_PAE_ENABLE
  mov cr4, eax

.switchCompat:
  mov ecx, 0xC0000080 ; EFER_MSR
  rdmsr
  or eax, 1 << 8 ; EFER_LM_ENABLE
  wrmsr

.enablePaging:
  mov eax, cr0
  or eax, CR0_PG_ENABLE | CR0_PM_ENABLE
  mov cr0, eax

.loadGDT:
  lgdt [GDT.Pointer]
  jmp GDT.Code:realm64

[BITS 64]
realm64:
  cli

  mov ax, GDT.Data
  mov ds, ax
  mov fs, ax
  mov gs, ax
  mov es, ax
  mov ss, ax

  jmp realMode64
