"""Desensamblador: palabra de 32 bits -> texto (I-51, decision 034).

Envuelve el desensamblado del modelo de referencia (tools/isasim/isasim/isa.py),
que decodifica con tablas propias escritas desde isa.md. Lo que agrega es
classify antes de decodificar: una palabra fuera de isa.md se muestra como no
soportada, con lo que haria el hardware, en vez de terminar en el error del
modelo (decisiones 024 y 025).

El texto de una instruccion de isa.md se vuelve a ensamblar con rvasm y da la
misma palabra: registros x0..x31, inmediatos en decimal, lui con los 20 bits
altos en hex y saltos con el desplazamiento relativo al PC (+8, -4), que rvasm
interpreta igual que una etiqueta (README 2.5). 0x00000013 sale como 'nop',
como en objdump: los programas _nops de sw/ estan llenos.

Un branch o un jal cuyo desplazamiento no es multiplo de 4 es una palabra de
isa.md (el `.word 0xdeadbeef` de tests/programs/isa_completo.s es un jal asi),
pero rvasm no acepta ese desplazamiento en la fuente: no hay instrucciones
comprimidas. Sale como '.word' con la instruccion en el comentario, que se
vuelve a ensamblar igual. Asi la ida y vuelta vale para toda palabra de isa.md.
"""

import sys
from functools import cache
from pathlib import Path
from types import ModuleType

from .isa import SUPPORTED, UNRECOGNIZED, classify

NOP_WORD = 0x0000_0013   # addi x0, x0, 0

_ISASIM_DIR = Path(__file__).resolve().parents[2] / "isasim"


@cache
def _model() -> ModuleType:
    """isasim.isa, importado recien al desensamblar: `import rvasm` no carga el modelo."""
    if str(_ISASIM_DIR) not in sys.path:
        sys.path.insert(0, str(_ISASIM_DIR))
    from isasim import isa
    return isa


def disassemble(word: int) -> str:
    """Texto de una palabra, por ejemplo 'addi x1, x0, 5', 'beq x1, x2, -8' o 'halt'.

    Un salto de isa.md con desplazamiento no multiplo de 4 da '.word 0x...' con la
    instruccion en el comentario. Una palabra fuera de isa.md da '.word 0x...' con
    un comentario que dice por que y que haria el hardware; ese texto el
    ensamblador lo rechaza (decision 025).
    """
    if not 0 <= word <= 0xFFFF_FFFF:
        raise ValueError(f"la palabra no entra en 32 bits: {word:#x}")
    if word == NOP_WORD:
        return "nop"
    result = classify(word)
    if result.kind == SUPPORTED:
        model = _model()
        ins = model.decode(word)
        text = model.disassemble(ins)
        if ins.kind in ("BRANCH", "JAL") and ins.imm & 0b10:
            return f".word 0x{word:08X}  # {text}: desplazamiento no multiplo de 4"
        return text
    effect = "el hardware la ejecuta como NOP" if result.kind == UNRECOGNIZED \
        else "resultado no especificado"
    return f".word 0x{word:08X}  # fuera de isa.md: {result.reason}; {effect}"
