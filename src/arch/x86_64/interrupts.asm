section .text

global isr_trap

extern handlers_map
extern irqHandler

%macro STUB_BEGINS 0
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
%endmacro

%macro STUB_ENDS 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    add rsp, 16
    iretq
%endmacro

%macro ISR_NOERRCODE 1
global isr_%1
isr_%1:
    cli
    push qword 0
    push %1
    jmp isr_trap
%endmacro

%macro ISR_ERRCODE 1
global isr_%1
isr_%1:
    cli
    push %1
    jmp isr_trap
%endmacro

%macro IRQ_GATE 1
global irq_%1
irq_%1:
  cli
  push qword 0  ; push err code of 0 to align with same cpuState struct
  push qword %1 ; push irq gate number as interrupt number
  jmp irq_trap
%endmacro

ISR_NOERRCODE 0
ISR_NOERRCODE 1
ISR_NOERRCODE 2
ISR_NOERRCODE 3
ISR_NOERRCODE 4
ISR_NOERRCODE 5
ISR_NOERRCODE 6
ISR_NOERRCODE 7
ISR_ERRCODE 8
ISR_NOERRCODE 9
ISR_ERRCODE 10
ISR_ERRCODE 11
ISR_ERRCODE 12
ISR_ERRCODE 13
ISR_ERRCODE 14
ISR_NOERRCODE 15
ISR_NOERRCODE 16
ISR_ERRCODE 17
ISR_NOERRCODE 18
ISR_NOERRCODE 19
ISR_NOERRCODE 20
ISR_NOERRCODE 21
ISR_NOERRCODE 22
ISR_NOERRCODE 23
ISR_NOERRCODE 24
ISR_NOERRCODE 25
ISR_NOERRCODE 26
ISR_NOERRCODE 27
ISR_NOERRCODE 28
ISR_NOERRCODE 29
ISR_NOERRCODE 30
ISR_NOERRCODE 31
IRQ_GATE 32
IRQ_GATE 33
IRQ_GATE 34
IRQ_GATE 35
IRQ_GATE 36
IRQ_GATE 37
IRQ_GATE 38
IRQ_GATE 39
IRQ_GATE 40
IRQ_GATE 41
IRQ_GATE 42
IRQ_GATE 43
IRQ_GATE 44
IRQ_GATE 45
IRQ_GATE 46
IRQ_GATE 47
; syscall
ISR_NOERRCODE 144

; interrupt_id field offset inside interrupts.cpuState
CPU_STATE_INTERRUPT_ID equ 120

isr_trap:
    STUB_BEGINS

    ; call handlers_map[interrupt_id]
    lea rdi, [rsp]
    mov rax, [rdi + CPU_STATE_INTERRUPT_ID]
    and rax, 0xff
    mov rax, [handlers_map + rax * 8]
    call rax

    STUB_ENDS

irq_trap:
    STUB_BEGINS

    mov rdi, rsp
    call irqHandler

    STUB_ENDS
