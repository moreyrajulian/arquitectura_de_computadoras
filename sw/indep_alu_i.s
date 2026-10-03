# indep_alu_i: instrucciones con inmediato independientes (incluye shifts).
#
# Parte del estado inicial (sw/estado_inicial/). Solo leen x1-x9 y escriben
# x11-x31: ninguna lee un registro que escribe otra (ver indep_alu_r.s).
# Estado esperado: indep_alu_i.exp

        addi    x11, x1, -8             # 7 - 8               = 0xFFFFFFFF
        addi    x12, x2, 2047           # -3 + 2047           = 0x000007FC
        andi    x13, x8, 0xFF           #                     = 0x000000EF
        andi    x14, x8, -256           # & 0xFFFFFF00        = 0xDEADBE00
        ori     x15, x1, -2048          # 7 | 0xFFFFF800      = 0xFFFFF807
        xori    x16, x9, -1             # ~0x12345678         = 0xEDCBA987
        slti    x17, x2, -2             # -3 < -2             = 1
        slti    x18, x1, 7              # 7 < 7               = 0
        sltiu   x19, x1, -1             # 7 <u 0xFFFFFFFF     = 1
        sltiu   x20, x2, 5              # 0xFFFFFFFD <u 5     = 0
        slli    x21, x1, 31             # 7 << 31             = 0x80000000
        srli    x22, x4, 31             # 0x80000000 >> 31    = 0x00000001
        srai    x23, x4, 31             # 0x80000000 >>a 31   = 0xFFFFFFFF
        srai    x24, x8, 4              # 0xDEADBEEF >>a 4    = 0xFDEADBEE
        srli    x25, x8, 4              # 0xDEADBEEF >> 4     = 0x0DEADBEE
        slli    x26, x9, 4              # 0x12345678 << 4     = 0x23456780
        halt
