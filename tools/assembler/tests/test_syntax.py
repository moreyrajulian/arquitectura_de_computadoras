"""Sintaxis aceptada: etiquetas, comentarios, directivas, formas de operandos y pseudos."""

from rvasm import assemble


def words(src: str) -> list[int]:
    return assemble(src).words


def test_comments_and_blank_lines():
    src = """
    # comentario de linea completa
    addi x1, x0, 5   # comentario al final
    // estilo C
    addi x1, x0, 5   // tambien al final

    """
    assert words(src) == [0x00500093, 0x00500093]


def test_labels_alone_inline_and_stacked():
    src = """
    a:
    b: c: addi x0, x0, 0
    d: beq x0, x0, a
       beq x0, x0, b
       beq x0, x0, c
       beq x0, x0, d
    """
    prog = assemble(src)
    assert prog.labels == {"a": 0, "b": 0, "c": 0, "d": 4}
    # cada beq salta a su etiqueta: offset = destino - PC del beq
    expected = [words(f"beq x0, x0, {off}")[0] for off in (-4, -8, -12, -12)]
    assert prog.words[1:] == expected


def test_label_at_end_of_program_points_past_last_word():
    prog = assemble("j fin\nhalt\nfin:\n")
    assert prog.labels["fin"] == 8
    assert prog.words[0] == assemble("jal x0, 8").words[0]


def test_case_insensitive_mnemonics_and_registers_but_not_labels():
    assert words("ADDI X1, ZERO, 5") == words("addi x1, x0, 5")
    assert assemble("Loop: j Loop").labels == {"Loop": 0}


def test_abi_register_names():
    assert words("add ra, sp, gp") == words("add x1, x2, x3")
    assert words("add fp, s0, s11") == words("add x8, x8, x27")
    assert words("add t6, a7, zero") == words("add x31, x17, x0")


def test_whitespace_is_flexible():
    assert words("  addi   x1 ,x0,   5  ") == words("addi x1, x0, 5")
    assert words("lw x1, 8 ( x2 )") == words("lw x1, 8(x2)")


def test_number_bases():
    assert words("addi x1, x0, 0x10") == words("addi x1, x0, 16")
    assert words("addi x1, x0, 0b101") == words("addi x1, x0, 5")
    assert words("addi x1, x0, -0x800") == words("addi x1, x0, -2048")
    assert words("lui x1, 0xF_FFFF") == words("lui x1, 1048575")


def test_memory_operand_without_offset():
    assert words("lw x1, (x2)") == words("lw x1, 0(x2)")
    assert words("sw x1, (sp)") == words("sw x1, 0(x2)")


def test_jalr_operand_forms():
    base = words("jalr x1, 0(x5)")
    assert words("jalr x1, x5, 0") == base
    assert words("jalr x1, x5") == base
    assert words("jalr x5") == base                       # rd = ra
    assert words("jalr x0, x6, -8") == words("jalr x0, -8(x6)")


def test_jal_short_form_links_ra():
    assert words("x: jal x") == words("x: jal ra, x")


def test_numeric_branch_offset_is_relative_to_pc():
    # un numero en un salto es el desplazamiento (PC += imm), no una direccion
    assert words("nop\nbeq x0, x0, -4") == words("a: nop\nbeq x0, x0, a")


def test_equ_constants():
    src = """
    .equ N, 10
    .set OFF, -4
    addi x1, x0, N
    lw x2, OFF(sp)
    """
    assert words(src) == words("addi x1, x0, 10\nlw x2, -4(sp)")


def test_equ_can_be_used_before_its_definition():
    assert words("addi x1, x0, N\n.equ N, 3") == words("addi x1, x0, 3")


def test_ignored_directives():
    assert words(".text\n.globl main\n.global main\nmain: nop") == [0x00000013]


def test_word_directive_values_and_labels():
    prog = assemble("nop\nfin: .word 0xdeadbeef, -1, 7, fin")
    assert prog.words == [0x00000013, 0xDEADBEEF, 0xFFFFFFFF, 7, 4]


# ---- pseudo-instrucciones -------------------------------------------------------
def test_simple_pseudos():
    assert words("nop") == words("addi x0, x0, 0")
    assert words("mv a0, a1") == words("addi a0, a1, 0")
    assert words("not t0, t1") == words("xori t0, t1, -1")
    assert words("neg t2, t3") == words("sub t2, x0, t3")
    assert words("x: j x") == words("x: jal x0, x")
    assert words("jr t0") == words("jalr x0, 0(t0)")
    assert words("ret") == words("jalr x0, 0(ra)")
    assert words("x: beqz a0, x") == words("x: beq a0, x0, x")
    assert words("x: bnez a0, x") == words("x: bne a0, x0, x")


def test_li_small_is_one_addi():
    assert words("li a0, 0") == words("addi a0, x0, 0")
    assert words("li a0, 2047") == words("addi a0, x0, 2047")
    assert words("li a0, -2048") == words("addi a0, x0, -2048")


def test_li_multiple_of_4096_is_one_lui():
    assert words("li a0, 0x10000") == words("lui a0, 0x10")
    assert words("li a0, 0x80000000") == words("lui a0, 0x80000")


def test_li_large_is_lui_plus_addi_like_gnu_as():
    # misma expansion que GNU as. LLVM elige a veces otra secuencia
    # equivalente (2048 -> addi + slli); el valor final es el mismo.
    assert words("li a1, 2048") == words("lui a1, 1\naddi a1, a1, -2048")
    assert words("li a2, 0x12345678") == words("lui a2, 0x12345\naddi a2, a2, 0x678")
    assert words("li a3, 0x7ffff800") == words("lui a3, 0x80000\naddi a3, a3, -2048")
    assert words("li a4, -2049") == words("lui a4, 0xfffff\naddi a4, a4, 2047")
    assert words("li a5, 0xffffffff") == words("addi a5, x0, -1")


def test_li_values_reconstruct_exactly():
    """Simula lui/addi y verifica que el registro termina con el valor pedido."""
    for value in [2048, 4095, 4096, 0x12345678, 0x7FFFFFFF, -0x80000000, -2049, 0x800, 0xFFFFF800]:
        prog = assemble(f"li x5, {value}")
        reg = 0
        for w in prog.words:
            opcode, imm_i = w & 0x7F, (w >> 20) - ((w >> 20 & 0x800) << 1)
            if opcode == 0b0110111:                      # lui
                reg = w & 0xFFFFF000
            else:                                        # addi
                rs1_val = reg if (w >> 15) & 0x1F == 5 else 0
                reg = (rs1_val + imm_i) & 0xFFFFFFFF
        assert reg == value & 0xFFFFFFFF, hex(value)


def test_li_size_shifts_following_labels():
    # li de dos palabras corre las direcciones siguientes
    prog = assemble("li a0, 0x12345678\nfin: halt")
    assert prog.labels["fin"] == 8


def test_source_map_points_to_lines():
    prog = assemble("# hola\nli a0, 0x12345678\n\nhalt")
    assert prog.source_map[0][0] == 2
    assert prog.source_map[4][0] == 2
    assert prog.source_map[8] == (4, "halt")


def test_to_bytes_is_little_endian():
    assert assemble("addi x1, x0, 5").to_bytes() == bytes([0x93, 0x00, 0x50, 0x00])
