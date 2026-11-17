"""Capa `tui` del debugger (docs/spec/interfaz_pc.md, decisiones 008 y 040): la pantalla
con Textual. Solo dibuja y traduce teclas a acciones de `rvdebug.session`.

    python tools/debugger/debugger.py --port COM10 --prog sw/alu_r.s
"""

from __future__ import annotations

import argparse

from ..protocol import BAUD
from .app import DebuggerApp, serial_connector

__all__ = ["DebuggerApp", "serial_connector", "main"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="debugger.py",
        description="Debugger del RISC-V por la Debug Unit (docs/spec/interfaz_pc.md)")
    parser.add_argument("--port", help="puerto serie (COM10, /dev/ttyUSB1); sin él, F1 "
                                       "lista los puertos")
    parser.add_argument("--prog", help="programa a cargar al conectar (.s, .hex o .bin)")
    parser.add_argument("--baud", type=int, default=BAUD, help=f"baudrate (por defecto {BAUD})")
    parser.add_argument("--watchdog", type=float, default=5.0,
                        help="segundos sin EVT_HALTED antes de avisar (por defecto 5)")
    args = parser.parse_args(argv)
    app = DebuggerApp(serial_connector(args.baud, args.watchdog), port=args.port,
                      prog=args.prog, baud=args.baud, halt_watchdog=args.watchdog)
    app.run()
    return 0
