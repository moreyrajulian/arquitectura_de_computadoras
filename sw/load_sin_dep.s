# load_sin_dep: carga seguida de instrucciones que no dependen de ella.
#
# Prueba: despues de un lw viene una instruccion que no usa el dato, asi que
# no hay stall; el dato se usa recien a distancia 2 y llega por forwarding
# desde MEM/WB (pipeline.md 10.2 y 10.3). Si el procesador frenara de mas, el
# estado seria el mismo pero tardaria mas ciclos.
#
# Para M7 (sin forwarding) esta load_sin_dep_nops.
# Estado esperado: load_sin_dep.exp

        addi    x1, x0, 0x44            # x1 = 0x00000044
        addi    x2, x0, 0x10            # x2 = 0x00000010
        addi    x3, x0, 3               # x3 = 0x00000003
        sw      x1, 0x20(x0)            # dmem[0x020] = 0x00000044
        lw      x5, 0x20(x0)            # x5 = 0x00000044
        addi    x6, x2, 1               # no usa x5: sin stall, x6 = 0x00000011
        add     x7, x5, x0              # x5 a distancia 2: x7 = 0x00000044
        lw      x8, 0x20(x0)            # x8 = 0x00000044
        sw      x3, 0x24(x0)            # no usa x8: sin stall, dmem[0x024] = 3
        sub     x9, x0, x8              # x8 a distancia 2: x9 = 0xFFFFFFBC
        halt
