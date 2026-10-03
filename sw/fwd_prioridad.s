# fwd_prioridad: las instrucciones anteriores escriben el mismo registro.
#
# Prueba: cuando EX/MEM y MEM/WB tienen el mismo rd, gana EX/MEM, que es el
# valor mas reciente (pipeline.md 10.2). Se prueba en rs1, en rs2 y con tres
# escrituras seguidas (EX/MEM, MEM/WB y el banco a la vez).
#
# Para M7 (sin forwarding) esta fwd_prioridad_nops.
# Estado esperado: fwd_prioridad.exp

        addi    x1, x0, 1               # x1 = 1 (queda en MEM/WB)
        addi    x1, x0, 2               # x1 = 2 (queda en EX/MEM)
        add     x2, x1, x0              # rs1: tiene que ser 2, no 1
        addi    x3, x0, 5
        addi    x3, x0, 6
        sub     x4, x0, x3              # rs2: 0 - 6 = 0xFFFFFFFA, no 0 - 5
        addi    x5, x0, 0x10            # banco
        addi    x5, x0, 0x20            # MEM/WB
        addi    x5, x0, 0x30            # EX/MEM
        add     x6, x5, x5              # 0x30 + 0x30 = 0x60
        halt
