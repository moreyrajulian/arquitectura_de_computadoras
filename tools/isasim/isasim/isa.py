"""Capa 1: semántica de la ISA, instrucción por instrucción.

Ejecuta las instrucciones de docs/spec/isa.md sin saber nada del pipeline: es la
referencia de *qué* tiene que pasar. La decodificación se escribe acá a partir de
isa.md y no usa las tablas del ensamblador (rvasm), para que un error de
codificación no quede escondido en los dos lados (verificacion.md §2).

Comportamiento de memoria: docs/spec/memoria.md §5 y §6 (little-endian, alias de
direcciones y accesos desalineados sin excepción, con avisos persistentes).
"""

from dataclasses import dataclass, field

MASK32 = 0xFFFF_FFFF
HALT_WORD = 0x0010_0073          # ebreak (decisión 001)
NOP_WORD = 0x0000_0013           # addi x0, x0, 0
IMEM_WORDS = 1024                # memoria.md §1
DMEM_WORDS = 1024
MEM_BYTES = 4 * DMEM_WORDS       # 0x1000

OP_R = 0b0110011
OP_I = 0b0010011
OP_LOAD = 0b0000011
OP_STORE = 0b0100011
OP_BRANCH = 0b1100011
OP_JAL = 0b1101111
OP_JALR = 0b1100111
OP_LUI = 0b0110111
OP_SYSTEM = 0b1110011

# (funct3, funct7) -> nombre, según la tabla de isa.md
R_OPS = {
    (0b000, 0x00): "add", (0b000, 0x20): "sub", (0b001, 0x00): "sll",
    (0b101, 0x00): "srl", (0b101, 0x20): "sra", (0b111, 0x00): "and",
    (0b110, 0x00): "or", (0b100, 0x00): "xor", (0b010, 0x00): "slt",
    (0b011, 0x00): "sltu",
}
I_OPS = {0b000: "addi", 0b111: "andi", 0b110: "ori", 0b100: "xori",
         0b010: "slti", 0b011: "sltiu"}
SHIFT_OPS = {(0b001, 0x00): "slli", (0b101, 0x00): "srli", (0b101, 0x20): "srai"}
LOAD_OPS = {0b000: "lb", 0b001: "lh", 0b010: "lw", 0b100: "lbu", 0b101: "lhu"}
STORE_OPS = {0b000: "sb", 0b001: "sh", 0b010: "sw"}
BRANCH_OPS = {0b000: "beq", 0b001: "bne"}

ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1",
       "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
       "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"]


class ModelError(Exception):
    """El programa no se puede ejecutar o el modelo encontró una inconsistencia."""


def sext(value, bits):
    """Extiende con signo un valor de `bits` bits a 32 bits."""
    value &= (1 << bits) - 1
    if value >> (bits - 1):
        value -= 1 << bits
    return value & MASK32


def signed(value):
    return value - (1 << 32) if value & 0x8000_0000 else value


def field_(word, hi, lo):
    return (word >> lo) & ((1 << (hi - lo + 1)) - 1)


@dataclass(frozen=True)
class Instr:
    """Instrucción decodificada según isa.md."""

    word: int
    name: str        # mnemónico de isa.md, "halt" o "no_reconocida"
    kind: str        # R, I, SHIFT, LOAD, STORE, BRANCH, JAL, JALR, LUI, HALT, NONE
    rd: int
    rs1: int
    rs2: int
    funct3: int
    imm: int         # inmediato de 32 bits (shamt en los desplazamientos con inmediato)

    @property
    def reads_rs1(self):
        return self.kind in ("R", "I", "SHIFT", "LOAD", "STORE", "BRANCH", "JALR")

    @property
    def reads_rs2(self):
        return self.kind in ("R", "STORE", "BRANCH")

    @property
    def writes_rd(self):
        return self.kind in ("R", "I", "SHIFT", "LOAD", "JAL", "JALR", "LUI")

    def __str__(self):
        return disassemble(self)


def decode(word):
    """Decodifica una palabra. Las que no están en isa.md se comportan como NOP
    solo si su opcode no es de ninguna familia del procesador (pipeline.md §4.4);
    una palabra con opcode conocido y funct3/funct7 fuera de isa.md es un error,
    porque el hardware la ejecutaría según su opcode y no como NOP."""
    word &= MASK32
    opcode = word & 0x7F
    rd = field_(word, 11, 7)
    funct3 = field_(word, 14, 12)
    rs1 = field_(word, 19, 15)
    rs2 = field_(word, 24, 20)
    funct7 = field_(word, 31, 25)
    imm_i = sext(field_(word, 31, 20), 12)
    imm_s = sext((field_(word, 31, 25) << 5) | field_(word, 11, 7), 12)
    imm_b = sext((field_(word, 31, 31) << 12) | (field_(word, 7, 7) << 11)
                 | (field_(word, 30, 25) << 5) | (field_(word, 11, 8) << 1), 13)
    imm_u = word & 0xFFFF_F000
    imm_j = sext((field_(word, 31, 31) << 20) | (field_(word, 19, 12) << 12)
                 | (field_(word, 20, 20) << 11) | (field_(word, 30, 21) << 1), 21)

    def make(name, kind, imm=0):
        return Instr(word, name, kind, rd, rs1, rs2, funct3, imm)

    def invalid(what):
        raise ModelError(f"palabra 0x{word:08X}: {what} fuera de isa.md; el hardware la "
                         f"ejecutaría según su opcode (pipeline.md §4.4), no como NOP")

    if word == HALT_WORD:
        return make("halt", "HALT")
    if opcode == OP_R:
        name = R_OPS.get((funct3, funct7)) or invalid("tipo R con funct3/funct7")
        return make(name, "R")
    if opcode == OP_I:
        if funct3 in (0b001, 0b101):
            name = SHIFT_OPS.get((funct3, funct7)) or invalid("desplazamiento con funct7")
            return make(name, "SHIFT", rs2)            # shamt = instr[24:20]
        return make(I_OPS[funct3], "I", imm_i)
    if opcode == OP_LOAD:
        name = LOAD_OPS.get(funct3) or invalid("load con funct3")
        return make(name, "LOAD", imm_i)
    if opcode == OP_STORE:
        name = STORE_OPS.get(funct3) or invalid("store con funct3")
        return make(name, "STORE", imm_s)
    if opcode == OP_BRANCH:
        name = BRANCH_OPS.get(funct3) or invalid("branch con funct3")
        return make(name, "BRANCH", imm_b)
    if opcode == OP_JAL:
        return make("jal", "JAL", imm_j)
    if opcode == OP_JALR:
        if funct3 != 0:
            invalid("jalr con funct3")
        return make("jalr", "JALR", imm_i)
    if opcode == OP_LUI:
        return make("lui", "LUI", imm_u)
    # ecall, csr*, palabras en cero y opcodes fuera del subconjunto: sin efecto
    return make("no_reconocida", "NONE")


def disassemble(ins):
    r = lambda n: f"x{n}"                                   # noqa: E731
    k = ins.kind
    if k == "R":
        return f"{ins.name} {r(ins.rd)}, {r(ins.rs1)}, {r(ins.rs2)}"
    if k in ("I", "SHIFT"):
        return f"{ins.name} {r(ins.rd)}, {r(ins.rs1)}, {signed(ins.imm)}"
    if k == "LOAD":
        return f"{ins.name} {r(ins.rd)}, {signed(ins.imm)}({r(ins.rs1)})"
    if k == "STORE":
        return f"{ins.name} {r(ins.rs2)}, {signed(ins.imm)}({r(ins.rs1)})"
    if k == "BRANCH":
        return f"{ins.name} {r(ins.rs1)}, {r(ins.rs2)}, {signed(ins.imm):+d}"
    if k == "JAL":
        return f"jal {r(ins.rd)}, {signed(ins.imm):+d}"
    if k == "JALR":
        return f"jalr {r(ins.rd)}, {signed(ins.imm)}({r(ins.rs1)})"
    if k == "LUI":
        return f"lui {r(ins.rd)}, 0x{ins.imm >> 12:X}"
    if k == "HALT":
        return "halt"
    return "nop" if ins.word == NOP_WORD else f".word 0x{ins.word:08X}"


@dataclass
class Effect:
    """Lo que hizo una instrucción ejecutada (una fila de la traza por instrucción)."""

    seq: int
    pc: int
    instr: Instr
    rs1_val: int = 0          # valores de arquitectura de los registros que nombra
    rs2_val: int = 0          # cada campo, antes de ejecutar
    reg_write: tuple | None = None    # (rd, valor) si escribe un registro distinto de x0
    mem_addr: int | None = None       # dirección efectiva de un load o store
    store: tuple | None = None        # (índice de palabra, palabra después del store)
    taken: bool = False               # cambió el flujo (branch tomado, jal, jalr)
    next_pc: int = 0


@dataclass
class IsaState:
    regs: list = field(default_factory=lambda: [0] * 32)
    dmem: list = field(default_factory=lambda: [0] * DMEM_WORDS)
    used: set = field(default_factory=set)          # palabras escritas (decisión 005)
    imem_fault: bool = False
    dmem_oob: bool = False
    dmem_misaligned: bool = False
    halted: bool = False
    pc: int = 0


class IsaSim:
    """Ejecuta un programa instrucción por instrucción.

    `delay_slots = 2` reproduce el pipeline **sin flush** (M7): las dos
    instrucciones que siguen a un salto tomado se ejecutan antes del destino.
    """

    def __init__(self, imem, regs=None, dmem=None, delay_slots=0):
        if len(imem) != IMEM_WORDS:
            raise ModelError(f"la memoria de programa tiene que tener {IMEM_WORDS} palabras")
        self.imem = [w & MASK32 for w in imem]
        self.state = IsaState()
        if regs:
            self.state.regs = [v & MASK32 for v in regs]
        if dmem:
            self.state.dmem = [v & MASK32 for v in dmem]
        self.state.regs[0] = 0
        self.delay_slots = delay_slots
        self._pending = []        # direcciones que siguen, cuando hay huecos de salto
        self.effects = []

    def fetch(self, pc):
        if pc >= MEM_BYTES or pc & 0b11:
            self.state.imem_fault = True             # memoria.md §6.1
        return self.imem[(pc >> 2) % IMEM_WORDS]

    def step(self):
        s = self.state
        pc = s.pc
        ins = decode(self.fetch(pc))
        a, b = s.regs[ins.rs1], s.regs[ins.rs2]
        eff = Effect(len(self.effects), pc, ins, a, b)
        target, value = None, None
        k = ins.kind

        if k == "R":
            value = alu_op(ins.name, a, b)
        elif k == "I":
            value = alu_op(ins.name[:-1] if ins.name != "sltiu" else "sltu", a, ins.imm)
        elif k == "SHIFT":
            value = alu_op(ins.name[:-1], a, ins.imm)
        elif k == "LUI":
            value = ins.imm
        elif k == "LOAD":
            addr = (a + ins.imm) & MASK32
            eff.mem_addr = addr
            word = s.dmem[self._dmem_index(addr, ins.funct3)]
            value = load_value(ins.name, word, addr)
        elif k == "STORE":
            addr = (a + ins.imm) & MASK32
            eff.mem_addr = addr
            idx = self._dmem_index(addr, ins.funct3)
            s.dmem[idx] = store_word(ins.name, s.dmem[idx], b, addr)
            s.used.add(idx)
            eff.store = (idx, s.dmem[idx])
        elif k == "BRANCH":
            if (a == b) == (ins.name == "beq"):
                target = (pc + ins.imm) & MASK32
        elif k == "JAL":
            value, target = (pc + 4) & MASK32, (pc + ins.imm) & MASK32
        elif k == "JALR":
            value, target = (pc + 4) & MASK32, (a + ins.imm) & MASK32 & ~1
        elif k == "HALT":
            s.halted = True

        if ins.writes_rd and ins.rd != 0:
            s.regs[ins.rd] = value
            eff.reg_write = (ins.rd, value)
        s.regs[0] = 0

        eff.taken = target is not None
        if self._pending:                       # estoy en un hueco de salto (modo sin flush)
            if eff.taken:
                raise ModelError(f"pc 0x{pc:08X}: salto tomado en el hueco de otro salto; "
                                 "sin flush el comportamiento no está definido")
            s.pc = self._pending.pop(0)
        elif eff.taken and self.delay_slots:
            self._pending = [(pc + 4 * i) & MASK32 for i in range(2, self.delay_slots + 1)]
            self._pending.append(target)
            s.pc = (pc + 4) & MASK32
        else:
            s.pc = target if eff.taken else (pc + 4) & MASK32
        eff.next_pc = s.pc
        self.effects.append(eff)
        return eff

    def _dmem_index(self, addr, funct3):
        s = self.state
        if addr >= MEM_BYTES:
            s.dmem_oob = True
        size = funct3 & 0b11
        if (size == 0b01 and addr & 1) or (size == 0b10 and addr & 0b11):
            s.dmem_misaligned = True
        return (addr >> 2) % DMEM_WORDS

    def run(self, max_instructions=100_000):
        while not self.state.halted and len(self.effects) < max_instructions:
            self.step()
        return self.effects


def alu_op(op, a, b):
    """Operaciones de isa.md sobre valores de 32 bits."""
    if op == "add":
        return (a + b) & MASK32
    if op == "sub":
        return (a - b) & MASK32
    if op == "sll":
        return (a << (b & 31)) & MASK32
    if op == "srl":
        return a >> (b & 31)
    if op == "sra":
        return (signed(a) >> (b & 31)) & MASK32
    if op == "and":
        return a & b
    if op == "or":
        return a | b
    if op == "xor":
        return a ^ b
    if op == "slt":
        return int(signed(a) < signed(b))
    if op == "sltu":
        return int(a < b)
    raise ModelError(f"operación desconocida {op}")


def load_value(name, word, addr):
    """Parte de la palabra que lee cada load, extendida (little-endian, memoria.md §5)."""
    if name == "lw":
        return word
    if name in ("lh", "lhu"):
        half = (word >> (16 * ((addr >> 1) & 1))) & 0xFFFF
        return sext(half, 16) if name == "lh" else half
    byte = (word >> (8 * (addr & 0b11))) & 0xFF
    return sext(byte, 8) if name == "lb" else byte


def store_word(name, old, data, addr):
    """Palabra después de un store (los bytes vecinos no cambian)."""
    if name == "sw":
        return data & MASK32
    if name == "sh":
        shift = 16 * ((addr >> 1) & 1)
        return (old & ~(0xFFFF << shift) & MASK32) | ((data & 0xFFFF) << shift)
    shift = 8 * (addr & 0b11)
    return (old & ~(0xFF << shift) & MASK32) | ((data & 0xFF) << shift)
