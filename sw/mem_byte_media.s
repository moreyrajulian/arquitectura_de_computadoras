# mem_byte_media: accesos por byte y por media palabra.
#
# Prueba:
# - sb en cada posicion del byte, con datos de bit alto en 0 y en 1, y con
#   bits altos "basura" en rs2 que no se tienen que escribir;
# - orden little-endian (el byte de la direccion a va en los bits 8*(a mod 4));
# - sh en las dos posiciones de la palabra;
# - que sb y sh no tocan los bytes vecinos (palabra 0x10C);
# - lb y lbu de cada byte, lh y lhu de cada media palabra, con bit alto en 0 y
#   en 1 en cada posicion (extension de signo contra extension con ceros).
#
# Sin riesgos: dependencias a distancia >= 3 y ningun dato cargado se vuelve a
# leer. Los loads seguidos no frenan aunque la deteccion de load-use mire los
# campos sin decodificar: ningun inmediato tiene en sus bits [4:0] el rd del
# load anterior (M7).
# Estado esperado: mem_byte_media.exp

        addi    x1, x0, -127            # x1 = 0xFFFFFF81 -> byte 0x81
        addi    x2, x0, 0x7E            # x2 = 0x0000007E -> byte 0x7E
        addi    x3, x0, 0x5F0           # x3 = 0x000005F0 -> byte 0xF0
        addi    x4, x0, 0x705           # x4 = 0x00000705 -> byte 0x05
        addi    x5, x0, 0x0F            # x5 = 0x0000000F -> byte 0x0F
        addi    x6, x0, -6              # x6 = 0xFFFFFFFA -> byte 0xFA
        lui     x7, 0x11223             # x7 = 0x11223000
        lui     x8, 0xFFFF8             # x8 = 0xFFFF8000
        lui     x9, 8                   # x9 = 0x00008000
        addi    x7, x7, 0x344           # x7 = 0x11223344
        addi    x8, x8, 1               # x8 = 0xFFFF8001 -> media 0x8001
        addi    x9, x9, -2              # x9 = 0x00007FFE -> media 0x7FFE

# Palabra 0x100 = 05 F0 7E 81 (bit alto 1, 0, 1, 0 desde el byte 0)
        sb      x1, 0x100(x0)
        sb      x2, 0x101(x0)
        sb      x3, 0x102(x0)
        sb      x4, 0x103(x0)           # dmem[0x100] = 0x05F07E81
# Palabra 0x104 = FA 0F 81 7E (bit alto 0, 1, 0, 1 desde el byte 0)
        sb      x2, 0x104(x0)
        sb      x1, 0x105(x0)
        sb      x5, 0x106(x0)
        sb      x6, 0x107(x0)           # dmem[0x104] = 0xFA0F817E
# Palabra 0x108 = medias 7FFE y 8001
        sh      x8, 0x108(x0)
        sh      x9, 0x10A(x0)           # dmem[0x108] = 0x7FFE8001
# Vecinos: sb y sh sobre una palabra ya escrita
        sw      x7, 0x10C(x0)           # dmem[0x10C] = 0x11223344
        sb      x1, 0x10D(x0)           # solo el byte 1:  0x11228144
        lw      x10, 0x10C(x0)          # x10 = 0x11228144
        sh      x9, 0x10E(x0)           # solo los bytes 2-3: 0x7FFE8144

# lb: extension de signo
        lb      x11, 0x100(x0)          # 0x81 -> 0xFFFFFF81
        lb      x12, 0x101(x0)          # 0x7E -> 0x0000007E
        lb      x13, 0x102(x0)          # 0xF0 -> 0xFFFFFFF0
        lb      x14, 0x103(x0)          # 0x05 -> 0x00000005
        lb      x15, 0x104(x0)          # 0x7E -> 0x0000007E
        lb      x16, 0x105(x0)          # 0x81 -> 0xFFFFFF81
        lb      x17, 0x106(x0)          # 0x0F -> 0x0000000F
        lb      x18, 0x107(x0)          # 0xFA -> 0xFFFFFFFA
# lbu: extension con ceros
        lbu     x19, 0x100(x0)          # 0x00000081
        lbu     x20, 0x101(x0)          # 0x0000007E
        lbu     x21, 0x102(x0)          # 0x000000F0
        lbu     x22, 0x103(x0)          # 0x00000005
        lbu     x23, 0x104(x0)          # 0x0000007E
        lbu     x24, 0x105(x0)          # 0x00000081
        lbu     x25, 0x106(x0)          # 0x0000000F
        lbu     x26, 0x107(x0)          # 0x000000FA
# lh: extension de signo (los registros x1-x6 ya no se leen: se reusan)
        lh      x27, 0x100(x0)          # 0x7E81 -> 0x00007E81
        lh      x28, 0x102(x0)          # 0x05F0 -> 0x000005F0
        lh      x29, 0x104(x0)          # 0x817E -> 0xFFFF817E
        lh      x30, 0x106(x0)          # 0xFA0F -> 0xFFFFFA0F
        lh      x31, 0x108(x0)          # 0x8001 -> 0xFFFF8001
        lh      x1, 0x10A(x0)           # 0x7FFE -> 0x00007FFE
# lhu: extension con ceros
        lhu     x2, 0x100(x0)           # 0x00007E81
        lhu     x3, 0x104(x0)           # 0x0000817E
        lhu     x4, 0x106(x0)           # 0x0000FA0F
        lhu     x5, 0x108(x0)           # 0x00008001
        lhu     x6, 0x102(x0)           # 0x000005F0
        halt
