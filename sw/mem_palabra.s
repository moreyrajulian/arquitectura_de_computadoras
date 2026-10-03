# mem_palabra: sw y lw de palabras completas.
#
# Prueba: sw/lw en 0x000 (primera palabra) y en 0xFFC (ultima, solo alcanzable
# con un registro base), con base distinta de x0 y desplazamiento negativo.
#
# Sin riesgos: toda dependencia esta a distancia >= 3 y ningun registro cargado
# se usa despues, asi que no hay load-use (M7).
# Estado esperado: mem_palabra.exp

        lui     x1, 0xDEADC             # x1 = 0xDEADC000
        lui     x2, 1                   # x2 = 0x00001000 (base, fuera de rango)
        addi    x3, x0, 0x123           # x3 = 0x00000123
        addi    x1, x1, -0x111          # x1 = 0xDEADBEEF
        lui     x4, 0x12345             # x4 = 0x12345000
        sw      x3, 0(x0)               # dmem[0x000] = 0x00000123
        sw      x1, -4(x2)              # dmem[0xFFC] = 0xDEADBEEF
        addi    x5, x0, 0x200           # x5 = 0x00000200 (base)
        sw      x4, 0x10(x0)            # dmem[0x010] = 0x12345000
        lw      x10, 0(x0)              # x10 = 0x00000123
        sw      x3, -8(x5)              # dmem[0x1F8] = 0x00000123
        lw      x11, -4(x2)             # x11 = 0xDEADBEEF (desde 0xFFC)
        lw      x12, 0x10(x0)           # x12 = 0x12345000
        lw      x13, -8(x5)             # x13 = 0x00000123 (desde 0x1F8)
        halt
