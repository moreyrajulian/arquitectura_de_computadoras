# bypass_banco: RAW a distancia 3, bypass interno del banco de registros.
#
# Prueba: el consumidor esta en ID en el mismo ciclo en que el productor
# escribe en WB; el banco entrega el dato nuevo (decision 007). Se prueba en
# rs1, en rs2, en los dos, como dato de un sw y con el dato de un lw.
#
# Corre igual en M7 (el bypass esta en el banco, no en el forwarding): no
# necesita variante _nops.
# Estado esperado: bypass_banco.exp

        addi    x1, x0, 0x21            # x1 = 0x00000021
        addi    x10, x0, 1              # independiente
        addi    x11, x0, 2              # independiente
        add     x2, x1, x0              # rs1 a distancia 3: x2 = 0x00000021
        addi    x12, x0, 3
        addi    x13, x0, 4
        sub     x3, x0, x2              # rs2 a distancia 3: x3 = 0xFFFFFFDF
        addi    x14, x0, 5
        addi    x15, x0, 6
        add     x4, x3, x3              # los dos:           x4 = 0xFFFFFFBE
        addi    x16, x0, 7
        addi    x17, x0, 8
        sw      x4, 0x10(x0)            # dato del sw:       dmem[0x010] = 0xFFFFFFBE
        lw      x5, 0x10(x0)            # x5 = 0xFFFFFFBE
        addi    x18, x0, 9
        addi    x19, x0, 10
        add     x6, x5, x0              # dato del lw a distancia 3: x6 = 0xFFFFFFBE
        halt
