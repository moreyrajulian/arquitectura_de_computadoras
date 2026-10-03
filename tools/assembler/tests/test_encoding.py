"""Codificacion de cada instruccion contra valores esperados independientes.

Los valores esperados NO salen de rvasm: se obtuvieron ensamblando las mismas
lineas con LLVM (clang de zig 0.16, -mcpu=generic_rv32) y se copiaron aca.
Cubren todas las instrucciones de isa.md, inmediatos negativos, extremos de
rango y saltos hacia adelante y hacia atras.
"""

import re

import pytest
from conftest import REPO_ROOT

from rvasm import HALT_WORD, assemble
from rvasm.isa import INSTRUCTIONS


def word(line: str) -> int:
    program = assemble(line)
    assert len(program.words) == 1
    return program.words[0]


# (linea, palabra esperada segun LLVM)
CASES = [
    # R-type
    ("add x1, x2, x3", 0x003100B3),
    ("sub x5, x6, x7", 0x407302B3),
    ("sll x8, x9, x10", 0x00A49433),
    ("srl x11, x12, x13", 0x00D655B3),
    ("sra x14, x15, x16", 0x4107D733),
    ("and x17, x18, x19", 0x013978B3),
    ("or x20, x21, x22", 0x016AEA33),
    ("xor x23, x24, x25", 0x019C4BB3),
    ("slt x26, x27, x28", 0x01CDAD33),
    ("sltu x29, x30, x31", 0x01FF3EB3),
    # loads
    ("lb x1, 0(x2)", 0x00010083),
    ("lh x3, -2(x4)", 0xFFE21183),
    ("lw x5, -2048(x6)", 0x80032283),
    ("lbu x7, 2047(x8)", 0x7FF44383),
    ("lhu x9, 100(x10)", 0x06455483),
    # I-type aritmeticas y logicas
    ("addi x1, x0, 5", 0x00500093),
    ("addi x1, x1, -1", 0xFFF08093),
    ("addi x2, x2, -2048", 0x80010113),
    ("addi x3, x3, 2047", 0x7FF18193),
    ("andi x4, x5, -256", 0xF002F213),
    ("ori x6, x7, 0x555", 0x5553E313),
    ("xori x8, x9, -1", 0xFFF4C413),
    ("slti x10, x11, -5", 0xFFB5A513),
    ("sltiu x12, x13, 7", 0x0076B613),
    # desplazamientos
    ("slli x14, x15, 3", 0x00379713),
    ("srli x16, x17, 31", 0x01F8D813),
    ("srai x18, x19, 7", 0x4079D913),
    ("srai x20, x21, 31", 0x41FADA13),
    # jalr
    ("jalr x1, 0(x5)", 0x000280E7),
    ("jalr x0, -8(x6)", 0xFF830067),
    ("jalr x7, 2047(x8)", 0x7FF403E7),
    # stores (inmediato partido en imm[11:5] e imm[4:0])
    ("sb x1, 0(x2)", 0x00110023),
    ("sh x3, -1(x4)", 0xFE321FA3),
    ("sw x5, -2048(x6)", 0x80532023),
    ("sw x7, 2047(x8)", 0x7E742FA3),
    # U-type
    ("lui x1, 0x12345", 0x123450B7),
    ("lui x2, 0xfffff", 0xFFFFF137),
    ("lui x3, 0", 0x000001B7),
    # HALT (decision 001)
    ("ebreak", 0x00100073),
]


@pytest.mark.parametrize("line,expected", CASES, ids=[c[0] for c in CASES])
def test_instruction_encoding(line, expected):
    assert word(line) == expected


# Saltos con etiquetas, hacia atras y hacia adelante (valores de LLVM)
BRANCH_PROGRAM = """\
back:
  nop
  beq x1, x2, back
  bne x3, x4, back
  jal x1, back
  beq x5, x6, fwd
  bne x7, x8, fwd
  jal x0, fwd
  nop
fwd:
  nop
  beq x1, x2, 4092
  bne x1, x2, -4096
  jal x0, 1048572
  jal x0, -1048576
"""
BRANCH_EXPECTED = [
    0x00000013,
    0xFE208EE3,  # beq  -4  (hacia atras)
    0xFE419CE3,  # bne  -8  (hacia atras)
    0xFF5FF0EF,  # jal  -12 (hacia atras)
    0x00628863,  # beq  +16 (hacia adelante)
    0x00839663,  # bne  +12
    0x0080006F,  # jal  +8
    0x00000013,
    0x00000013,
    0x7E208EE3,  # beq  +4092     (maximo del formato B)
    0x80209063,  # bne  -4096     (minimo del formato B)
    0x7FDFF06F,  # jal  +1048572  (maximo del formato J)
    0x8000006F,  # jal  -1048576  (minimo del formato J)
]


def test_branches_forward_and_backward():
    assert assemble(BRANCH_PROGRAM).words == BRANCH_EXPECTED


def test_halt_is_ebreak():
    assert word("halt") == word("ebreak") == HALT_WORD == 0x00100073


def test_cases_cover_every_instruction():
    covered = {line.split()[0] for line, _ in CASES} | {"beq", "bne", "jal", "halt"}
    assert covered == set(INSTRUCTIONS)


def test_instruction_table_matches_isa_md():
    """isa.py tiene que coincidir con la tabla de docs/spec/isa.md (fuente de verdad)."""
    text = (REPO_ROOT / "docs" / "spec" / "isa.md").read_text(encoding="utf-8")
    rows = re.findall(r"^\|\s*([a-z]+)(?: \((\w+)\))?\s*\|[^|]*\|\s*([RISBUJ])-type\s*\|"
                      r"\s*([01]{7})\s*\|\s*([01]{3}|-)\s*\|\s*([01]{7}|-)\s*\|", text, re.M)
    assert len(rows) >= 33, "no se pudo leer la tabla de isa.md"
    table = {}
    for name, alias, _fmt, opcode, f3, f7 in rows:
        entry = (int(opcode, 2), int(f3, 2) if f3 != "-" else 0, int(f7, 2) if f7 != "-" else 0)
        table[name] = entry
        if alias:
            table[alias] = entry
    assert set(table) == set(INSTRUCTIONS)
    for name, (opcode, f3, f7) in table.items():
        spec = INSTRUCTIONS[name]
        assert (spec.opcode, spec.funct3) == (opcode, f3), name
        if spec.form in ("R", "SHIFT"):
            assert spec.funct7 == f7, name
