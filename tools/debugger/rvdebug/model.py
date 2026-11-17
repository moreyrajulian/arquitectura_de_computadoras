"""Capa `model` de la interfaz (docs/spec/interfaz_pc.md §1, decisión 040): el volcado de
un instante y cómo se muestra un registro. Python puro, sin Textual.

`Snapshot` junta lo que devuelve READ_ALL (bloque de estado, registros, latches y memoria
usada) y, si se pidió, el último READ_DMEM. Las diferencias entre dos volcados, la
decodificación de los latches en campos de pipeline.md §8 y la inferencia de riesgos
(interfaz_pc.md §4.2 y §4.3) son de la I-53 y se agregan acá.
"""

from __future__ import annotations

from dataclasses import dataclass, replace

from .protocol import Dump, Latches, Status

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
