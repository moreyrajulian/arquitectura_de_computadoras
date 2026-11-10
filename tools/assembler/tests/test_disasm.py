"""Desensamblador (I-51, decision 034).

El texto esperado de cada instruccion se escribe a mano desde isa.md. La ida y
vuelta (ensamblar -> desensamblar -> ensamblar da las mismas palabras) corre
sobre los programas de sw/ y de tests/programs/, y sobre palabras de isa.md al
azar armadas desde sus campos. Que el modelo y classify decodifican igual cada palabra lo prueba
tools/isasim/tests/test_isa.py (test_decode_agrees_with_assembler_classify).
"""

import random
import subprocess
import sys

import pytest
from conftest import ASSEMBLER_DIR, REPO_ROOT

from rvasm import AssemblerError, assemble, classify, disassemble
from rvasm.isa import INSTRUCTIONS, SUPPORTED

# Una linea por instruccion de isa.md y el texto que tiene que dar. La fuente usa
# nombres ABI, pseudos y las otras formas de operandos; la salida tiene una sola
# forma. Los inmediatos van a los extremos del rango y los saltos, hacia atras y
# hacia adelante hasta los limites de los formatos B y J.
EXPECTED = {
    "add":   ("add ra, sp, gp",      "add x1, x2, x3"),
    "sub":   ("sub t6, t5, t4",      "sub x31, x30, x29"),
    "sll":   ("sll x1, x2, x3",      "sll x1, x2, x3"),
    "slt":   ("slt a0, a1, a2",      "slt x10, x11, x12"),
    "sltu":  ("sltu x1, x2, x3",     "sltu x1, x2, x3"),
    "xor":   ("xor x1, x2, x3",      "xor x1, x2, x3"),
    "srl":   ("srl x1, x2, x3",      "srl x1, x2, x3"),
    "sra":   ("sra x1, x2, x3",      "sra x1, x2, x3"),
    "or":    ("or x1, x2, x3",       "or x1, x2, x3"),
    "and":   ("and x1, x2, x3",      "and x1, x2, x3"),
    "lb":    ("lb x1, -1(x2)",       "lb x1, -1(x2)"),
    "lh":    ("lh x1, -2048(x2)",    "lh x1, -2048(x2)"),
    "lw":    ("lw a0, (sp)",         "lw x10, 0(x2)"),
    "lbu":   ("lbu x1, 2047(x2)",    "lbu x1, 2047(x2)"),
    "lhu":   ("lhu x1, 2(x2)",       "lhu x1, 2(x2)"),
    "addi":  ("addi x1, x2, -2048",  "addi x1, x2, -2048"),
    "slti":  ("slti x1, x2, 2047",   "slti x1, x2, 2047"),
    "sltiu": ("sltiu x1, x2, -1",    "sltiu x1, x2, -1"),
    "xori":  ("not x1, x2",          "xori x1, x2, -1"),
    "ori":   ("ori x1, x2, 0x7ff",   "ori x1, x2, 2047"),
    "andi":  ("andi x1, x2, -1",     "andi x1, x2, -1"),
    "slli":  ("slli x1, x2, 0",      "slli x1, x2, 0"),
    "srli":  ("srli x1, x2, 31",     "srli x1, x2, 31"),
    "srai":  ("srai x1, x2, 31",     "srai x1, x2, 31"),
    "jalr":  ("ret",                 "jalr x0, 0(x1)"),
    "jal":   ("jal x1, -1048576",    "jal x1, -1048576"),
    "sb":    ("sb x1, -1(x2)",       "sb x1, -1(x2)"),
    "sh":    ("sh x1, 2047(x2)",     "sh x1, 2047(x2)"),
    "sw":    ("sw a0, 0(zero)",      "sw x10, 0(x0)"),
    "beq":   ("beq x1, x2, -4096",   "beq x1, x2, -4096"),
    "bne":   ("bnez x1, 4092",       "bne x1, x0, +4092"),
    "lui":   ("lui x1, 0xfffff",     "lui x1, 0xFFFFF"),
    "halt":  ("ebreak",              "halt"),
}

PROGRAMS = (sorted((REPO_ROOT / "sw").glob("*.s"))
            + sorted((ASSEMBLER_DIR / "tests" / "programs").glob("*.s")))


def _word(line: str) -> int:
    return assemble(line).words[0]


def _round_trip(words: list[int]) -> list[int]:
    """Desensambla cada palabra en una linea y vuelve a ensamblar el texto."""
    text = "\n".join(disassemble(w) for w in words)
    return assemble(text, "<desensamblado>").words


def test_expected_covers_isa():
    # ebreak es otro nombre de halt: la misma palabra
    assert set(EXPECTED) == set(INSTRUCTIONS) - {"ebreak"}


@pytest.mark.parametrize("name", EXPECTED)
def test_every_isa_instruction(name):
    line, text = EXPECTED[name]
    word = _word(line)
    assert classify(word).name == name
    assert disassemble(word) == text
    assert _round_trip([word]) == [word]


@pytest.mark.parametrize("line,text", [
    ("nop", "nop"),                          # 0x00000013, como en objdump
    ("addi x0, x0, 0", "nop"),
    ("addi x0, x0, 1", "addi x0, x0, 1"),    # otra escritura a x0 no es nop
    ("lui x1, 0", "lui x1, 0x0"),
    ("jal x0, 1048572", "jal x0, +1048572"),
    ("j 8", "jal x0, +8"),
    ("jal 0", "jal x1, +0"),
    ("jalr x1, x2, -4", "jalr x1, -4(x2)"),
    ("jr t0", "jalr x0, 0(x5)"),
    ("mv a0, a1", "addi x10, x11, 0"),
    ("neg a0, a1", "sub x10, x0, x11"),
])
def test_pseudos_and_operand_forms(line, text):
    assert disassemble(_word(line)) == text


def test_branch_back_to_label_gives_offset():
    words = assemble("bucle: addi x1, x1, 1\n"
                     "       bne  x1, x2, bucle\n"
                     "       beq  x0, x0, fin\n"
                     "       nop\n"
                     "fin:   halt").words
    assert [disassemble(w) for w in words] == [
        "addi x1, x1, 1", "bne x1, x2, -4", "beq x0, x0, +8", "nop", "halt"]


@pytest.mark.parametrize("program", PROGRAMS, ids=[f"{p.parent.name}/{p.name}" for p in PROGRAMS])
def test_round_trip_program(program):
    words = assemble(program.read_text(encoding="utf-8"), program.name).words
    assert _round_trip(words) == words


def _random_isa_words(count: int, seed: int) -> list[int]:
    """Palabras de isa.md al azar: opcode, funct3 y funct7 de la tabla, el resto al azar."""
    rng = random.Random(seed)
    specs = [spec for name, spec in INSTRUCTIONS.items() if spec.form != "SYS"]
    words = []
    for _ in range(count):
        spec = rng.choice(specs)
        word = (rng.getrandbits(25) << 7) | spec.opcode
        if spec.form not in ("U", "J"):
            word = (word & ~(0b111 << 12)) | (spec.funct3 << 12)
        if spec.form in ("R", "SHIFT"):
            word = (word & ~(0x7F << 25)) | (spec.funct7 << 25)
        words.append(word)
    return words


def test_round_trip_random_words():
    # incluye los saltos con desplazamiento no multiplo de 4 (la mitad de los B y J)
    words = _random_isa_words(10_000, seed=51)
    assert {classify(w).name for w in words} == set(INSTRUCTIONS) - {"ebreak", "halt"}
    for i in range(0, len(words), 1000):          # un programa tiene a lo sumo 1024
        chunk = words[i:i + 1000]
        assert _round_trip(chunk) == chunk


@pytest.mark.parametrize("line,bit,text", [
    ("beq x1, x2, 0", 8, "beq x1, x2, +2"),
    ("bne x1, x2, -4", 8, "bne x1, x2, -2"),
    ("jal x0, 0", 21, "jal x0, +2"),
])
def test_jump_offset_not_multiple_of_4(line, bit, text):
    # Es una palabra de isa.md (el hardware salta a un PC desalineado, memoria.md
    # 6.1), pero rvasm no acepta ese desplazamiento en la fuente: sale como .word
    word = _word(line) | (1 << bit)         # imm[1] es instr[8] en B e instr[21] en J
    assert classify(word).kind == SUPPORTED
    assert disassemble(word) == f".word 0x{word:08X}  # {text}: desplazamiento no multiplo de 4"
    with pytest.raises(AssemblerError, match="no es multiplo de 4"):
        assemble(text)
    assert _round_trip([word]) == [word]


@pytest.mark.parametrize("word,reason", [
    (0x0000_0000, "opcode 0000000 fuera de la tabla; el hardware la ejecuta como NOP"),
    (0x0000_0097, "opcode 0010111 fuera de la tabla; el hardware la ejecuta como NOP"),  # auipc
    (0x0000_0073, "palabra SYSTEM distinta de halt; el hardware la ejecuta como NOP"),   # ecall
    (0x0020_C063, "branch con funct3 = 100; resultado no especificado"),                # blt
    (0x0220_80B3, "tipo R con funct3 = 000 y funct7 = 0000001; resultado no especificado"),  # mul
])
def test_word_outside_isa(word, reason):
    # El modelo termina en error con las de resultado no especificado; aca no
    text = disassemble(word)
    assert text == f".word 0x{word:08X}  # fuera de isa.md: {reason}"
    with pytest.raises(AssemblerError, match="no es una instruccion de isa.md"):
        assemble(text)


@pytest.mark.parametrize("word", [-1, 1 << 32])
def test_word_wider_than_32_bits(word):
    with pytest.raises(ValueError, match="32 bits"):
        disassemble(word)


def test_import_rvasm_does_not_load_the_model():
    # El ensamblador sigue sin depender del modelo: isasim se carga al desensamblar
    code = ("import sys, rvasm\n"
            "assert 'isasim' not in sys.modules\n"
            "assert rvasm.disassemble(0x00500093) == 'addi x1, x0, 5'\n"
            "assert 'isasim' in sys.modules\n")
    subprocess.run([sys.executable, "-c", code], cwd=ASSEMBLER_DIR, check=True)
