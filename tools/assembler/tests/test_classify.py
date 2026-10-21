"""classify: que hace el hardware con cada palabra (decisiones 024 y 025).

Las palabras fuera de isa.md se arman a mano desde sus campos (isa.md, figura
de formatos), no con rvasm. Las de isa.md salen del ensamblador: lo que se
prueba es que toda palabra que rvasm genera se reconoce como su instruccion.
"""

import pytest

from rvasm import HALT_WORD, assemble, classify
from rvasm.isa import INSTRUCTIONS, SUPPORTED, UNRECOGNIZED, UNSPECIFIED

OP_R, OP_I, OP_LOAD, OP_STORE = 0b0110011, 0b0010011, 0b0000011, 0b0100011
OP_BRANCH, OP_JALR, OP_SYSTEM = 0b1100011, 0b1100111, 0b1110011


def fields(opcode: int, funct3: int = 0, funct7: int = 0, rd: int = 1, rs1: int = 2, rs2: int = 3) -> int:
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


# Una linea por instruccion de isa.md. Los inmediatos negativos llenan los bits
# donde iria funct7: un addi negativo no es un tipo R con funct7 = 1111111.
SUPPORTED_LINES = {
    "add": "add x1, x2, x3",
    "sub": "sub x31, x30, x29",
    "sll": "sll x1, x2, x3",
    "slt": "slt x1, x2, x3",
    "sltu": "sltu x1, x2, x3",
    "xor": "xor x1, x2, x3",
    "srl": "srl x1, x2, x3",
    "sra": "sra x1, x2, x3",
    "or": "or x1, x2, x3",
    "and": "and x1, x2, x3",
    "lb": "lb x1, -1(x2)",
    "lh": "lh x1, -2048(x2)",
    "lw": "lw x1, -4(x2)",
    "lbu": "lbu x1, -1(x2)",
    "lhu": "lhu x1, 2047(x2)",
    "addi": "addi x1, x2, -1",
    "slti": "slti x1, x2, -1",
    "sltiu": "sltiu x1, x2, -1",
    "xori": "xori x1, x2, -1",
    "ori": "ori x1, x2, -1",
    "andi": "andi x1, x2, -1",
    "slli": "slli x1, x2, 31",
    "srli": "srli x1, x2, 31",
    "srai": "srai x1, x2, 31",
    "jalr": "jalr x1, -1(x2)",
    "jal": "jal x1, -4",
    "sb": "sb x1, -1(x2)",
    "sh": "sh x1, -1(x2)",
    "sw": "sw x1, -1(x2)",
    "beq": "beq x1, x2, -4",
    "bne": "bne x1, x2, -4",
    "lui": "lui x1, 0xfffff",
    "halt": "halt",
}


def test_supported_lines_cover_isa():
    # ebreak es otro nombre de halt: la misma palabra
    assert set(SUPPORTED_LINES) == set(INSTRUCTIONS) - {"ebreak"}


@pytest.mark.parametrize("name,line", SUPPORTED_LINES.items())
def test_every_isa_instruction_is_supported(name, line):
    word = assemble(line).words[0]
    result = classify(word)
    assert (result.kind, result.name, result.reason) == (SUPPORTED, name, "")


def test_ebreak_is_halt():
    assert classify(HALT_WORD).name == "halt"
    assert classify(assemble("ebreak").words[0]).name == "halt"


@pytest.mark.parametrize("word,fragment", [
    (0x0000_0000, "opcode 0000000 fuera de la tabla"),       # memoria vacia
    (0xFFFF_FFFF, "opcode 1111111 fuera de la tabla"),
    (0x0000_0097, "opcode 0010111 fuera de la tabla"),       # auipc x1, 0
    (0x0000_000F, "opcode 0001111 fuera de la tabla"),       # fence
    (0x0000_0004, "opcode 0000100 fuera de la tabla"),       # una etiqueta: bits[1:0] = 00
    (0x0000_0073, "SYSTEM distinta de halt"),                # ecall
    (fields(OP_SYSTEM, 0b001), "SYSTEM distinta de halt"),   # csrrw
    (HALT_WORD | (1 << 7), "SYSTEM distinta de halt"),       # ebreak con rd = 1 (decision 001)
])
def test_unrecognized_words_are_nop(word, fragment):
    result = classify(word)
    assert result.kind == UNRECOGNIZED and result.name is None
    assert fragment in result.reason


@pytest.mark.parametrize("word,fragment", [
    (fields(OP_BRANCH, 0b100), "branch con funct3 = 100"),                       # blt
    (fields(OP_BRANCH, 0b111), "branch con funct3 = 111"),                       # bgeu
    (fields(OP_BRANCH, 0b010), "branch con funct3 = 010"),                       # reservado
    (fields(OP_R, 0b000, 0b0000001), "tipo R con funct3 = 000 y funct7 = 0000001"),  # mul
    (fields(OP_R, 0b111, 0b0100000), "tipo R con funct3 = 111 y funct7 = 0100000"),
    (fields(OP_I, 0b001, 0b0100000), "I aritmetica con funct3 = 001 y funct7 = 0100000"),
    (fields(OP_I, 0b101, 0b0000001), "I aritmetica con funct3 = 101 y funct7 = 0000001"),
    (fields(OP_LOAD, 0b011), "load con funct3 = 011"),
    (fields(OP_LOAD, 0b110), "load con funct3 = 110"),
    (fields(OP_LOAD, 0b111), "load con funct3 = 111"),
    (fields(OP_STORE, 0b011), "store con funct3 = 011"),
    (fields(OP_STORE, 0b111), "store con funct3 = 111"),
    (fields(OP_JALR, 0b001), "jalr con funct3 = 001"),
])
def test_known_opcode_with_unsupported_funct_is_unspecified(word, fragment):
    result = classify(word)
    assert result.kind == UNSPECIFIED and result.name is None
    assert fragment in result.reason


def test_only_opcode_funct3_and_funct7_matter():
    # rd, rs1 y rs2 no cambian la clase (pipeline.md 4.4 decodifica por opcode)
    for rd, rs1, rs2 in [(0, 0, 0), (31, 31, 31), (5, 17, 29)]:
        assert classify(fields(OP_R, 0b000, 0b0100000, rd, rs1, rs2)).name == "sub"
        assert classify(fields(OP_BRANCH, 0b100, 0, rd, rs1, rs2)).kind == UNSPECIFIED
