# mixto_lazo: programa corto realista, prueba de humo de la regresion.
#
# Arma con stores el arreglo a[k] = 3k + 1 (k = 0..4) en 0x100 y lo suma con
# un lazo de loads. Mezcla lazos con salto hacia atras, loads, stores,
# forwarding hacia un store (addi x2 -> primer sw, distancia 2) y hacia un
# salto (addi x3 -> bne) y un carga-uso por vuelta (lw x5 -> add).
# Suma: 1 + 4 + 7 + 10 + 13 = 35 = 0x23, que queda en x10 y en 0x200.
#
# Para M7 (sin forwarding, stall ni flush) esta mixto_lazo_nops.
# Estado esperado: mixto_lazo.exp

        addi    x1, x0, 0x100           # x1 = puntero al arreglo
        addi    x2, x0, 1               # x2 = valor a guardar
        addi    x3, x0, 5               # x3 = elementos que faltan
llenar: sw      x2, 0(x1)               # a[k] = valor
        addi    x2, x2, 3
        addi    x1, x1, 4
        addi    x3, x3, -1
        bne     x3, x0, llenar          # x3 <- EX/MEM; 4 tomados, 1 no

        addi    x1, x0, 0x100           # x1 = puntero al arreglo
        addi    x3, x0, 5               # x3 = elementos que faltan
        addi    x10, x0, 0              # x10 = suma
sumar:  lw      x5, 0(x1)
        add     x10, x10, x5            # carga-uso: 1 stall por vuelta
        addi    x1, x1, 4
        addi    x3, x3, -1
        bne     x3, x0, sumar           # x3 <- EX/MEM; 4 tomados, 1 no
        sw      x10, 0x200(x0)          # dmem[0x200] = 0x23
        halt
