"""Formatos de salida del ensamblador.

| Formato | Para que                                                         |
|---------|------------------------------------------------------------------|
| hex     | $readmemh en simulacion y entrada de la interfaz de la PC (F2)  |
| bin     | Payload exacto del comando LOAD (palabras little-endian)        |
| coe     | Inicializacion del Block Memory Generator de Vivado              |
| lst     | Listado para leer: direccion, palabra y linea fuente            |
"""

from .assembler import Program
from .isa import HALT_WORD, IMEM_WORDS

FORMATS = ("hex", "bin", "coe", "lst")


def _filled(words: list[int], fill: bool) -> list[int]:
    """Con fill, completa la memoria con HALT como lo deja LOAD (memoria.md 4.2)."""
    return words + [HALT_WORD] * (IMEM_WORDS - len(words)) if fill else list(words)


def to_hex(program: Program, fill: bool = False) -> str:
    """Una palabra por linea, 8 digitos hex, sin prefijo: lo lee $readmemh."""
    return "".join(f"{w:08x}\n" for w in _filled(program.words, fill))


def to_bin(program: Program, fill: bool = False) -> bytes:
    return b"".join(w.to_bytes(4, "little") for w in _filled(program.words, fill))


def to_coe(program: Program, fill: bool = False, source_name: str = "") -> str:
    words = _filled(program.words, fill)
    header = f"; generado por rvasm desde {source_name}\n" if source_name else ""
    body = ",\n".join(f"{w:08x}" for w in words)
    return (f"{header}memory_initialization_radix=16;\n"
            f"memory_initialization_vector=\n{body};\n")


def to_listing(program: Program) -> str:
    """direccion  palabra  linea | fuente. Una pseudo de dos palabras repite la linea."""
    out = []
    addr_to_label = {}
    for name, addr in program.labels.items():
        addr_to_label.setdefault(addr, []).append(name)
    for i, w in enumerate(program.words):
        addr = 4 * i
        for name in addr_to_label.get(addr, []):
            out.append(f"{'':20}{name}:")
        line_no, src = program.source_map.get(addr, (0, ""))
        out.append(f"0x{addr:04x}  {w:08x}  {line_no:4} | {src.strip()}")
    return "\n".join(out) + "\n"


def render(program: Program, fmt: str, fill: bool = False, source_name: str = "") -> bytes:
    """Salida en el formato pedido, siempre como bytes (listo para escribir)."""
    if fmt == "hex":
        return to_hex(program, fill).encode()
    if fmt == "bin":
        return to_bin(program, fill)
    if fmt == "coe":
        return to_coe(program, fill, source_name).encode()
    if fmt == "lst":
        return to_listing(program).encode()
    raise ValueError(f"formato desconocido '{fmt}' (opciones: {', '.join(FORMATS)})")
