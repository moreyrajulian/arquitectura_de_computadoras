# shifts: desplazamientos con inmediato y con registro.
#
# Prueba: slli srli srai con shamt 0, 1 y 31; sll srl sra con rs2 >= 32 (solo
# cuentan los 5 bits bajos: 33 desplaza 1, -1 desplaza 31 y 64 desplaza 0).
#
# Sin riesgos: toda dependencia esta a distancia >= 3 (M7).
# Estado esperado: shifts.exp

        lui     x1, 0x87654             # x1 = 0x87654000
        addi    x2, x0, 33              # x2 = 0x00000021 -> desplaza 1
        addi    x3, x0, -1              # x3 = 0xFFFFFFFF -> desplaza 31
        addi    x1, x1, 0x321           # x1 = 0x87654321
        addi    x4, x0, 64              # x4 = 0x00000040 -> desplaza 0
        sll     x16, x3, x2             # 0xFFFFFFFF << 1     = 0xFFFFFFFE

        slli    x10, x1, 0              #                     = 0x87654321
        slli    x11, x1, 1              #                     = 0x0ECA8642
        slli    x12, x1, 31             #                     = 0x80000000
        srli    x13, x1, 0              #                     = 0x87654321
        srli    x14, x1, 1              #                     = 0x43B2A190
        srli    x15, x1, 31             #                     = 0x00000001
        srai    x17, x1, 0              #                     = 0x87654321
        srai    x18, x1, 1              #                     = 0xC3B2A190
        srai    x19, x1, 31             #                     = 0xFFFFFFFF
        srl     x20, x1, x2             # >> (33 & 31 = 1)    = 0x43B2A190
        sra     x21, x1, x3             # >>a (-1 & 31 = 31)  = 0xFFFFFFFF
        sll     x22, x1, x4             # << (64 & 31 = 0)    = 0x87654321
        srl     x23, x1, x3             # >> 31               = 0x00000001
        halt
