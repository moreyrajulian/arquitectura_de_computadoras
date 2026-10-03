"""Punto de entrada: python tools/assembler/asm.py programa.s -o programa.hex

Agrega su propia carpeta al path para que funcione desde cualquier directorio.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from rvasm.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
