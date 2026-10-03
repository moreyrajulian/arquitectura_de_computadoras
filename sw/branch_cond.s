# branch_cond: saltos condicionales beq y bne.
#
# Prueba: beq y bne tomados y no tomados, hacia adelante y hacia atras (un
# lazo de 3 vueltas con bne y un beq hacia atras).
#
# Detras de cada salto tomado hay dos instrucciones que NO se tienen que
# ejecutar (escriben x20 a x24): son las que ya entraron por PC + 4 y el flush
# tiene que anular (pipeline.md 10.5). Si el flush falla, x16 y x17 tambien
# quedan distintos de 1. x31 = -1 indica que se tomo un salto que no debia.
#
# Sin riesgos de datos (distancias >= 3), solo de control: sin flush (M7) da
# otro resultado; para M7 esta branch_cond_nops.
# Estado esperado: branch_cond.exp

        addi    x1, x0, 5               # 0x00  x1 = 5
        addi    x2, x0, 5               # 0x04  x2 = 5
        addi    x3, x0, 7               # 0x08  x3 = 7
        addi    x4, x0, 3               # 0x0C  x4 = 3 (vueltas del lazo)
# beq tomado hacia adelante
        beq     x1, x2, b1              # 0x10  tomado
        addi    x20, x0, 1              # 0x14  no se ejecuta
        addi    x20, x0, 2              # 0x18  no se ejecuta
        addi    x20, x0, 3              # 0x1C  no se busca
# bne y beq no tomados
b1:     bne     x1, x2, malo            # 0x20  no tomado
        addi    x11, x0, 0x11           # 0x24  x11 = 0x11
        beq     x1, x3, malo            # 0x28  no tomado
        addi    x12, x0, 0x12           # 0x2C  x12 = 0x12
# bne tomado hacia adelante
        bne     x1, x3, b2              # 0x30  tomado
        addi    x21, x0, 1              # 0x34  no se ejecuta
        addi    x21, x0, 2              # 0x38  no se ejecuta
malo:   addi    x31, x0, -1             # 0x3C
        halt                            # 0x40
# bne tomado hacia atras: lazo de 3 vueltas
b2:     addi    x13, x13, 1             # 0x44  x13 = 1, 2, 3
        addi    x14, x14, 2             # 0x48  x14 = 2, 4, 6
        addi    x15, x15, 3             # 0x4C  x15 = 3, 6, 9
        bne     x13, x4, b2             # 0x50  tomado 2 veces, no tomado 1
        addi    x16, x16, 1             # 0x54  una sola vez: x16 = 1
        addi    x17, x17, 1             # 0x58  una sola vez: x17 = 1
# beq tomado hacia atras
        beq     x0, x0, b3              # 0x5C  tomado
        addi    x22, x0, 1              # 0x60  no se ejecuta
        addi    x22, x0, 2              # 0x64  no se ejecuta
b4:     addi    x18, x0, 0x18           # 0x68  x18 = 0x18 (se llega desde atras)
        beq     x1, x2, fin             # 0x6C  tomado
        addi    x23, x0, 1              # 0x70  no se ejecuta
        addi    x23, x0, 2              # 0x74  no se ejecuta
b3:     addi    x19, x0, 0x19           # 0x78  x19 = 0x19
        beq     x1, x2, b4              # 0x7C  tomado hacia atras
        addi    x24, x0, 1              # 0x80  no se ejecuta
        addi    x24, x0, 2              # 0x84  no se ejecuta
fin:    halt                            # 0x88
