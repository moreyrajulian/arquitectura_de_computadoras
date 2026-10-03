# load_sin_dep_nops: load_sin_dep con un nop antes de cada uso del dato.
#
# Variante para M7: el nop lleva el uso a distancia 3 del lw. Mismo estado
# que load_sin_dep.
# Estado esperado: load_sin_dep_nops.exp

        addi    x1, x0, 0x44
        addi    x2, x0, 0x10
        addi    x3, x0, 3
        sw      x1, 0x20(x0)            # dmem[0x020] = 0x00000044
        lw      x5, 0x20(x0)
        addi    x6, x2, 1               # x6 = 0x00000011
        nop
        add     x7, x5, x0              # x7 = 0x00000044
        lw      x8, 0x20(x0)
        sw      x3, 0x24(x0)            # dmem[0x024] = 0x00000003
        nop
        sub     x9, x0, x8              # x9 = 0xFFFFFFBC
        halt
