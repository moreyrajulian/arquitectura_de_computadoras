"""Ayudas comunes de los tests del modelo (nombre propio para no chocar con otros
módulos de test del repo cuando pytest corre varias carpetas juntas)."""

import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[2]
REPO = TOOLS.parent
for path in (TOOLS / "isasim", TOOLS / "assembler"):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

from rvasm import HALT_WORD, assemble  # noqa: E402


def words_of(source):
    """Ensambla un fragmento y devuelve la memoria de programa completa (con HALT)."""
    words = assemble(source, "test.s").words
    return words + [HALT_WORD] * (1024 - len(words))
