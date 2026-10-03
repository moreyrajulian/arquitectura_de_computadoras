# indep_cargas: loads independientes.
#
# Parte del estado inicial (sw/estado_inicial/): leen la memoria de datos
# precargada usando como base x0, x6 = 0x100 y x7 = 0x1000. Ningun registro
# cargado se vuelve a leer, asi que no hay carga-uso; tampoco hay stalls por
# la comparacion conservadora: ningun inmediato tiene en sus bits [4:0] el rd
# del load anterior. El dato leido se ve en MEM/WB.
# Estado esperado: indep_cargas.exp

        lw      x11, 0(x6)              # 0x100 = 0xDEADBEEF
        lw      x12, -4(x7)             # 0xFFC = 0xCAFEBABE
        lw      x13, 0x104(x0)          # 0x104 = 0x7F018040
        lb      x14, 0(x6)              # 0x100: 0xEF -> 0xFFFFFFEF
        lb      x15, 5(x6)              # 0x105: 0x80 -> 0xFFFFFF80
        lb      x16, 4(x6)              # 0x104: 0x40 -> 0x00000040
        lbu     x17, 1(x6)              # 0x101: 0xBE -> 0x000000BE
        lbu     x18, 7(x6)              # 0x107: 0x7F -> 0x0000007F
        lh      x19, 2(x6)              # 0x102: 0xDEAD -> 0xFFFFDEAD
        lh      x20, 6(x6)              # 0x106: 0x7F01 -> 0x00007F01
        lhu     x21, 0(x6)              # 0x100: 0xBEEF -> 0x0000BEEF
        lhu     x22, 4(x6)              # 0x104: 0x8040 -> 0x00008040
        halt
