# Programa de validacion: usa TODAS las instrucciones de docs/spec/isa.md,
# las pseudo-instrucciones soportadas y los casos de borde de cada formato
# (inmediatos negativos, extremos de rango, saltos hacia adelante y atras).
#
# No se ejecuta: solo se compara su codificacion contra un ensamblador
# estandar (validate_reference.py). Por eso solo usa sintaxis portable.

        .text
        # sin .globl: un ensamblador estandar no resuelve saltos a simbolos
        # globales dentro del objeto (deja relocaciones para el linker)
        .equ    BASE, 0x100
        .equ    NEG, -16

inicio:
# ---- R-type: todos, con nombres xN y ABI ----------------------------------
        add     x1, x2, x3
        sub     x31, x30, x29
        sll     t0, t1, t2
        srl     a0, a1, a2
        sra     s0, s1, s2
        and     ra, sp, gp
        or      tp, fp, s11
        xor     a7, t6, zero
        slt     x5, x6, x7
        sltu    x8, x9, x10

# ---- I-type: aritmeticas, logicas y extremos del inmediato de 12 bits -----
        addi    x1, x0, 0
        addi    x1, x0, 2047
        addi    x1, x0, -2048
        addi    sp, sp, -4
        addi    a0, a0, NEG
        andi    t0, t1, 0xff
        andi    t0, t1, -1
        ori     t2, t3, 0x7ff
        xori    t4, t5, -1
        slti    s3, s4, -100
        sltiu   s5, s6, 1

# ---- I-type: desplazamientos (shamt 0..31, funct7 en imm[11:5]) -----------
        slli    a3, a4, 0
        slli    a3, a4, 31
        srli    a5, a6, 1
        srai    s7, s8, 31
        srai    s9, s10, 5

# ---- Loads: offsets positivos, negativos, cero y simbolicos ---------------
        lb      x1, 0(x2)
        lh      x3, -2(x4)
        lw      x5, 2047(x6)
        lbu     x7, -2048(x8)
        lhu     x9, BASE(x10)
        lw      ra, (sp)

# ---- Stores ----------------------------------------------------------------
        sb      x11, 1(x12)
        sh      x13, -2(x14)
        sw      x15, 2044(x16)
        sw      ra, -2048(sp)
        sw      zero, NEG(sp)

# ---- U-type: extremos -------------------------------------------------------
        lui     x1, 0
        lui     x2, 0xfffff
        lui     sp, 1

# ---- Saltos hacia atras ------------------------------------------------------
atras:
        beq     x1, x2, atras           # desplazamiento 0
        bne     x3, x4, atras           # -4
        beq     t0, t1, inicio          # largo hacia atras
        jal     ra, atras
        jal     x0, inicio

# ---- Saltos hacia adelante --------------------------------------------------
        beq     a0, a1, adelante
        bne     a2, a3, adelante
        jal     ra, adelante
        jalr    x0, 0(ra)
        jalr    ra, -4(t0)
        jalr    t1, 2047(t2)
adelante:
        jal     funcion

# ---- Pseudo-instrucciones ----------------------------------------------------
        nop
        mv      a0, a1
        not     t0, t1
        neg     t2, t3
        li      a0, 0
        li      a0, -1
        li      a0, 2047
        li      a0, -2048
        li      a2, 0x12345678
        li      a3, 0x7ffff800
        li      a4, -2049
        li      a5, 0x10000
        li      a6, 0xffffffff
        li      a7, 0x80000000
        beqz    a0, funcion
        bnez    a0, atras
        j       atras
        j       funcion

funcion:
        jr      t0
        ret
        .word   0x00000013, 0xdeadbeef, -1
        halt
