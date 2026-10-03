# loaduse_sw_beq: carga seguida de un sw que usa el dato y de un salto.
#
# Prueba:
# - lw seguido de sw que guarda el dato cargado (rs2): frena, aunque se podria
#   resolver con forwarding hacia MEM, que no se implementa (decision 011);
# - lw seguido de sw que usa el dato como base (rs1): frena;
# - lw seguido de beq (tomado) y de bne (no tomado) que comparan el dato:
#   frenan un ciclo y despues el salto resuelve con el dato correcto
#   (pipeline.md 10.5: +1 ciclo).
# Cuatro stalls en total. x31 = -1 indica que se tomo un salto que no debia.
#
# Para M7 (sin stall, forwarding ni flush) esta loaduse_sw_beq_nops.
# Estado esperado: loaduse_sw_beq.exp

        addi    x4, x0, 0x20            # x4 = 0x00000020
        addi    x1, x0, 0x33            # x1 = 0x00000033
        addi    x2, x0, 0x33            # x2 = 0x00000033
        sw      x4, 0x10(x0)            # dmem[0x010] = 0x00000020
        sw      x1, 0(x0)               # dmem[0x000] = 0x00000033
        lw      x5, 0(x0)               # x5 = 0x00000033
        sw      x5, 4(x0)               # dato del sw: stall, dmem[0x004] = 0x33
        lw      x8, 0x10(x0)            # x8 = 0x00000020
        sw      x1, 0(x8)               # base del sw: stall, dmem[0x020] = 0x33
        lw      x6, 4(x0)               # x6 = 0x00000033
        beq     x6, x2, igual           # stall; tomado (0x33 = 0x33)
        addi    x20, x0, 1              # no se ejecuta
        addi    x20, x0, 2              # no se ejecuta
malo:   addi    x31, x0, -1
        halt
igual:  lw      x7, 0(x0)               # x7 = 0x00000033
        bne     x7, x1, malo            # stall; no tomado
        addi    x9, x0, 0x99            # x9 = 0x00000099
        halt
