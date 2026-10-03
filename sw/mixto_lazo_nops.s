# mixto_lazo_nops: mixto_lazo con nop para correr sin forwarding, stall ni flush.
#
# Variante para M7: nop entre cada productor y su consumidor cercano
# (addi x2 -> primer sw, addi x3 -> bne, lw x5 -> add) y dos nop despues de
# cada salto. Mismo estado que mixto_lazo.
# Estado esperado: mixto_lazo_nops.exp

        addi    x1, x0, 0x100
        addi    x2, x0, 1
        addi    x3, x0, 5
        nop                             # x2 a distancia 3 del primer sw
llenar: sw      x2, 0(x1)
        addi    x2, x2, 3
        addi    x1, x1, 4
        addi    x3, x3, -1
        nop
        nop
        bne     x3, x0, llenar
        nop
        nop

        addi    x1, x0, 0x100
        addi    x3, x0, 5
        addi    x10, x0, 0
sumar:  lw      x5, 0(x1)
        nop
        nop
        add     x10, x10, x5
        addi    x1, x1, 4
        addi    x3, x3, -1
        nop
        nop
        bne     x3, x0, sumar
        nop
        nop
        sw      x10, 0x200(x0)          # dmem[0x200] = 0x23
        halt
