# indep_store_load: un store seguido de un load a la misma direccion.
#
# Parte del estado inicial (sw/estado_inicial/). Solo leen x1-x9 y solo
# escriben x11-x16, que no se vuelven a leer. Cada load va justo despues
# del store a la misma palabra (distancia 1): el store escribe dmem al pasar
# de EX/MEM a MEM/WB y el load lee en el ciclo siguiente, asi que tiene que
# ver el dato nuevo. Se ve en mem_wb_read_data, sin necesitar WB. Incluye
# stores parciales sobre palabras vacias y sobre las precargadas, y loads
# de otro tamano que el store (los bytes vecinos no cambian). La instruccion
# que sigue a cada load no tiene su rd en los campos rs1 ni rs2, asi que no
# hay carga-uso, tampoco por la comparacion conservadora.
# Estado esperado: indep_store_load.exp

        sw      x8, 0x40(x0)            # 0x040 = 0xDEADBEEF
        lw      x11, 0x40(x0)           # x11 = 0xDEADBEEF
        sb      x9, 0x45(x0)            # 0x044 = 0x00007800
        lw      x12, 0x44(x0)           # x12 = 0x00007800 (los otros bytes en 0)
        sh      x2, 0x4A(x0)            # 0x048 = 0xFFFD0000
        lhu     x13, 0x4A(x0)           # x13 = 0x0000FFFD
        sw      x9, 4(x6)               # 0x104: 0x7F018040 -> 0x12345678
        lbu     x14, 5(x6)              # 0x105 = 0x56 -> x14 = 0x00000056
        sb      x8, 3(x6)               # 0x100: 0xDEADBEEF -> 0xEFADBEEF
        lb      x15, 3(x6)              # 0x103 = 0xEF -> x15 = 0xFFFFFFEF
        sh      x1, 0(x6)               # 0x100: 0xEFADBEEF -> 0xEFAD0007
        lw      x16, 0(x6)              # x16 = 0xEFAD0007
        halt
