"""Tablas del ISA soportado: registros e instrucciones.

Fuente: docs/spec/isa.md. Cada instruccion de esa tabla aparece aca con su
formato, opcode, funct3 y funct7; si la tabla cambia, se cambia solo este
archivo.
"""

from dataclasses import dataclass

# Palabra de HALT: ebreak (decision 001)
HALT_WORD = 0x0010_0073

# Tamano de la memoria de programa en palabras (memoria.md, IMEM_AW = 10)
IMEM_WORDS = 1024


# --------------------------------------------------------------------------
# Registros: x0..x31 y nombres ABI
# --------------------------------------------------------------------------
_ABI_NAMES = [
    "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
]

REGISTERS: dict[str, int] = {f"x{i}": i for i in range(32)}
REGISTERS.update({name: i for i, name in enumerate(_ABI_NAMES)})
REGISTERS["fp"] = 8  # alias de s0


# --------------------------------------------------------------------------
# Instrucciones
# --------------------------------------------------------------------------
# Formas de operandos (definen como se parsea la linea, no solo el formato):
#   R       rd, rs1, rs2
#   I       rd, rs1, imm12
#   SHIFT   rd, rs1, shamt          (I-type con funct7 en imm[11:5])
#   LOAD    rd, imm(rs1)            (I-type)
#   JALR    rd, imm(rs1) | rd, rs1, imm | rd, rs1 | rs1
#   S       rs2, imm(rs1)
#   B       rs1, rs2, destino
#   U       rd, imm20
#   J       rd, destino | destino
#   SYS     sin operandos           (halt / ebreak)
@dataclass(frozen=True)
class InstrSpec:
    form: str
    opcode: int
    funct3: int = 0
    funct7: int = 0


OP_R = 0b0110011
OP_I = 0b0010011
OP_LOAD = 0b0000011
OP_STORE = 0b0100011
OP_BRANCH = 0b1100011
OP_JALR = 0b1100111
OP_JAL = 0b1101111
OP_LUI = 0b0110111
OP_SYSTEM = 0b1110011

INSTRUCTIONS: dict[str, InstrSpec] = {
    # R-type
    "add":   InstrSpec("R", OP_R, 0b000, 0b0000000),
    "sub":   InstrSpec("R", OP_R, 0b000, 0b0100000),
    "sll":   InstrSpec("R", OP_R, 0b001, 0b0000000),
    "slt":   InstrSpec("R", OP_R, 0b010, 0b0000000),
    "sltu":  InstrSpec("R", OP_R, 0b011, 0b0000000),
    "xor":   InstrSpec("R", OP_R, 0b100, 0b0000000),
    "srl":   InstrSpec("R", OP_R, 0b101, 0b0000000),
    "sra":   InstrSpec("R", OP_R, 0b101, 0b0100000),
    "or":    InstrSpec("R", OP_R, 0b110, 0b0000000),
    "and":   InstrSpec("R", OP_R, 0b111, 0b0000000),
    # I-type: loads
    "lb":    InstrSpec("LOAD", OP_LOAD, 0b000),
    "lh":    InstrSpec("LOAD", OP_LOAD, 0b001),
    "lw":    InstrSpec("LOAD", OP_LOAD, 0b010),
    "lbu":   InstrSpec("LOAD", OP_LOAD, 0b100),
    "lhu":   InstrSpec("LOAD", OP_LOAD, 0b101),
    # I-type: aritmeticas y logicas con inmediato
    "addi":  InstrSpec("I", OP_I, 0b000),
    "slti":  InstrSpec("I", OP_I, 0b010),
    "sltiu": InstrSpec("I", OP_I, 0b011),
    "xori":  InstrSpec("I", OP_I, 0b100),
    "ori":   InstrSpec("I", OP_I, 0b110),
    "andi":  InstrSpec("I", OP_I, 0b111),
    # I-type: desplazamientos con shamt
    "slli":  InstrSpec("SHIFT", OP_I, 0b001, 0b0000000),
    "srli":  InstrSpec("SHIFT", OP_I, 0b101, 0b0000000),
    "srai":  InstrSpec("SHIFT", OP_I, 0b101, 0b0100000),
    # saltos incondicionales
    "jalr":  InstrSpec("JALR", OP_JALR, 0b000),
    "jal":   InstrSpec("J", OP_JAL),
    # S-type
    "sb":    InstrSpec("S", OP_STORE, 0b000),
    "sh":    InstrSpec("S", OP_STORE, 0b001),
    "sw":    InstrSpec("S", OP_STORE, 0b010),
    # B-type
    "beq":   InstrSpec("B", OP_BRANCH, 0b000),
    "bne":   InstrSpec("B", OP_BRANCH, 0b001),
    # U-type
    "lui":   InstrSpec("U", OP_LUI),
    # HALT = ebreak (decision 001)
    "halt":   InstrSpec("SYS", OP_SYSTEM),
    "ebreak": InstrSpec("SYS", OP_SYSTEM),
}

# Pseudo-instrucciones: se expanden a instrucciones de la tabla anterior.
# Solo se incluyen las que no necesitan instrucciones fuera del ISA
# (no hay auipc, blt, bge, ...). El valor es la cantidad de operandos.
PSEUDO_INSTRUCTIONS: dict[str, int] = {
    "nop": 0,   # addi x0, x0, 0
    "mv": 2,    # addi rd, rs, 0
    "not": 2,   # xori rd, rs, -1
    "neg": 2,   # sub rd, x0, rs
    "li": 2,    # addi rd, x0, imm  |  lui rd, hi (+ addi rd, rd, lo)
    "j": 1,     # jal x0, destino
    "jr": 1,    # jalr x0, 0(rs)
    "ret": 0,   # jalr x0, 0(ra)
    "beqz": 2,  # beq rs, x0, destino
    "bnez": 2,  # bne rs, x0, destino
}

# Instrucciones RV32I que no estan en isa.md: se reconocen solo para dar
# un mensaje mas claro que "instruccion desconocida".
UNSUPPORTED_RV32I = {
    "auipc", "blt", "bge", "bltu", "bgeu", "ecall", "fence", "fence.i",
    "csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci",
    # pseudo-instrucciones estandar que se expanden a algo de la lista
    "la", "call", "tail", "bgt", "ble", "bgtu", "bleu", "bltz", "bgez",
    "blez", "bgtz",
}
