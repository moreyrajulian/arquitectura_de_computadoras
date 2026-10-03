# jump: saltos incondicionales jal y jalr.
#
# Prueba: jal con rd = x1 (ra, llamada) y con rd distinto de x1 y de x0; jal con
# rd = x0 (j, no escribe nada); jalr como retorno de funcion (ret); jalr con
# desplazamiento y con el bit 0 de la direccion en 1, que se pone en 0
# (0x3D + 4 = 0x41 -> 0x40).
#
# Detras de cada salto hay dos instrucciones que NO se tienen que ejecutar
# (escriben x21 a x24). x10 cuenta las veces que se pasa por la direccion de
# retorno: tiene que quedar en 1.
#
# Sin riesgos de datos (distancias >= 3), solo de control: sin flush (M7) da
# otro resultado; para M7 esta jump_nops.
# Los destinos de jalr son direcciones fijas: si se agrega o se quita una
# instruccion antes de "impar", hay que corregir el addi de 0x28.
# Estado esperado: jump.exp

        jal     x1, func                # 0x00  x1 = 0x04 (ra)
        addi    x10, x10, 1             # 0x04  retorno: x10 = 1
        jal     x0, salto2              # 0x08  j: no escribe ningun registro
        addi    x21, x0, 1              # 0x0C  no se ejecuta
        addi    x21, x0, 2              # 0x10  no se ejecuta
func:   addi    x11, x0, 0x11           # 0x14  x11 = 0x11
        addi    x12, x0, 0x12           # 0x18  x12 = 0x12
        jalr    x0, 0(x1)               # 0x1C  ret: vuelve a 0x04
        addi    x22, x0, 1              # 0x20  no se ejecuta
        addi    x22, x0, 2              # 0x24  no se ejecuta
salto2: addi    x2, x0, 0x3D            # 0x28  x2 = 0x3D
        addi    x13, x0, 0x13           # 0x2C  x13 = 0x13
        addi    x14, x0, 0x14           # 0x30  x14 = 0x14
        jalr    x3, 4(x2)               # 0x34  destino 0x41 & ~1 = 0x40; x3 = 0x38
        addi    x23, x0, 1              # 0x38  no se ejecuta
        addi    x23, x0, 2              # 0x3C  no se ejecuta
impar:  addi    x15, x0, 0x15           # 0x40  x15 = 0x15
        jal     x5, fin                 # 0x44  x5 = 0x48
        addi    x24, x0, 1              # 0x48  no se ejecuta
        addi    x24, x0, 2              # 0x4C  no se ejecuta
fin:    halt                            # 0x50
