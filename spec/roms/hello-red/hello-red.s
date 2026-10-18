@ Fills the screen red in BG mode 3. Loaded at 0x08000000.
@ Check: clang -target armv4t-none-eabi -c hello-red.s && xcrun llvm-objdump -d hello-red.o

    .arm
    .text
_start:
    mov  r0, #0x04000000    @ 08000000: E3A00301  r0 = REG_DISPCNT
    mov  r1, #0x400         @ 08000004: E3A01B01
    add  r1, r1, #3         @ 08000008: E2811003  r1 = 0x403 (mode 3, BG2 on)
    str  r1, [r0]           @ 0800000C: E5801000  REG_DISPCNT = r1
    mov  r0, #0x06000000    @ 08000010: E3A00406  r0 = VRAM
    mov  r1, #0x1F          @ 08000014: E3A0101F  r1 = red (BGR555)
    mov  r2, #0x9600        @ 08000018: E3A02C96  r2 = 240 * 160 pixels
loop:
    strh r1, [r0], #2       @ 0800001C: E0C010B2  *r0 = r1; r0 += 2
    subs r2, r2, #1         @ 08000020: E2522001  r2 -= 1, set flags
    bne  loop               @ 08000024: 1AFFFFFC  until r2 == 0
end:
    b    end                @ 08000028: EAFFFFFE  loop forever
