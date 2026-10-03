# fwd_prioridad_nops: fwd_prioridad con dos nop antes de cada consumidor.
#
# Variante para M7: la ultima escritura queda a distancia 3 del consumidor.
# Mismo estado que fwd_prioridad.
# Estado esperado: fwd_prioridad_nops.exp

        addi    x1, x0, 1
        addi    x1, x0, 2
        nop
        nop
        add     x2, x1, x0              # x2 = 2
        addi    x3, x0, 5
        addi    x3, x0, 6
        nop
        nop
        sub     x4, x0, x3              # x4 = 0xFFFFFFFA
        addi    x5, x0, 0x10
        addi    x5, x0, 0x20
        addi    x5, x0, 0x30
        nop
        nop
        add     x6, x5, x5              # x6 = 0x60
        halt
