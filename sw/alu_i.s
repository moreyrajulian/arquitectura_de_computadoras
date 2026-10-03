# alu_i: instrucciones aritmeticas y logicas con inmediato.
#
# Prueba: addi andi ori xori slti sltiu con inmediato positivo, negativo,
# maximo (2047) y minimo (-2048). sltiu contra -1: el inmediato se extiende
# con signo (0xFFFFFFFF) y despues se compara sin signo.
#
# Sin riesgos: toda dependencia esta a distancia >= 3 (M7).
# Estado esperado: alu_i.exp

        addi    x1, x0, 100             # x1 = 0x00000064
        addi    x2, x0, -100            # x2 = 0xFFFFFF9C
        addi    x3, x0, 0x678           # x3 = 0x00000678

        addi    x10, x1, -1             # 100 - 1             = 0x00000063
        addi    x11, x2, 2047           # -100 + 2047         = 0x0000079B
        addi    x12, x0, -2048          #                     = 0xFFFFF800
        andi    x13, x2, -16            # 0xFFFFFF9C & 0xFFFFFFF0 = 0xFFFFFF90
        andi    x14, x3, 0xF0           # 0x678 & 0x0F0       = 0x00000070
        ori     x15, x3, -2048          # 0x678 | 0xFFFFF800  = 0xFFFFFE78
        xori    x16, x1, -1             # ~0x64               = 0xFFFFFF9B
        xori    x17, x3, 0xFF           # 0x678 ^ 0x0FF       = 0x00000687
        slti    x18, x2, -99            # -100 < -99          = 1
        slti    x19, x1, -1             # 100 < -1            = 0
        sltiu   x20, x1, -1             # 0x64 <u 0xFFFFFFFF  = 1
        sltiu   x21, x2, -1             # 0xFFFFFF9C <u 0xFFFFFFFF = 1
        sltiu   x22, x2, 100            # 0xFFFFFF9C <u 0x64  = 0
        sltiu   x23, x0, 1              # 0 <u 1              = 1
        slti    x24, x2, 0              # -100 < 0            = 1
        halt
