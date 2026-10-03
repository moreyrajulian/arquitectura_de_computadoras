# loaduse_rs1_rs2: carga-uso en rs1, en rs2 y en los dos.
#
# Prueba: la instruccion que sigue a un lw usa el dato cargado. La deteccion
# frena un ciclo y despues el dato llega por forwarding desde MEM/WB
# (pipeline.md 10.3). Tres stalls en total. Es tambien el programa que se
# ejecuta en modo STEP para probar STEP en medio de un stall (verificacion.md
# 3.3).
#
# Para M7 (sin stall ni forwarding) esta loaduse_rs1_rs2_nops.
# Estado esperado: loaduse_rs1_rs2.exp

        addi    x1, x0, 42              # x1 = 0x0000002A
        addi    x2, x0, -5              # x2 = 0xFFFFFFFB
        addi    x3, x0, 3               # independiente
        sw      x1, 8(x0)               # dmem[0x008] = 0x0000002A
        sw      x2, 12(x0)              # dmem[0x00C] = 0xFFFFFFFB
        lw      x5, 8(x0)               # x5 = 0x0000002A
        add     x6, x5, x0              # rs1: stall, x6 = 0x0000002A
        lw      x7, 12(x0)              # x7 = 0xFFFFFFFB
        sub     x8, x0, x7              # rs2: stall, x8 = 0x00000005
        lw      x9, 8(x0)               # x9 = 0x0000002A
        add     x10, x9, x9             # los dos: stall, x10 = 0x00000054
        halt
