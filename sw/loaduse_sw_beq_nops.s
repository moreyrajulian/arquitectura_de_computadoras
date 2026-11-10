# loaduse_sw_beq_nops: loaduse_sw_beq con nop despues de cada lw y de cada
# salto.
#
# Variante para M7: dos nop despues de cada lw (el dato se usa a distancia 3)
# y dos nop despues de cada salto (sin flush se ejecutan en lugar de las
# instrucciones que el flush anularia). Mismo estado que loaduse_sw_beq, salvo
# la direccion de fin, que el codigo corrido cambia (x10, x11, x12 y dmem[0x008]).
# El destino del jalr es una direccion fija: si se agrega o se quita una
# instruccion antes de "fin", hay que corregir el addi de 0x78.
# Estado esperado: loaduse_sw_beq_nops.exp

        addi    x4, x0, 0x20
        addi    x1, x0, 0x33
        addi    x2, x0, 0x33
        sw      x4, 0x10(x0)            # dmem[0x010] = 0x00000020
        sw      x1, 0(x0)               # dmem[0x000] = 0x00000033
        lw      x5, 0(x0)
        nop
        nop
        sw      x5, 4(x0)               # dmem[0x004] = 0x00000033
        lw      x8, 0x10(x0)
        nop
        nop
        sw      x1, 0(x8)               # dmem[0x020] = 0x00000033
        lw      x6, 4(x0)
        nop
        nop
        beq     x6, x2, igual           # tomado
        nop
        nop
        addi    x20, x0, 1              # no se ejecuta
        addi    x20, x0, 2              # no se ejecuta
malo:   addi    x31, x0, -1
        halt
igual:  lw      x7, 0(x0)
        nop
        nop
        bne     x7, x1, malo            # no tomado
        nop
        nop
        addi    x9, x0, 0x99            # x9 = 0x00000099
        addi    x10, x0, 0xAC           # 0x78  x10 = direccion de fin
        nop
        nop
        sw      x10, 8(x0)              # dmem[0x008] = 0x000000AC
        lw      x11, 8(x0)
        nop
        nop
        jalr    x12, 0(x11)             # 0x94  salta a fin; x12 = 0x98
        nop
        nop
        addi    x21, x0, 1              # no se ejecuta
        addi    x21, x0, 2              # no se ejecuta
        addi    x31, x0, -1             # no se ejecuta
fin:    halt                            # 0xAC
