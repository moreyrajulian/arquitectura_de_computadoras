# halt_camino_equivocado: un salto tomado pasa por encima de un HALT.
#
# Prueba: cuando el salto se resuelve en EX, el HALT de abajo ya entro al
# pipeline por el camino equivocado (en ID en el primer caso, en IF en el
# segundo). redirect gana en el mux del PC y el flush lo convierte en burbuja:
# no tiene que detener el procesador (pipeline.md 3.4). Si lo detuviera, x4 y
# x5 quedarian en 0.
#
# Solo tiene sentido con el pipeline completo (M8): sin flush el HALT se
# ejecuta. No tiene variante _nops.
# Estado esperado: halt_camino_equivocado.exp

        addi    x1, x0, 1               # x1 = 1
        addi    x2, x0, 2               # x2 = 2
        addi    x3, x0, 3               # x3 = 3
        beq     x0, x0, sigue           # tomado
        halt                            # en ID cuando el beq esta en EX
        addi    x20, x0, 1              # en IF cuando el beq esta en EX
sigue:  addi    x4, x0, 4               # x4 = 4
        jal     x0, fin                 # tomado
        addi    x21, x0, 1              # en ID cuando el jal esta en EX
        halt                            # en IF cuando el jal esta en EX
fin:    addi    x5, x0, 5               # x5 = 5
        halt
