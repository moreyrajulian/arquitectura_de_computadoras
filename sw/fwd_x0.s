# fwd_x0: escritura en x0.
#
# Prueba: una instruccion con rd = x0 no tiene efecto y no se reenvia
# (pipeline.md 10.2, rd != 0), ni desde EX/MEM (distancia 1), ni desde MEM/WB
# (distancia 2), ni por el bypass del banco (distancia 3, decision 007). Un lw
# con rd = x0 tampoco frena a la instruccion siguiente (pipeline.md 10.3): si
# frenara, el programa tardaria un ciclo de mas.
#
# Sin riesgos reales: las lecturas de x0 tienen que dar 0 con o sin forwarding,
# asi que corre igual en M7 y no necesita variante _nops.
# Estado esperado: fwd_x0.exp

        addi    x1, x0, 9               # x1 = 9
        addi    x2, x0, 4               # x2 = 4
        addi    x3, x0, 5               # x3 = 5
        addi    x0, x1, 0x123           # intenta x0 = 0x12C: no tiene efecto
        add     x4, x0, x1              # x0 en rs1 a distancia 1: x4 = 0 + 9 = 9
        addi    x0, x2, 7               # intenta x0 = 0xB
        sub     x5, x3, x0              # x0 en rs2 a distancia 1: x5 = 5 - 0 = 5
                                        # (y a distancia 3 de la escritura en x0 de arriba)
        addi    x0, x3, 1               # intenta x0 = 6
        addi    x6, x1, 0               # x6 = 9
        addi    x7, x0, 0x77            # x0 a distancia 2: x7 = 0x77
        sw      x1, 0(x0)               # x0 como base a distancia 3: dmem[0x000] = 9
        lw      x0, 0(x0)               # load a x0: no tiene efecto
        add     x8, x0, x1              # sin stall ni forwarding: x8 = 0 + 9 = 9
        halt
