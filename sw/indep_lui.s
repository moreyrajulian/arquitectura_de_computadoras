# indep_lui: lui independientes.
#
# Parte del estado inicial (sw/estado_inicial/). Solo escriben x11-x31 y no
# leen registros (ver indep_alu_r.s). lui x14, 0 escribe un 0: si el
# inmediato se armara mal, quedaria otro valor.
# Estado esperado: indep_lui.exp

        lui     x11, 0x12345            # 0x12345000
        lui     x12, 0xFFFFF            # 0xFFFFF000
        lui     x13, 0x80000            # 0x80000000
        lui     x14, 0                  # 0x00000000
        lui     x15, 1                  # 0x00001000
        lui     x16, 0x7FFFF            # 0x7FFFF000
        halt
