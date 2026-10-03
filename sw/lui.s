# lui: carga de los 20 bits altos y armado de constantes de 32 bits.
#
# Prueba: lui con distintos valores (incluido el bit 31 en 1) y la composicion
# lui + addi, tambien con addi negativo: si el bit 11 de la constante es 1, el
# addi resta, asi que el lui lleva la parte alta + 1
# (0xDEADBEEF = lui 0xDEADC + addi -0x111).
#
# Sin riesgos: cada addi esta a distancia >= 3 de su lui (M7).
# Estado esperado: lui.exp

        lui     x1, 0x12345             # x1 = 0x12345000
        lui     x2, 0xFFFFF             # x2 = 0xFFFFF000
        lui     x3, 1                   # x3 = 0x00001000
        lui     x4, 0xDEADC             # x4 = 0xDEADC000
        addi    x1, x1, 0x678           # x1 = 0x12345678
        lui     x5, 0x80000             # x5 = 0x80000000
        addi    x4, x4, -0x111          # x4 = 0xDEADBEEF
        addi    x2, x2, 0x7FF           # x2 = 0xFFFFF7FF
        addi    x5, x5, -1              # x5 = 0x7FFFFFFF
        lui     x6, 1                   # x6 = 0x00001000
        lui     x7, 0xABCDE             # x7 = 0xABCDE000
        lui     x8, 0x7FFFF             # x8 = 0x7FFFF000
        addi    x6, x6, -2048           # x6 = 0x00000800
        halt
