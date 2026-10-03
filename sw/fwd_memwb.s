# fwd_memwb: RAW a distancia 2, forwarding desde MEM/WB.
#
# Prueba: entre el productor y el consumidor hay una instruccion que no tiene
# nada que ver; el dato llega desde MEM/WB (pipeline.md 10.2, fwd = 01), en
# rs1, en rs2, en los dos y como dato de un sw.
#
# Para M7 (sin forwarding) esta fwd_memwb_nops.
# Estado esperado: fwd_memwb.exp

        addi    x1, x0, 7               # x1 = 0x00000007
        addi    x10, x0, 1              # independiente
        addi    x2, x1, 3               # rs1 <- MEM/WB:  x2 = 0x0000000A
        addi    x11, x0, 2              # independiente
        sub     x3, x0, x2              # rs2 <- MEM/WB:  x3 = 0xFFFFFFF6
        addi    x12, x0, 3              # independiente
        add     x4, x3, x3              # los dos:        x4 = 0xFFFFFFEC
        addi    x13, x0, 4              # independiente
        sw      x4, 8(x0)               # dato del sw:    dmem[0x008] = 0xFFFFFFEC
        halt
