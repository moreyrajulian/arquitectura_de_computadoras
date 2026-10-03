# mem_avisos: accesos desalineados y fuera de rango (memoria.md 6).
#
# Es el unico programa con accesos que no estan alineados o en rango. El
# procesador no se detiene: ignora los bits que sobran y deja un aviso que
# queda activo hasta el proximo reset.
# - dmem_misaligned: lw en 0x003, lh en 0x001 y sh en 0x00B.
# - dmem_oob: sw y lw en 0x1004 (caen en 0x004).
# - imem_fault: el HALT final se busca en 0x1030, que es un alias de 0x030.
#
# Sin riesgos de datos (distancias >= 3). El jalr va seguido de dos nop, asi
# que da lo mismo con flush o sin el (M7) y no hace falta variante _nops.
# Estado esperado: mem_avisos.exp

        lui     x3, 0x12345             # 0x00  x3 = 0x12345000
        addi    x1, x0, 0x55            # 0x04  x1 = 0x00000055
        lui     x2, 1                   # 0x08  x2 = 0x00001000
        sw      x3, 0(x0)               # 0x0C  dmem[0x000] = 0x12345000
        sh      x1, 0xB(x0)             # 0x10  0x00B -> 0x00A, bytes 2-3 de 0x008 (desalineado)
        sw      x1, 4(x2)               # 0x14  0x1004 -> dmem[0x004] = 0x55 (fuera de rango)
        lw      x10, 3(x0)              # 0x18  0x003 -> palabra 0x000 (desalineado)
        lw      x11, 4(x2)              # 0x1C  0x1004 -> palabra 0x004 (fuera de rango)
        lh      x12, 1(x0)              # 0x20  0x001 -> media 0x000 = 0x5000 (desalineado)
        jalr    x0, 0x30(x2)            # 0x24  salta a 0x1030: alias de fin (imem_fault)
        nop                             # 0x28
        nop                             # 0x2C
fin:    halt                            # 0x30
