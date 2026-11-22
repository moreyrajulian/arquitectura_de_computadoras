# demo_datos: demostracion del camino de datos (I-58).
#
# Muestra en pocos ciclos los riesgos de datos y como se resuelven:
# - forwarding desde EX/MEM y desde MEM/WB hacia la ALU, los dos a la vez en
#   el primer add (pipeline.md 10.2);
# - forwarding hacia el dato de un store, desde EX/MEM y desde MEM/WB;
# - carga-uso: el add despues del lw x5 frena un ciclo (pipeline.md 10.3). En
#   ese ciclo el sub x4 esta en WB y el add lee x4 en ID: lo entrega el bypass
#   del banco (decision 007). En el ciclo siguiente x5 llega desde MEM/WB;
# - load sin dependencia: el sw que sigue al lw x7 no lo usa y no frena.
#
# Es para la demo, no para la regresion: no esta en sw/programas.py y no
# tiene variante _nops. La cobertura por ciclo y el guion estan en README.md.
# Estado esperado: demo_datos.exp

        addi    x1, x0, 5               # 0x00  x1 = 5
        addi    x2, x0, 3               # 0x04  x2 = 3
        add     x3, x1, x2              # 0x08  x1 <- MEM/WB, x2 <- EX/MEM: x3 = 8
        sw      x3, 0x10(x0)            # 0x0C  dato x3 <- EX/MEM: dmem[0x010] = 8
        sub     x4, x3, x1              # 0x10  x3 <- MEM/WB: x4 = 3
        lw      x5, 0x10(x0)            # 0x14  x5 = 8
        add     x6, x5, x4              # 0x18  1 stall; x5 <- MEM/WB, x4 <- banco: x6 = 11
        lw      x7, 0x10(x0)            # 0x1C  x7 = 8
        sw      x6, 0x14(x0)            # 0x20  no usa x7: sin stall; dato x6 <- MEM/WB: dmem[0x014] = 11
        halt                            # 0x24
