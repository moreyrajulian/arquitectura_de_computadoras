# fwd_memwb_nops: fwd_memwb con un nop antes de cada consumidor.
#
# Variante para M7: el nop lleva cada dependencia de distancia 2 a distancia 3,
# que resuelve el banco de registros. Mismo estado que fwd_memwb.
# Estado esperado: fwd_memwb_nops.exp

        addi    x1, x0, 7               # x1 = 0x00000007
        addi    x10, x0, 1
        nop
        addi    x2, x1, 3               # x2 = 0x0000000A
        addi    x11, x0, 2
        nop
        sub     x3, x0, x2              # x3 = 0xFFFFFFF6
        addi    x12, x0, 3
        nop
        add     x4, x3, x3              # x4 = 0xFFFFFFEC
        addi    x13, x0, 4
        nop
        sw      x4, 8(x0)               # dmem[0x008] = 0xFFFFFFEC
        halt
