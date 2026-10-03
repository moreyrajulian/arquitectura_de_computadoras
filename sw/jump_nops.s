# jump_nops: jump con dos nop despues de cada salto.
#
# Variante para M7 (sin flush): las dos instrucciones que entran detras de un
# salto se ejecutan siempre, asi que tienen que ser nop. El retorno de "func"
# vuelve a los nop de 0x04, que se ejecutan y no cambian nada. Mismo estado
# que jump salvo los registros que guardan direcciones (x1, x2, x3, x5),
# porque el codigo se corre.
# Los destinos de jalr son direcciones fijas: si se agrega o se quita una
# instruccion antes de "impar", hay que corregir el addi de 0x40.
# Estado esperado: jump_nops.exp

        jal     x1, func                # 0x00  x1 = 0x04 (ra)
        nop                             # 0x04  (retorno)
        nop                             # 0x08
        addi    x10, x10, 1             # 0x0C  x10 = 1
        jal     x0, salto2              # 0x10
        nop                             # 0x14
        nop                             # 0x18
        addi    x21, x0, 1              # 0x1C  no se ejecuta
        addi    x21, x0, 2              # 0x20  no se ejecuta
func:   addi    x11, x0, 0x11           # 0x24
        addi    x12, x0, 0x12           # 0x28
        jalr    x0, 0(x1)               # 0x2C  ret: vuelve a 0x04
        nop                             # 0x30
        nop                             # 0x34
        addi    x22, x0, 1              # 0x38  no se ejecuta
        addi    x22, x0, 2              # 0x3C  no se ejecuta
salto2: addi    x2, x0, 0x5D            # 0x40  x2 = 0x5D
        addi    x13, x0, 0x13           # 0x44
        addi    x14, x0, 0x14           # 0x48
        jalr    x3, 4(x2)               # 0x4C  destino 0x61 & ~1 = 0x60; x3 = 0x50
        nop                             # 0x50
        nop                             # 0x54
        addi    x23, x0, 1              # 0x58  no se ejecuta
        addi    x23, x0, 2              # 0x5C  no se ejecuta
impar:  addi    x15, x0, 0x15           # 0x60
        jal     x5, fin                 # 0x64  x5 = 0x68
        nop                             # 0x68
        nop                             # 0x6C
        addi    x24, x0, 1              # 0x70  no se ejecuta
        addi    x24, x0, 2              # 0x74  no se ejecuta
fin:    halt                            # 0x78
