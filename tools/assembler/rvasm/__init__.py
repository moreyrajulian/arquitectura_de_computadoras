"""rvasm: ensamblador del subconjunto RV32I del procesador (docs/spec/isa.md).

Uso como biblioteca (por ejemplo desde la interfaz de la PC):

    from rvasm import assemble, AssemblerError
    program = assemble(open("prog.s").read(), "prog.s")
    payload = program.to_bytes()      # payload de LOAD
"""

from .assembler import AssemblerError, Diagnostic, Program, assemble, parse_int
from .isa import HALT_WORD, IMEM_WORDS
from .output import FORMATS, render, to_bin, to_coe, to_hex, to_listing

__all__ = [
    "AssemblerError", "Diagnostic", "Program", "assemble", "parse_int",
    "HALT_WORD", "IMEM_WORDS",
    "FORMATS", "render", "to_bin", "to_coe", "to_hex", "to_listing",
]
