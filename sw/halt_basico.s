# halt_basico: HALT con instrucciones detras que no se tienen que ejecutar.
#
# Prueba: despues del HALT el PC se congela y lo que entra a IF/ID es burbuja
# (pipeline.md 3.4). Si alguna instruccion posterior se ejecutara, cambiaria
# x3, x4 o dmem[0x000].
#
# Sin riesgos (M7).
# Estado esperado: halt_basico.exp

        addi    x1, x0, 1               # x1 = 1
        addi    x2, x0, 2               # x2 = 2
        halt
        addi    x3, x0, 3               # no se ejecuta
        addi    x4, x0, 4               # no se ejecuta
        sw      x1, 0(x0)               # no se ejecuta
        halt
