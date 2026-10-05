"""Campos de los registros de segmentación (pipeline.md §8) y su empaquetado.

Un latch se empaqueta en un número de `bits` bits con los campos **en el orden de
las tablas de pipeline.md §8, el primero en los bits más altos**. Es el formato de
una línea de los archivos de traza que lee el testbench con `$readmemh`, y el que
usa el volcado de `READ_LATCHES` partido en palabras de 32 bits (propuesta para
cerrar la tabla provisoria de protocolo_debug.md §3.6).

Junto con cada valor esperado se genera una **máscara**: los bits en 1 se comparan.
Reglas (a respetar por el banco de pruebas, I-17):
- Burbuja (`valid = 0`): solo `valid` y las señales de control (pipeline.md §2:
  "sus campos de datos no importan").
- `id_ex_imm` de una instrucción sin inmediato (tipo R, HALT, no reconocida):
  `imm_sel` vale "x" en la tabla de verdad (pipeline.md §4.4), así que el valor
  depende de la implementación.
- Todo lo demás se compara, incluidos los campos que la instrucción no usa (por
  ejemplo `id_ex_rs2_data` de un `addi`): su valor está definido por el diseño.
"""

from dataclasses import dataclass

# (nombre, ancho, es_control). Orden y anchos de pipeline.md §8.
LAYOUT = {
    "if_id": [
        ("valid", 1, True), ("pc", 32, False), ("instr", 32, False),
    ],
    "id_ex": [
        ("valid", 1, True), ("pc", 32, False), ("rs1_data", 32, False),
        ("rs2_data", 32, False), ("imm", 32, False), ("rs1", 5, False),
        ("rs2", 5, False), ("rd", 5, False), ("funct3", 3, False),
        ("alu_ctrl", 4, True), ("alu_src_a", 1, True), ("alu_src_b", 1, True),
        ("branch", 1, True), ("jal", 1, True), ("jalr", 1, True),
        ("mem_read", 1, True), ("mem_write", 1, True), ("reg_write", 1, True),
        ("mem_to_reg", 1, True), ("halt", 1, True),
    ],
    "ex_mem": [
        ("valid", 1, True), ("pc", 32, False), ("result", 32, False),
        ("store_data", 32, False), ("rd", 5, False), ("funct3", 3, False),
        ("mem_write", 1, True), ("reg_write", 1, True), ("mem_to_reg", 1, True),
        ("halt", 1, True),
    ],
    "mem_wb": [
        ("valid", 1, True), ("pc", 32, False), ("result", 32, False),
        ("read_data", 32, False), ("rd", 5, False), ("funct3", 3, False),
        ("offset", 2, False), ("reg_write", 1, True), ("mem_to_reg", 1, True),
        ("halt", 1, True),
    ],
}

LATCHES = list(LAYOUT)                          # orden IF/ID, ID/EX, EX/MEM, MEM/WB
TITLES = {"if_id": "IF/ID", "id_ex": "ID/EX", "ex_mem": "EX/MEM", "mem_wb": "MEM/WB"}
WIDTH = {name: sum(w for _, w, _ in fields) for name, fields in LAYOUT.items()}
WORDS = {name: (bits + 31) // 32 for name, bits in WIDTH.items()}   # para READ_LATCHES


def bubble(latch):
    """Contenido de un latch después del reset: todo en cero."""
    return {name: 0 for name, _, _ in LAYOUT[latch]}


def pack(latch, values):
    """Empaqueta los campos de un latch en un entero de WIDTH[latch] bits."""
    out = 0
    for name, width, _ in LAYOUT[latch]:
        v = values[name]
        if v < 0 or v >> width:
            raise ValueError(f"{latch}.{name} = {v} no entra en {width} bits")
        out = (out << width) | v
    return out


def unpack(latch, number):
    values = {}
    for name, width, _ in reversed(LAYOUT[latch]):
        values[name] = number & ((1 << width) - 1)
        number >>= width
    return values


def compare_mask(latch, values, imm_defined=True):
    """Máscara de bits a comparar para un contenido esperado (reglas del docstring)."""
    out = 0
    valid = values["valid"]
    for name, width, is_control in LAYOUT[latch]:
        compare = is_control or valid
        if latch == "id_ex" and name == "imm" and not imm_defined:
            compare = False
        out = (out << width) | (((1 << width) - 1) if compare else 0)
    return out


def hex_digits(latch):
    return (WIDTH[latch] + 3) // 4


def to_words(latch, number):
    """Partido en palabras de 32 bits, la menos significativa primero."""
    return [(number >> (32 * i)) & 0xFFFF_FFFF for i in range(WORDS[latch])]


@dataclass
class Snapshot:
    """Contenido de los cuatro latches durante un ciclo."""

    cycle: int
    values: dict                 # latch -> {campo: valor}
    imm_defined: bool            # ID/EX: si el inmediato está definido
    events: list                 # texto: stall, redirect, stop_fetch, escritura...

    def packed(self, latch):
        return pack(latch, self.values[latch])

    def mask(self, latch):
        return compare_mask(latch, self.values[latch], self.imm_defined)
