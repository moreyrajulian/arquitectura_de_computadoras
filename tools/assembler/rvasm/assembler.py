"""Ensamblador de dos pasadas para el subconjunto RV32I de docs/spec/isa.md.

Pasada 1: separa etiquetas, comentarios y sentencias, y asigna una direccion
a cada sentencia (todas ocupan un tamano conocido de antemano).
Pasada 2: con todas las etiquetas definidas, codifica cada sentencia.

Los errores no cortan el ensamblado: se acumulan con su numero de linea y al
final se lanza un unico AssemblerError con todos.
"""

import re
from dataclasses import dataclass, field

from .isa import (
    HALT_WORD,
    IMEM_WORDS,
    INSTRUCTIONS,
    PSEUDO_INSTRUCTIONS,
    REGISTERS,
    UNSUPPORTED_RV32I,
    InstrSpec,
)


# --------------------------------------------------------------------------
# Resultado y diagnosticos
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class Diagnostic:
    filename: str
    line: int
    message: str
    source: str = ""
    severity: str = "error"

    def __str__(self) -> str:
        text = f"{self.filename}:{self.line}: {self.severity}: {self.message}"
        if self.source.strip():
            text += f"\n    {self.line} | {self.source.strip()}"
        return text


class AssemblerError(Exception):
    """Uno o mas errores de ensamblado, cada uno con su linea."""

    def __init__(self, errors: list[Diagnostic]):
        self.errors = errors
        super().__init__("\n".join(str(e) for e in errors))


@dataclass
class Program:
    words: list[int]
    # direccion (en bytes) -> (numero de linea, texto de la linea)
    source_map: dict[int, tuple[int, str]]
    labels: dict[str, int]
    warnings: list[Diagnostic] = field(default_factory=list)

    def to_bytes(self) -> bytes:
        """Palabras en little-endian: el payload de LOAD (protocolo_debug.md 3.3)."""
        return b"".join(w.to_bytes(4, "little") for w in self.words)


class _LineError(Exception):
    """Error en una linea; el ensamblador le agrega archivo y numero."""


# --------------------------------------------------------------------------
# Lexico
# --------------------------------------------------------------------------
_LABEL_RE = re.compile(r"^\s*([A-Za-z_.$][\w.$]*)\s*:")
_SYMBOL_RE = re.compile(r"^[A-Za-z_.$][\w.$]*$")
_MEM_OPERAND_RE = re.compile(r"^(.*?)\(\s*([^()]*?)\s*\)$")
_INT_RE = re.compile(r"^([+-]?)\s*(0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*)$")


def _strip_comment(line: str) -> str:
    """Corta en el primer '#' o '//' (no hay strings en el lenguaje)."""
    cut = len(line)
    for marker in ("#", "//"):
        pos = line.find(marker)
        if pos != -1:
            cut = min(cut, pos)
    return line[:cut]


def _split_operands(text: str) -> list[str]:
    text = text.strip()
    if not text:
        return []
    ops = [op.strip() for op in text.split(",")]
    if any(op == "" for op in ops):
        raise _LineError("operando vacio (sobra o falta una coma)")
    return ops


def parse_int(text: str) -> int:
    """Entero decimal, hexadecimal (0x) o binario (0b), con signo opcional."""
    m = _INT_RE.match(text.strip())
    if not m:
        raise _LineError(f"inmediato invalido '{text}'")
    sign, digits = m.groups()
    if len(digits) > 1 and digits[0] == "0" and digits[1].isdigit():
        # En GNU as un numero con cero a la izquierda es octal: se rechaza
        # para que el mismo .s no signifique cosas distintas.
        raise _LineError(f"numero con cero a la izquierda '{text}' "
                         "(ambiguo: GNU as lo lee en octal)")
    value = int(digits.replace("_", ""), 0)
    return -value if sign == "-" else value


def _check_range(value: int, lo: int, hi: int, what: str) -> int:
    if not lo <= value <= hi:
        raise _LineError(f"{what} fuera de rango: {value} (permitido {lo} a {hi})")
    return value


# --------------------------------------------------------------------------
# Codificacion por formato (docs/spec/isa.md, figura de formatos)
# --------------------------------------------------------------------------
def encode_r(spec: InstrSpec, rd: int, rs1: int, rs2: int) -> int:
    return (spec.funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (spec.funct3 << 12) | (rd << 7) | spec.opcode


def encode_i(spec: InstrSpec, rd: int, rs1: int, imm: int) -> int:
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (spec.funct3 << 12) | (rd << 7) | spec.opcode


def encode_s(spec: InstrSpec, rs1: int, rs2: int, imm: int) -> int:
    imm &= 0xFFF
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (spec.funct3 << 12) \
        | ((imm & 0x1F) << 7) | spec.opcode


def encode_b(spec: InstrSpec, rs1: int, rs2: int, imm: int) -> int:
    imm &= 0x1FFF
    return (((imm >> 12) & 0x1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) \
        | (spec.funct3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 0x1) << 7) | spec.opcode


def encode_u(spec: InstrSpec, rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | spec.opcode


def encode_j(spec: InstrSpec, rd: int, imm: int) -> int:
    imm &= 0x1FFFFF
    return (((imm >> 20) & 0x1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 0x1) << 20) \
        | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | spec.opcode


# --------------------------------------------------------------------------
# Ensamblador
# --------------------------------------------------------------------------
@dataclass
class _Statement:
    line_no: int
    source: str
    address: int
    mnemonic: str
    operands: list[str]


def _li_parts(value: int) -> tuple[int, int]:
    """Divide un valor de 32 bits en (hi20, lo12) tal que (hi20 << 12) + lo12 = valor.

    lo12 es con signo, por eso hi20 se redondea sumando 0x800 (igual que
    %hi/%lo en GNU as y LLVM).
    """
    value &= 0xFFFFFFFF
    lo = value & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((value - lo) >> 12) & 0xFFFFF
    return hi, lo


class _Assembler:
    def __init__(self, source: str, filename: str):
        self.lines = source.splitlines()
        self.filename = filename
        self.errors: list[Diagnostic] = []
        self.warnings: list[Diagnostic] = []
        self.labels: dict[str, tuple[int, int]] = {}   # nombre -> (direccion, linea)
        self.constants: dict[str, int] = {}             # .equ / .set
        self.statements: list[_Statement] = []
        self.size_words = 0

    # ---- diagnosticos -----------------------------------------------------
    def _error(self, line_no: int, message: str) -> None:
        src = self.lines[line_no - 1] if 0 < line_no <= len(self.lines) else ""
        self.errors.append(Diagnostic(self.filename, line_no, message, src))

    def _warn(self, line_no: int, message: str) -> None:
        src = self.lines[line_no - 1] if 0 < line_no <= len(self.lines) else ""
        self.warnings.append(Diagnostic(self.filename, line_no, message, src, "warning"))

    # ---- operandos --------------------------------------------------------
    @staticmethod
    def reg(text: str) -> int:
        name = text.strip().lower()
        if name not in REGISTERS:
            raise _LineError(f"registro inexistente '{text.strip()}'")
        return REGISTERS[name]

    def imm(self, text: str) -> int:
        text = text.strip()
        if _SYMBOL_RE.match(text):
            if text in self.constants:
                return self.constants[text]
            if text.lower() in REGISTERS:
                raise _LineError(f"se esperaba un inmediato y se encontro el registro '{text}'")
            if text in self.labels:
                raise _LineError(f"la etiqueta '{text}' no se puede usar como inmediato "
                                 "(solo como destino de salto o en .word)")
            raise _LineError(f"simbolo no definido '{text}'")
        return parse_int(text)

    def mem(self, text: str) -> tuple[int, int]:
        """'imm(rs1)' o '(rs1)' -> (imm, rs1)."""
        m = _MEM_OPERAND_RE.match(text.strip())
        if not m:
            raise _LineError(f"se esperaba 'offset(registro)' y se encontro '{text.strip()}'")
        off, base = m.groups()
        offset = self.imm(off) if off.strip() else 0
        return offset, self.reg(base)

    def target(self, text: str, pc: int, bits: int, what: str) -> int:
        """Destino de salto: etiqueta (relativa al PC) o desplazamiento numerico."""
        text = text.strip()
        if _SYMBOL_RE.match(text) and text not in self.constants:
            if text.lower() in REGISTERS:
                raise _LineError(f"se esperaba una etiqueta o desplazamiento y se encontro "
                                 f"el registro '{text}'")
            if text not in self.labels:
                raise _LineError(f"etiqueta no definida '{text}'")
            offset = self.labels[text][0] - pc
        else:
            offset = self.imm(text)
        lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 2
        _check_range(offset, lo, hi, f"desplazamiento de {what}")
        if offset % 4:
            raise _LineError(f"desplazamiento de {what} {offset} no es multiplo de 4 "
                             "(no hay instrucciones comprimidas)")
        return offset

    @staticmethod
    def _arity(mnemonic: str, ops: list[str], *allowed: int) -> None:
        if len(ops) not in allowed:
            expected = " o ".join(str(n) for n in allowed)
            raise _LineError(f"'{mnemonic}' espera {expected} operandos y recibio {len(ops)}")

    # ---- pasada 1 ---------------------------------------------------------
    def _size(self, mnemonic: str, ops: list[str]) -> int:
        """Palabras que ocupa una sentencia (se necesita antes de codificar)."""
        if mnemonic == ".word":
            if not ops:
                raise _LineError("'.word' necesita al menos un valor")
            return len(ops)
        if mnemonic == "li":
            # el tamano depende del valor: una constante .equ tiene que estar
            # definida antes (en el resto de las instrucciones puede ir despues)
            self._arity("li", ops, 2)
            try:
                value = self._li_value(ops[1])
            except _LineError as e:
                if str(e).startswith("simbolo no definido"):
                    raise _LineError(f"{e} (en 'li' la constante .equ tiene que definirse "
                                     "antes de usarla)") from None
                raise
            return 1 if -2048 <= value <= 2047 or _li_parts(value)[1] == 0 else 2
        return 1

    def _li_value(self, text: str) -> int:
        value = self.imm(text)
        _check_range(value, -(1 << 31), (1 << 32) - 1, "inmediato de 'li'")
        return value - (1 << 32) if value >= 1 << 31 else value

    def _directive(self, name: str, rest: str) -> bool:
        """Procesa directivas sin contenido. True si la sentencia no ocupa memoria."""
        if name in (".text", ".globl", ".global"):
            if name == ".text" and rest.strip():
                raise _LineError("'.text' no lleva argumentos")
            return True
        if name in (".equ", ".set"):
            ops = _split_operands(rest)
            self._arity(name, ops, 2)
            sym = ops[0]
            if not _SYMBOL_RE.match(sym):
                raise _LineError(f"nombre de constante invalido '{sym}'")
            if sym in self.labels or sym in self.constants:
                raise _LineError(f"simbolo '{sym}' ya definido")
            self.constants[sym] = self.imm(ops[1])
            return True
        if name in (".data", ".bss", ".rodata", ".section", ".byte", ".half",
                    ".ascii", ".asciz", ".string", ".zero", ".space"):
            raise _LineError(f"directiva '{name}' no soportada: no hay seccion de datos "
                             "inicializada; los datos se escriben con stores "
                             "(memoria.md 2.2)")
        if name == ".word":
            return False
        raise _LineError(f"directiva desconocida '{name}'")

    def first_pass(self) -> None:
        address = 0
        for line_no, raw in enumerate(self.lines, start=1):
            is_statement = False
            try:
                text = _strip_comment(raw)
                while (m := _LABEL_RE.match(text)):
                    name = m.group(1)
                    if name in self.labels:
                        prev = self.labels[name][1]
                        raise _LineError(f"etiqueta '{name}' duplicada (definida en la linea {prev})")
                    if name.lower() in REGISTERS or name.lower() in INSTRUCTIONS \
                            or name.lower() in PSEUDO_INSTRUCTIONS or name in self.constants:
                        raise _LineError(f"'{name}' no puede ser etiqueta: es un registro, "
                                         "instruccion o constante")
                    self.labels[name] = (address, line_no)
                    text = text[m.end():]
                text = text.strip()
                if not text:
                    continue
                parts = text.split(None, 1)
                mnemonic = parts[0].lower()
                rest = parts[1] if len(parts) > 1 else ""
                if mnemonic.startswith(".") and self._directive(mnemonic, rest):
                    continue
                is_statement = True
                ops = _split_operands(rest)
                if not mnemonic.startswith("."):
                    self._check_mnemonic(mnemonic)
                size = self._size(mnemonic, ops)
                self.statements.append(_Statement(line_no, raw, address, mnemonic, ops))
                address += 4 * size
            except _LineError as e:
                self._error(line_no, str(e))
                if is_statement:
                    # reserva la palabra: las etiquetas siguientes quedan en su
                    # direccion real y el limite de 1024 palabras cuenta esta linea
                    address += 4
        self.size_words = address // 4

    @staticmethod
    def _check_mnemonic(mnemonic: str) -> None:
        if mnemonic in INSTRUCTIONS or mnemonic in PSEUDO_INSTRUCTIONS:
            return
        if mnemonic in UNSUPPORTED_RV32I:
            raise _LineError(f"instruccion '{mnemonic}' no soportada por este procesador "
                             "(ver docs/spec/isa.md)")
        raise _LineError(f"instruccion invalida '{mnemonic}'")

    # ---- pasada 2 ---------------------------------------------------------
    def encode(self, st: _Statement) -> list[int]:
        m, ops, pc = st.mnemonic, st.operands, st.address
        if m == ".word":
            words = []
            for op in ops:
                op = op.strip()
                if _SYMBOL_RE.match(op) and op in self.labels:
                    value = self.labels[op][0]
                else:
                    value = _check_range(self.imm(op), -(1 << 31), (1 << 32) - 1, "valor de '.word'")
                words.append(value & 0xFFFFFFFF)
            return words
        if m in PSEUDO_INSTRUCTIONS:
            return self._encode_pseudo(m, ops, pc)
        return [self._encode_real(m, ops, pc)]

    def _encode_real(self, m: str, ops: list[str], pc: int) -> int:
        spec = INSTRUCTIONS[m]
        form = spec.form
        if form == "R":
            self._arity(m, ops, 3)
            return encode_r(spec, self.reg(ops[0]), self.reg(ops[1]), self.reg(ops[2]))
        if form == "I":
            self._arity(m, ops, 3)
            imm = _check_range(self.imm(ops[2]), -2048, 2047, "inmediato de 12 bits")
            return encode_i(spec, self.reg(ops[0]), self.reg(ops[1]), imm)
        if form == "SHIFT":
            self._arity(m, ops, 3)
            shamt = _check_range(self.imm(ops[2]), 0, 31, "shamt")
            return encode_i(spec, self.reg(ops[0]), self.reg(ops[1]), (spec.funct7 << 5) | shamt)
        if form == "LOAD":
            self._arity(m, ops, 2)
            off, base = self.mem(ops[1])
            _check_range(off, -2048, 2047, "offset de 12 bits")
            return encode_i(spec, self.reg(ops[0]), base, off)
        if form == "S":
            self._arity(m, ops, 2)
            off, base = self.mem(ops[1])
            _check_range(off, -2048, 2047, "offset de 12 bits")
            return encode_s(spec, base, self.reg(ops[0]), off)
        if form == "B":
            self._arity(m, ops, 3)
            off = self.target(ops[2], pc, 13, "branch")
            return encode_b(spec, self.reg(ops[0]), self.reg(ops[1]), off)
        if form == "U":
            self._arity(m, ops, 2)
            imm = _check_range(self.imm(ops[1]), 0, 0xFFFFF, "inmediato de 20 bits")
            return encode_u(spec, self.reg(ops[0]), imm)
        if form == "J":
            self._arity(m, ops, 1, 2)
            rd = self.reg(ops[0]) if len(ops) == 2 else 1   # 'jal destino' = 'jal ra, destino'
            return encode_j(spec, rd, self.target(ops[-1], pc, 21, "jal"))
        if form == "JALR":
            self._arity(m, ops, 1, 2, 3)
            if len(ops) == 1:                                # jalr rs1 = jalr ra, 0(rs1)
                rd, (off, base) = 1, self._jalr_base(ops[0])
            elif len(ops) == 2:                              # jalr rd, imm(rs1) | jalr rd, rs1
                rd, (off, base) = self.reg(ops[0]), self._jalr_base(ops[1])
            else:                                            # jalr rd, rs1, imm
                rd, base, off = self.reg(ops[0]), self.reg(ops[1]), self.imm(ops[2])
            _check_range(off, -2048, 2047, "offset de 12 bits")
            return encode_i(spec, rd, base, off)
        if form == "SYS":
            self._arity(m, ops, 0)
            return HALT_WORD
        raise AssertionError(f"forma desconocida {form}")

    def _jalr_base(self, text: str) -> tuple[int, int]:
        return self.mem(text) if "(" in text else (0, self.reg(text))

    def _encode_pseudo(self, m: str, ops: list[str], pc: int) -> list[int]:
        self._arity(m, ops, PSEUDO_INSTRUCTIONS[m])
        I = INSTRUCTIONS
        if m == "nop":
            return [encode_i(I["addi"], 0, 0, 0)]
        if m == "mv":
            return [encode_i(I["addi"], self.reg(ops[0]), self.reg(ops[1]), 0)]
        if m == "not":
            return [encode_i(I["xori"], self.reg(ops[0]), self.reg(ops[1]), -1)]
        if m == "neg":
            return [encode_r(I["sub"], self.reg(ops[0]), 0, self.reg(ops[1]))]
        if m == "li":
            rd, value = self.reg(ops[0]), self._li_value(ops[1])
            if -2048 <= value <= 2047:
                return [encode_i(I["addi"], rd, 0, value)]
            hi, lo = _li_parts(value)
            words = [encode_u(I["lui"], rd, hi)]
            if lo:
                words.append(encode_i(I["addi"], rd, rd, lo))
            return words
        if m == "j":
            return [encode_j(I["jal"], 0, self.target(ops[0], pc, 21, "jal"))]
        if m == "jr":
            return [encode_i(I["jalr"], 0, self.reg(ops[0]), 0)]
        if m == "ret":
            return [encode_i(I["jalr"], 0, REGISTERS["ra"], 0)]
        if m == "beqz":
            return [encode_b(I["beq"], self.reg(ops[0]), 0, self.target(ops[1], pc, 13, "branch"))]
        if m == "bnez":
            return [encode_b(I["bne"], self.reg(ops[0]), 0, self.target(ops[1], pc, 13, "branch"))]
        raise AssertionError(f"pseudo-instruccion sin expansion {m}")

    def second_pass(self) -> tuple[list[int], dict[int, tuple[int, str]]]:
        words: list[int] = []
        source_map: dict[int, tuple[int, str]] = {}
        for st in self.statements:
            try:
                encoded = self.encode(st)
            except _LineError as e:
                self._error(st.line_no, str(e))
                continue
            for i, w in enumerate(encoded):
                source_map[st.address + 4 * i] = (st.line_no, st.source)
            words.extend(encoded)
        return words, source_map

    # ---- verificaciones del programa completo ------------------------------
    def check_program(self, words: list[int]) -> None:
        # size_words sale de la pasada 1: es correcto aunque haya lineas con error
        if self.size_words > IMEM_WORDS:
            self.errors.append(Diagnostic(
                self.filename, max(len(self.lines), 1),
                f"el programa ocupa {self.size_words} palabras y la memoria de programa tiene "
                f"{IMEM_WORDS} (memoria.md 2.2)"))
        if not self.errors and not words:
            self.errors.append(Diagnostic(self.filename, max(len(self.lines), 1),
                                          "el programa esta vacio (LOAD necesita al menos una palabra)"))
        has_halt = any(st.mnemonic in ("halt", "ebreak") for st in self.statements)
        if words and not has_halt:
            self._warn(max(len(self.lines), 1),
                       "el programa no tiene 'halt': se detendra en el relleno con HALT que "
                       "agrega LOAD despues de la ultima palabra")


def assemble(source: str, filename: str = "<entrada>") -> Program:
    """Ensambla un programa completo. Lanza AssemblerError si hay errores."""
    asm = _Assembler(source, filename)
    asm.first_pass()
    words, source_map = asm.second_pass()
    asm.check_program(words)
    if asm.errors:
        raise AssemblerError(sorted(asm.errors, key=lambda d: d.line))
    labels = {name: addr for name, (addr, _) in asm.labels.items()}
    return Program(words, source_map, labels, asm.warnings)
