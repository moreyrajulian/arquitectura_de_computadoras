# fwd_exmem_nops: fwd_exmem con nop entre cada productor y su consumidor.
#
# Variante para M7 (pipeline sin forwarding, stall ni flush): con dos nop en
# el medio cada dependencia queda a distancia 3 y la resuelve el banco de
# registros. Deja el mismo estado que fwd_exmem; solo cambia la cantidad de
# ciclos. Con el pipeline completo (M8) tiene que dar lo mismo.
# Estado esperado: fwd_exmem_nops.exp

        addi    x1, x0, 10              # x1 = 0x0000000A
        nop
        nop
        addi    x2, x1, 5               # x2 = 0x0000000F
        nop
        nop
        sub     x3, x0, x2              # x3 = 0xFFFFFFF1
        nop
        nop
        add     x4, x3, x3              # x4 = 0xFFFFFFE2
        nop
        nop
        sw      x4, 0(x0)               # dmem[0x000] = 0xFFFFFFE2
        addi    x5, x0, 0x40            # x5 = 0x00000040
        nop
        nop
        sw      x2, 4(x5)               # dmem[0x044] = 0x0000000F
        halt
