# salto_depende_nops: salto_depende con nop para correr sin forwarding ni flush.
#
# Variante para M7: nop antes de cada salto hasta que su operando quede a
# distancia 3, y dos nop despues de cada salto. Mismo estado que salto_depende
# salvo x5 y x6, que son direcciones y cambian porque el codigo se corre.
# El destino del jalr es una direccion fija: si se agrega o se quita una
# instruccion antes de "fin", hay que corregir el addi de 0x64.
# Estado esperado: salto_depende_nops.exp

        addi    x1, x0, 5               # 0x00
        addi    x2, x0, 6               # 0x04
        addi    x9, x0, 9               # 0x08
        addi    x3, x1, 1               # 0x0C  x3 = 6
        nop                             # 0x10
        nop                             # 0x14
        beq     x3, x2, paso1           # 0x18  tomado
        nop                             # 0x1C
        nop                             # 0x20
        addi    x20, x0, 1              # 0x24  no se ejecuta
        addi    x20, x0, 2              # 0x28  no se ejecuta
paso1:  addi    x4, x2, -1              # 0x2C  x4 = 5
        nop                             # 0x30
        nop                             # 0x34
        bne     x1, x4, malo            # 0x38  no tomado
        nop                             # 0x3C
        nop                             # 0x40
        addi    x8, x0, 8               # 0x44
        addi    x10, x0, 0x10           # 0x48
        nop                             # 0x4C
        bne     x8, x9, paso2           # 0x50  tomado
        nop                             # 0x54
        nop                             # 0x58
        addi    x21, x0, 1              # 0x5C  no se ejecuta
        addi    x21, x0, 2              # 0x60  no se ejecuta
paso2:  addi    x5, x0, 0x8C            # 0x64  x5 = direccion de fin
        nop                             # 0x68
        nop                             # 0x6C
        jalr    x6, 0(x5)               # 0x70  x6 = 0x74
        nop                             # 0x74
        nop                             # 0x78
        addi    x22, x0, 1              # 0x7C  no se ejecuta
        addi    x22, x0, 2              # 0x80  no se ejecuta
malo:   addi    x31, x0, -1             # 0x84
        halt                            # 0x88
fin:    halt                            # 0x8C
