"""isasim: modelo de referencia del procesador (I-16).

Dos capas (decisión del modelo de referencia):
- isa.py: semántica de docs/spec/isa.md, instrucción por instrucción;
- pipeline.py: el pipeline ciclo a ciclo según docs/spec/pipeline.md, comparado
  contra la capa anterior en cada instrucción.

Uso como biblioteca:

    from isasim import simulate, load_program, COMPLETO
    r = simulate(load_program("sw/fwd_exmem.s"), mode=COMPLETO)
    r.regs, r.dmem, r.cycles, r.snapshots
"""

from .files import (compare_exp, format_exp, format_trace, load_initial_state,
                    load_program, parse_exp, read_all_payload, write_outputs)
from .isa import IsaSim, ModelError, decode
from .latches import LATCHES, LAYOUT, WIDTH, pack, unpack
from .pipeline import COMPLETO, SIN_RIESGOS, Mode, RunResult, simulate

__all__ = [
    "simulate", "Mode", "COMPLETO", "SIN_RIESGOS", "RunResult", "ModelError",
    "IsaSim", "decode", "LATCHES", "LAYOUT", "WIDTH", "pack", "unpack",
    "load_program", "load_initial_state", "parse_exp", "compare_exp", "format_exp",
    "format_trace", "read_all_payload", "write_outputs",
]
