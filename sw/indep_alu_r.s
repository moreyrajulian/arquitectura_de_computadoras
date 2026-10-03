# indep_alu_r: instrucciones de tipo R independientes.
#
# Parte del estado inicial (sw/estado_inicial/). Ninguna instruccion lee un
# registro que escribe otra: solo leen x1-x9 (estado inicial) y escriben
# x11-x31. Por eso el resultado no depende de WB, del forwarding ni del orden
# entre etapas, y sirve para validar IF a MEM antes de que exista WB: cada
# resultado se ve en ex_mem_result.
# Estado esperado: indep_alu_r.exp

        add     x11, x1, x2             # 7 + (-3)            = 0x00000004
        sub     x12, x1, x2             # 7 - (-3)            = 0x0000000A
        sub     x13, x4, x1             # minimo - 7          = 0x7FFFFFF9
        sll     x14, x1, x5             # 7 << (33 & 31 = 1)  = 0x0000000E
        srl     x15, x4, x5             # 0x80000000 >> 1     = 0x40000000
        sra     x16, x4, x5             # 0x80000000 >>a 1    = 0xC0000000
        and     x17, x8, x9             # DEADBEEF & 12345678 = 0x12241668
        or      x18, x8, x9             # DEADBEEF | 12345678 = 0xDEBDFEFF
        xor     x19, x8, x9             # DEADBEEF ^ 12345678 = 0xCC99E897
        slt     x20, x2, x1             # -3 < 7              = 1
        slt     x21, x3, x4             # maximo < minimo     = 0
        sltu    x22, x2, x1             # 0xFFFFFFFD <u 7     = 0
        sltu    x23, x4, x3             # 0x80000000 <u 0x7FFFFFFF = 0
        slt     x24, x4, x3             # minimo < maximo     = 1
        sltu    x25, x1, x2             # 7 <u 0xFFFFFFFD     = 1
        add     x26, x3, x1             # maximo + 7          = 0x80000006
        halt
