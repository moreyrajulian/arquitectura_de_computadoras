# Fibonacci: guarda F(0) .. F(N-1) en la memoria de datos desde la
# direccion 0 y la suma de todos en x10 (a0). Usa una subrutina (jal/ret),
# un bucle con salto hacia atras y la pila en 0x1000 hacia abajo
# (memoria.md 2.2).
#
# Resultado esperado con N = 10:
#   dmem[0x00..0x24] = 0, 1, 1, 2, 3, 5, 8, 13, 21, 34
#   a0 = 88

        .equ    N, 10

        lui     sp, 1                   # sp = 0x1000 (tope de la pila)
        li      a0, N
        jal     ra, fib_tabla
        halt

# fib_tabla(a0 = n): escribe la tabla y devuelve la suma en a0
fib_tabla:
        addi    sp, sp, -4
        sw      ra, 0(sp)
        mv      t0, a0                  # t0 = cantidad restante
        li      t1, 0                   # t1 = F(i)
        li      t2, 1                   # t2 = F(i+1)
        li      t3, 0                   # t3 = direccion destino
        li      a0, 0                   # a0 = suma
bucle:
        beqz    t0, fin
        sw      t1, 0(t3)
        add     a0, a0, t1
        add     t4, t1, t2              # siguiente termino
        mv      t1, t2
        mv      t2, t4
        addi    t3, t3, 4
        addi    t0, t0, -1
        j       bucle
fin:
        lw      ra, 0(sp)
        addi    sp, sp, 4
        ret
