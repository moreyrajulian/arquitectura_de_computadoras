"""Debugger del RISC-V: interfaz de texto sobre la Debug Unit (docs/spec/interfaz_pc.md).

    python tools/debugger/debugger.py [--port COM10] [--prog sw/alu_r.s]

Necesita `pip install -r tools/debugger/requirements.txt` (textual y pyserial).
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from rvdebug.tui import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
