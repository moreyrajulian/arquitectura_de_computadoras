"""Punto de entrada del modelo de referencia (ver README.md)."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from isasim.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
