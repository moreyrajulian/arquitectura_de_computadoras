# alu_r: instrucciones aritmeticas y logicas de tipo R.
#
# Prueba: add sub sll srl sra and or xor slt sltu con operandos 0, positivos,
# negativos, el minimo (0x80000000) y el maximo (0x7FFFFFFF), incluido el
# desborde de add.
#
# Sin riesgos: toda dependencia esta a distancia >= 3 (la resuelve el banco de
# registros), asi que da el mismo resultado sin forwarding ni stall (M7).
# Estado esperado: alu_r.exp

        lui     x3, 0x80000             # x3 = 0x80000000 (minimo)
        addi    x1, x0, 7               # x1 = 0x00000007
        addi    x2, x0, -3              # x2 = 0xFFFFFFFD
        addi    x5, x3, -1              # x5 = 0x7FFFFFFF (maximo)
        addi    x4, x0, -1              # x4 = 0xFFFFFFFF
        addi    x6, x0, 4               # x6 = 4 (cantidad de desplazamiento)

        add     x10, x1, x2             # 7 + (-3)          = 0x00000004
        add     x11, x5, x1             # maximo + 7        = 0x80000006 (desborda)
        sub     x12, x1, x2             # 7 - (-3)          = 0x0000000A
        sub     x13, x0, x1             # 0 - 7             = 0xFFFFFFF9
        sll     x14, x1, x6             # 7 << 4            = 0x00000070
        srl     x15, x3, x6             # 0x80000000 >> 4   = 0x08000000
        sra     x16, x3, x6             # 0x80000000 >>a 4  = 0xF8000000
        and     x17, x2, x5             # 0xFFFFFFFD & max  = 0x7FFFFFFD
        or      x18, x1, x3             # 7 | minimo        = 0x80000007
        xor     x19, x2, x4             # 0xFFFFFFFD ^ -1   = 0x00000002
        slt     x20, x2, x1             # -3 < 7            = 1
        slt     x21, x1, x2             # 7 < -3            = 0
        sltu    x22, x2, x1             # 0xFFFFFFFD <u 7   = 0
        sltu    x23, x1, x2             # 7 <u 0xFFFFFFFD   = 1
        slt     x24, x3, x5             # minimo < maximo   = 1
        sltu    x25, x0, x1             # 0 <u 7            = 1
        add     x26, x0, x5             # 0 + maximo        = 0x7FFFFFFF
        halt
