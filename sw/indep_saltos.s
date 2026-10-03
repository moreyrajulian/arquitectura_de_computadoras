# indep_saltos: saltos independientes.
#
# Parte del estado inicial (sw/estado_inicial/). Las condiciones comparan
# x1-x3 (estado inicial); jal y jalr escriben x11-x13, que nadie lee; el
# jalr usa base x0, asi que su destino tampoco depende de otra instruccion.
# Prueba beq y bne tomados y no tomados, hacia adelante y hacia atras, jal y
# jalr (con el bit 0 del destino en 1).
#
# Cada salto va seguido de dos nop: da el mismo resultado con flush (M8) o sin
# el (antes de M8). x31 = -1 indica que se tomo un salto que no debia.
# Los destinos de jalr son direcciones fijas: si se agrega o se quita una
# instruccion antes de 0x64, hay que corregir el jalr de 0x58.
# Estado esperado: indep_saltos.exp

        beq     x1, x1, paso1           # 0x00  tomado (7 = 7)
        nop                             # 0x04
        nop                             # 0x08
        addi    x31, x0, -1             # 0x0C  no se ejecuta
paso1:  bne     x1, x2, paso2           # 0x10  tomado (7 != -3)
        nop                             # 0x14
        nop                             # 0x18
        addi    x31, x0, -1             # 0x1C  no se ejecuta
paso2:  beq     x1, x2, malo            # 0x20  no tomado
        nop                             # 0x24
        nop                             # 0x28
        bne     x3, x3, malo            # 0x2C  no tomado
        nop                             # 0x30
        nop                             # 0x34
        jal     x11, paso3              # 0x38  x11 = 0x3C
        nop                             # 0x3C
        nop                             # 0x40
atras:  jal     x13, fin                # 0x44  x13 = 0x48
        nop                             # 0x48
        nop                             # 0x4C
malo:   addi    x31, x0, -1             # 0x50
        halt                            # 0x54
paso3:  jalr    x12, 0x65(x0)           # 0x58  destino 0x65 & ~1 = 0x64; x12 = 0x5C
        nop                             # 0x5C
        nop                             # 0x60
        beq     x2, x2, atras           # 0x64  tomado hacia atras
        nop                             # 0x68
        nop                             # 0x6C
fin:    halt                            # 0x70
