"""Capa 1: semántica de isa.md y casos borde que pide la issue I-16.

Cada valor esperado se calcula a mano desde isa.md, no con el modelo.
"""

import pytest

from isasim import ModelError, decode
from isasim.isa import HALT_WORD, IsaSim

from isasim_testutil import words_of


def regs_after(source, regs=None, dmem=None):
    sim = IsaSim(words_of(source), regs, dmem)
    sim.run()
    return sim.state


# ---- x0 -------------------------------------------------------------------------------

def test_x0_ignores_writes_and_reads_zero():
    s = regs_after("addi x0, x0, 5\n add x1, x0, x0\n lui x0, 1\n jal x0, 4\n halt")
    assert s.regs[0] == 0 and s.regs[1] == 0


def test_load_to_x0_has_no_effect():
    s = regs_after("addi x1, x0, 7\n sw x1, 0(x0)\n lw x0, 0(x0)\n halt")
    assert s.regs[0] == 0


# ---- desbordes ------------------------------------------------------------------------

def test_add_wraps_around():
    s = regs_after("lui x1, 0x80000\n addi x1, x1, -1\n addi x2, x1, 1\n halt")
    assert s.regs[1] == 0x7FFF_FFFF and s.regs[2] == 0x8000_0000      # máximo + 1 = mínimo


def test_sub_wraps_around():
    s = regs_after("lui x1, 0x80000\n addi x2, x0, 1\n sub x3, x1, x2\n halt")
    assert s.regs[3] == 0x7FFF_FFFF                                    # mínimo - 1 = máximo


# ---- desplazamientos ------------------------------------------------------------------

def test_sra_replicates_sign_and_srl_inserts_zeros():
    s = regs_after("addi x1, x0, -16\n srai x2, x1, 2\n srli x3, x1, 2\n"
                   " addi x4, x0, 4\n sra x5, x1, x4\n srl x6, x1, x4\n halt")
    assert s.regs[2] == 0xFFFF_FFFC          # -16 >> 2 = -4
    assert s.regs[3] == 0x3FFF_FFFC
    assert s.regs[5] == 0xFFFF_FFFF          # -16 >> 4 = -1
    assert s.regs[6] == 0x0FFF_FFFF


def test_shift_amount_uses_only_five_bits():
    s = regs_after("addi x1, x0, 1\n addi x2, x0, 33\n sll x3, x1, x2\n halt")
    assert s.regs[3] == 2                    # 33 & 31 = 1


# ---- comparaciones con y sin signo ----------------------------------------------------

def test_slt_versus_sltu():
    s = regs_after("addi x1, x0, -1\n addi x2, x0, 1\n"
                   " slt x3, x1, x2\n sltu x4, x1, x2\n halt")
    assert s.regs[3] == 1                    # -1 < 1
    assert s.regs[4] == 0                    # 0xFFFFFFFF < 1 es falso


def test_sltiu_sign_extends_immediate_then_compares_unsigned():
    s = regs_after("addi x1, x0, 5\n sltiu x2, x1, -1\n sltiu x3, x0, 1\n halt")
    assert s.regs[2] == 1                    # 5 <u 0xFFFFFFFF
    assert s.regs[3] == 1                    # sltiu rd, rs, 1 = (rs == 0)


# ---- loads con y sin signo, little-endian ---------------------------------------------

@pytest.mark.parametrize("ins, expected", [
    ("lb  x2, 1(x0)", 0xFFFF_FFBE), ("lbu x2, 1(x0)", 0x0000_00BE),
    ("lh  x2, 2(x0)", 0xFFFF_DEAD), ("lhu x2, 2(x0)", 0x0000_DEAD),
    ("lw  x2, 0(x0)", 0xDEAD_BEEF), ("lb  x2, 0(x0)", 0xFFFF_FFEF),
])
def test_loads_match_memoria_md_examples(ins, expected):
    dmem = [0xDEAD_BEEF] + [0] * 1023                  # memoria.md §5
    assert regs_after(f"{ins}\n halt", dmem=dmem).regs[2] == expected


def test_byte_and_half_stores_keep_neighbours():
    dmem = [0xDEAD_BEEF] + [0] * 1023
    s = regs_after("addi x1, x0, 0x12\n sb x1, 2(x0)\n halt", dmem=dmem)
    assert s.dmem[0] == 0xDE12_BEEF
    s = regs_after("lui x1, 3\n addi x1, x1, 0x456\n sh x1, 2(x0)\n halt", dmem=dmem)
    assert s.dmem[0] == 0x3456_BEEF


# ---- saltos -----------------------------------------------------------------------------

def test_backward_branch_loop():
    s = regs_after("addi x1, x0, 3\n"
                   "loop: addi x2, x2, 10\n addi x1, x1, -1\n bne x1, x0, loop\n halt")
    assert s.regs[2] == 30 and s.regs[1] == 0


def test_jal_and_jalr_link_and_clear_bit_zero():
    s = regs_after("jal x1, dest\n addi x5, x0, 99\n"           # 0x00, 0x04
                   "dest: addi x6, x0, 0x15\n jalr x7, 0(x6)\n"  # 0x08, 0x0C
                   " addi x9, x0, 1\n addi x8, x0, 1\n halt")    # 0x10, 0x14, 0x18
    assert s.regs[1] == 4                    # dirección de retorno
    assert s.regs[5] == 0                    # no se ejecutó
    assert s.regs[7] == 16                   # jalr en pc 0x0C: PC + 4
    assert s.regs[9] == 0                    # (0x15 + 0) & ~1 = 0x14: saltea 0x10
    assert s.regs[8] == 1


# ---- memoria: alias y desalineados (memoria.md §6.1) ----------------------------------

def test_misaligned_and_out_of_range_set_flags_and_alias():
    s = regs_after("addi x1, x0, 7\n sw x1, 4(x0)\n lw x2, 6(x0)\n"
                   " lui x3, 1\n lw x4, 4(x3)\n halt")
    assert s.regs[2] == 7 and s.dmem_misaligned            # lee la palabra 0x004
    assert s.regs[4] == 7 and s.dmem_oob                   # 0x1004 cae en 0x004


# ---- decodificación ---------------------------------------------------------------------

def test_halt_and_unknown_words():
    assert decode(HALT_WORD).kind == "HALT"
    assert decode(0x0000_0000).kind == "NONE"              # memoria vacía: NOP
    assert decode(0x0000_0073).kind == "NONE"              # ecall: NOP (pipeline.md §4.4)


def test_known_opcode_with_unsupported_funct_is_an_error():
    with pytest.raises(ModelError):
        decode(0x0020_C063)                                # blt x1, x2, 0
