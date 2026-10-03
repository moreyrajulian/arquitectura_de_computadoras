# loaduse_rs1_rs2_nops: loaduse_rs1_rs2 con dos nop despues de cada lw.
#
# Variante para M7: el dato cargado se usa a distancia 3, cuando el lw ya esta
# en WB, asi que no hace falta stall ni forwarding. Mismo estado que
# loaduse_rs1_rs2, sin stalls.
# Estado esperado: loaduse_rs1_rs2_nops.exp

        addi    x1, x0, 42
        addi    x2, x0, -5
        addi    x3, x0, 3
        sw      x1, 8(x0)
        sw      x2, 12(x0)
        lw      x5, 8(x0)
        nop
        nop
        add     x6, x5, x0              # x6 = 0x0000002A
        lw      x7, 12(x0)
        nop
        nop
        sub     x8, x0, x7              # x8 = 0x00000005
        lw      x9, 8(x0)
        nop
        nop
        add     x10, x9, x9             # x10 = 0x00000054
        halt
