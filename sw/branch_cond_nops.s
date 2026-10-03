# branch_cond_nops: branch_cond con dos nop despues de cada salto.
#
# Variante para M7 (sin flush): las dos instrucciones que entran detras de un
# salto se ejecutan siempre, asi que tienen que ser nop. Las que escriben x20
# a x24 quedan despues de los nop y no se alcanzan. Mismo estado que
# branch_cond.
# Estado esperado: branch_cond_nops.exp

        addi    x1, x0, 5               # 0x00
        addi    x2, x0, 5               # 0x04
        addi    x3, x0, 7               # 0x08
        addi    x4, x0, 3               # 0x0C
        beq     x1, x2, b1              # 0x10  tomado
        nop                             # 0x14
        nop                             # 0x18
        addi    x20, x0, 1              # 0x1C  no se ejecuta
        addi    x20, x0, 2              # 0x20  no se ejecuta
        addi    x20, x0, 3              # 0x24  no se ejecuta
b1:     bne     x1, x2, malo            # 0x28  no tomado
        nop                             # 0x2C
        nop                             # 0x30
        addi    x11, x0, 0x11           # 0x34
        beq     x1, x3, malo            # 0x38  no tomado
        nop                             # 0x3C
        nop                             # 0x40
        addi    x12, x0, 0x12           # 0x44
        bne     x1, x3, b2              # 0x48  tomado
        nop                             # 0x4C
        nop                             # 0x50
        addi    x21, x0, 1              # 0x54  no se ejecuta
        addi    x21, x0, 2              # 0x58  no se ejecuta
malo:   addi    x31, x0, -1             # 0x5C
        halt                            # 0x60
b2:     addi    x13, x13, 1             # 0x64
        addi    x14, x14, 2             # 0x68
        addi    x15, x15, 3             # 0x6C
        bne     x13, x4, b2             # 0x70  tomado 2 veces, no tomado 1
        nop                             # 0x74
        nop                             # 0x78
        addi    x16, x16, 1             # 0x7C
        addi    x17, x17, 1             # 0x80
        beq     x0, x0, b3              # 0x84  tomado
        nop                             # 0x88
        nop                             # 0x8C
        addi    x22, x0, 1              # 0x90  no se ejecuta
        addi    x22, x0, 2              # 0x94  no se ejecuta
b4:     addi    x18, x0, 0x18           # 0x98
        beq     x1, x2, fin             # 0x9C  tomado
        nop                             # 0xA0
        nop                             # 0xA4
        addi    x23, x0, 1              # 0xA8  no se ejecuta
        addi    x23, x0, 2              # 0xAC  no se ejecuta
b3:     addi    x19, x0, 0x19           # 0xB0
        beq     x1, x2, b4              # 0xB4  tomado hacia atras
        nop                             # 0xB8
        nop                             # 0xBC
        addi    x24, x0, 1              # 0xC0  no se ejecuta
        addi    x24, x0, 2              # 0xC4  no se ejecuta
fin:    halt                            # 0xC8
