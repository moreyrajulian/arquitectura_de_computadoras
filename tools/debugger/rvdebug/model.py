"""Capa `model` de la interfaz (docs/spec/interfaz_pc.md §1, decisiones 040 y 043): el
volcado de un instante, cómo se muestra un registro, los campos de los latches, la palabra
de cada dirección y qué cambió entre dos volcados. Python puro, sin Textual.

`Snapshot` junta lo que devuelve READ_ALL (bloque de estado, registros, latches y memoria
usada) y, si se pidió, el último READ_DMEM. Los campos de cada latch salen de la tabla del
modelo de referencia (`isasim.latches.LAYOUT`, el orden de pipeline.md §8), así hay una sola
copia en Python (decisión 043). La inferencia de riesgos está en `hazards.py`.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field, replace
from functools import cached_property
from pathlib import Path

from .protocol import Dump, Latches, Status

_ISASIM = Path(__file__).resolve().parents[2] / "isasim"
if str(_ISASIM) not in sys.path:
    sys.path.insert(0, str(_ISASIM))
from isasim.latches import LATCHES, LAYOUT, WIDTH, WORDS, unpack  # noqa: E402
from isasim.latches import TITLES  # noqa: E402, F401  (nombres de los latches para la TUI)

HALT_WORD = 0x0010_0073      # isa.md: LOAD llena el resto de imem con HALT
IMEM_WORDS = 1024            # memoria.md; INFO informa el tamaño real

# Campos de control de cada latch: en una burbuja son los únicos que importan (pipeline.md §2)
CONTROL = {latch: frozenset(n for n, _, is_ctrl in LAYOUT[latch] if is_ctrl)
           for latch in LATCHES}

# Nombres ABI de x0 … x31 (convención de llamada de RISC-V)
ABI = ("zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
       "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
       "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
       "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6")


def reg_name(n: int) -> str:
    """`x1/ra`, como en la tabla de registros del boceto."""
    return f"x{n}/{ABI[n]}"


def fmt_hex(value: int) -> str:
    return f"0x{value & 0xFFFF_FFFF:08X}"


def fmt_dec(value: int, signed: bool = True) -> str:
    """Decimal de una palabra de 32 bits, en complemento a dos si `signed`."""
    value &= 0xFFFF_FFFF
    if signed and value & 0x8000_0000:
        value -= 1 << 32
    return str(value)


@dataclass(frozen=True)
class MemRange:
    """Resultado de un READ_DMEM: `addr` en bytes y las palabras leídas desde ahí."""
    addr: int
    words: tuple[int, ...]


def word_at(words, pc: int, imem_words: int = IMEM_WORDS) -> int | None:
    """La palabra de imem en `pc`, a partir de lo que se mandó con LOAD (decisión 043).

    Usa el índice `addr[11:2]` del core (memoria.md §6), así una dirección fuera de rango o
    desalineada da la misma palabra que buscaría IF. Después del programa, HALT. Sin
    programa conocido (`words` None), None."""
    if words is None:
        return None
    index = (pc >> 2) % imem_words
    return words[index] if index < len(words) else HALT_WORD


def decode_latches(latches: Latches) -> dict[str, dict[str, int]] | None:
    """Los campos de cada latch ({latch: {campo: valor}}), con los bits de relleno
    descartados. None si las palabras por latch no son las de pipeline.md §8 (la Debug Unit
    informa otro ancho en INFO)."""
    if any(len(latches.words(l)) != WORDS[l] for l in LATCHES):
        return None
    out = {}
    for latch in LATCHES:
        values = unpack(latch, latches.packed(latch) & ((1 << WIDTH[latch]) - 1))
        out[latch] = {name: values[name] for name, _, _ in LAYOUT[latch]}   # orden de §8
    return out


@dataclass(frozen=True)
class Snapshot:
    """Estado del procesador en un instante, tal como lo leyó la PC."""
    status: Status
    regs: tuple[int, ...]
    latches: Latches
    used: tuple[tuple[int, int], ...]    # pares (dirección en bytes, valor), en orden creciente
    range: MemRange | None = None        # el último READ_DMEM, si se pidió

    @classmethod
    def from_dump(cls, dump: Dump, range: MemRange | None = None) -> Snapshot:
        return cls(dump.status, dump.regs, dump.latches, dump.used, range)

    def with_status(self, status: Status) -> Snapshot:
        """El mismo volcado con un bloque de estado más nuevo (STATUS durante RUN)."""
        return replace(self, status=status)

    def with_range(self, range: MemRange) -> Snapshot:
        return replace(self, range=range)

    @cached_property
    def fields(self) -> dict[str, dict[str, int]] | None:
        """Los latches campo por campo (`decode_latches`)."""
        return decode_latches(self.latches)


@dataclass(frozen=True)
class Diff:
    """Qué cambió de un volcado al siguiente (interfaz_pc.md §4.2): los índices de los
    registros, los (latch, campo) y las direcciones de la memoria usada."""
    regs: frozenset[int] = field(default_factory=frozenset)
    latches: frozenset[tuple[str, str]] = field(default_factory=frozenset)
    mem: frozenset[int] = field(default_factory=frozenset)

    def __bool__(self) -> bool:
        return bool(self.regs or self.latches or self.mem)

    @property
    def counts(self) -> tuple[int, int, int]:
        """(registros, campos de latch, palabras de memoria)."""
        return len(self.regs), len(self.latches), len(self.mem)

    def summary(self, cur: Snapshot) -> str:
        """Resumen para el historial: `x3=12, M[0x0]=12` (valores con signo)."""
        used = dict(cur.used)
        parts = [f"x{i}={fmt_dec(cur.regs[i])}" for i in sorted(self.regs)]
        parts += [f"M[0x{a:X}]={fmt_dec(used[a])}" for a in sorted(self.mem) if a in used]
        return ", ".join(parts) or "—"


def diff(prev: Snapshot | None, cur: Snapshot) -> Diff:
    """Lo que cambió de `prev` a `cur`. Sin volcado anterior no cambió nada.

    En un latch que en `cur` es burbuja solo cuentan `valid` y el control: sus datos no
    importan (pipeline.md §2) y resaltarlos confundiría."""
    if prev is None:
        return Diff()
    regs = frozenset(i for i, (a, b) in enumerate(zip(prev.regs, cur.regs)) if a != b)
    before = dict(prev.used)
    mem = frozenset(addr for addr, value in cur.used if before.get(addr) != value)
    changed = set()
    if prev.fields is not None and cur.fields is not None:
        for latch in LATCHES:
            old, new = prev.fields[latch], cur.fields[latch]
            for name in new:
                if old[name] != new[name] and (new["valid"] or name in CONTROL[latch]):
                    changed.add((latch, name))
    return Diff(regs, frozenset(changed), mem)
