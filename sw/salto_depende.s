# salto_depende: saltos que usan el resultado de instrucciones anteriores.
#
# Prueba: beq, bne y jalr que leen un registro escrito por la instruccion
# inmediatamente anterior (forwarding desde EX/MEM) o por la de hace dos
# (desde MEM/WB). No cuesta ciclos extra: el salto se resuelve en EX con los
# operandos ya reenviados (pipeline.md 10.5). x31 = -1 indica que se tomo un
# salto que no debia.
#
# Para M7 (sin forwarding ni flush) esta salto_depende_nops.
# El destino del jalr es una direccion fija: si se agrega o se quita una
# instruccion antes de "fin", hay que corregir el addi de 0x38.
# Estado esperado: salto_depende.exp

        addi    x1, x0, 5               # 0x00  x1 = 5
        addi    x2, x0, 6               # 0x04  x2 = 6
        addi    x9, x0, 9               # 0x08  x9 = 9
        addi    x3, x1, 1               # 0x0C  x3 = 6
        beq     x3, x2, paso1           # 0x10  x3 <- EX/MEM: 6 = 6, tomado
        addi    x20, x0, 1              # 0x14  no se ejecuta
        addi    x20, x0, 2              # 0x18  no se ejecuta
paso1:  addi    x4, x2, -1              # 0x1C  x4 = 5
        bne     x1, x4, malo            # 0x20  x4 <- EX/MEM: 5 = 5, no tomado
        addi    x8, x0, 8               # 0x24  x8 = 8
        addi    x10, x0, 0x10           # 0x28  independiente
        bne     x8, x9, paso2           # 0x2C  x8 <- MEM/WB: 8 != 9, tomado
        addi    x21, x0, 1              # 0x30  no se ejecuta
        addi    x21, x0, 2              # 0x34  no se ejecuta
paso2:  addi    x5, x0, 0x50            # 0x38  x5 = direccion de fin
        jalr    x6, 0(x5)               # 0x3C  x5 <- EX/MEM; x6 = 0x40
        addi    x22, x0, 1              # 0x40  no se ejecuta
        addi    x22, x0, 2              # 0x44  no se ejecuta
malo:   addi    x31, x0, -1             # 0x48
        halt                            # 0x4C
fin:    halt                            # 0x50
