# fwd_exmem: RAW consecutiva, forwarding desde EX/MEM (distancia 1).
#
# Prueba: cada instruccion lee el resultado de la inmediatamente anterior, en
# rs1, en rs2, en los dos a la vez, como dato de un sw y como base de un sw
# (pipeline.md 10.2, fwd = 10). Sin forwarding leeria el valor viejo (0).
#
# Para M7 (sin forwarding) esta fwd_exmem_nops.
# Estado esperado: fwd_exmem.exp

        addi    x1, x0, 10              # x1 = 0x0000000A
        addi    x2, x1, 5               # rs1 <- EX/MEM:  x2 = 0x0000000F
        sub     x3, x0, x2              # rs2 <- EX/MEM:  x3 = 0xFFFFFFF1
        add     x4, x3, x3              # los dos:        x4 = 0xFFFFFFE2
        sw      x4, 0(x0)               # dato del sw:    dmem[0x000] = 0xFFFFFFE2
        addi    x5, x0, 0x40            # x5 = 0x00000040
        sw      x2, 4(x5)               # base del sw:    dmem[0x044] = 0x0000000F
        halt
