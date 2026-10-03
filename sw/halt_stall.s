# halt_stall: stall de carga-uso con el HALT en ID.
#
# Prueba: la palabra del HALT (0x00100073) tiene un 1 en el campo rs2, asi que
# un lw a x1 justo antes dispara la deteccion de carga-uso (falso positivo
# conservador, decision 011). IF/ID tiene que conservar el HALT durante el
# stall, porque en el registro de segmentacion en gana sobre flush
# (pipeline.md 3.4 y 10.4). Si el HALT se perdiera, se ejecutaria el addi de
# abajo o el procesador no se detendria.
#
# Solo tiene sentido con el pipeline completo (M8): sin deteccion de load-use
# no hay stall. No tiene variante _nops.
# Estado esperado: halt_stall.exp

        addi    x2, x0, 0x7B            # x2 = 0x0000007B
        addi    x3, x0, 1               # independiente
        addi    x4, x0, 2               # independiente
        sw      x2, 0(x0)               # dmem[0x000] = 0x0000007B
        lw      x1, 0(x0)               # x1 = 0x0000007B
        halt                            # stall: rs2 del HALT = 1 = rd del lw
        addi    x5, x0, 5               # no se ejecuta
        halt
