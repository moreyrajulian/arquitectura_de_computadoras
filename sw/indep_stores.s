# indep_stores: stores independientes.
#
# Parte del estado inicial (sw/estado_inicial/). Solo leen x1-x9 y no
# escriben registros. Escriben palabras, medias palabras y bytes en cada
# posicion, en palabras vacias y sobre las palabras precargadas (los bytes
# vecinos no cambian). El efecto se ve en la memoria de datos al terminar MEM,
# sin necesitar WB.
# Estado esperado: indep_stores.exp

        sw      x8, 0x10(x0)            # 0x010 = 0xDEADBEEF
        sw      x9, -8(x7)              # 0xFF8 = 0x12345678
        sh      x8, 0x20(x0)            # 0x020 = 0x0000BEEF
        sh      x9, 0x26(x0)            # 0x024 = 0x56780000
        sb      x8, 0x28(x0)            # 0x028 = 0x000000EF
        sb      x9, 0x29(x0)            # 0x028 = 0x000078EF
        sb      x8, 0x2E(x0)            # 0x02C = 0x00EF0000
        sb      x9, 0x2F(x0)            # 0x02C = 0x78EF0000
        sw      x1, 8(x6)               # 0x108 = 0x00000007
        sh      x2, 0xC(x6)             # 0x10C = 0x0000FFFD
        sb      x2, 0(x6)               # 0x100: 0xDEADBEEF -> 0xDEADBEFD
        sh      x1, 6(x6)               # 0x104: 0x7F018040 -> 0x00078040
        halt
