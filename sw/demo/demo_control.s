# demo_control: demostracion de los saltos (I-58).
#
# Guarda en memoria los terminos de Fibonacci F(3) a F(6) (2, 3, 5, 8) con un
# lazo y despues comprueba el ultimo leyendolo de vuelta. Muestra:
# - salto hacia atras: el bne se toma 3 veces (flush de 2 ciclos, pipeline.md
#   10.5) y la ultima no se toma (0 ciclos);
# - forwarding al comparador: el bne recibe x3 desde EX/MEM;
# - un load seguido de un salto que usa el dato: el beq frena un ciclo y recibe
#   x6 desde MEM/WB (pipeline.md 10.3);
# - un HALT en el camino equivocado: cuando el beq se resuelve en EX, el HALT de
#   0x30 esta en ID; el flush lo anula y el procesador no se detiene. Si se
#   detuviera, o si el flush fallara, x15 quedaria en -1.
#
# Para cambiar la cantidad de vueltas se cambia el fin del arreglo en x4
# (0x100 + 4 * vueltas): ciclos = 12 + 8 * vueltas.
#
# Es para la demo, no para la regresion: no esta en sw/programas.py y no
# tiene variante _nops. La cobertura por ciclo y el guion estan en README.md.
# Estado esperado: demo_control.exp

        addi    x1, x0, 1               # 0x00  x1 = F(1) = 1
        addi    x2, x0, 1               # 0x04  x2 = F(2) = 1
        addi    x3, x0, 0x100           # 0x08  x3 = puntero al arreglo
        addi    x4, x0, 0x110           # 0x0C  x4 = fin del arreglo: 4 vueltas
lazo:   add     x5, x1, x2              # 0x10  x5 = F(k) = F(k-2) + F(k-1)
        sw      x5, 0(x3)               # 0x14  dmem[x3] = F(k); dato x5 <- EX/MEM
        addi    x1, x2, 0               # 0x18  x1 = F(k-1)
        addi    x2, x5, 0               # 0x1C  x2 = F(k); x5 <- banco
        addi    x3, x3, 4               # 0x20  x3 = siguiente palabra
        bne     x3, x4, lazo            # 0x24  x3 <- EX/MEM; 3 tomados, 1 no
        lw      x6, -4(x3)              # 0x28  x6 = dmem[0x10C] = 8
        beq     x6, x2, fin             # 0x2C  1 stall; x6 <- MEM/WB; tomado (8 = 8)
        halt                            # 0x30  camino equivocado (en ID): no detiene el core
        addi    x15, x0, -1             # 0x34  camino equivocado (en IF): no se ejecuta
fin:    halt                            # 0x38
