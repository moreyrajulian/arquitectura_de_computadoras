"""Linea de comandos: python tools/assembler/asm.py programa.s -o programa.hex"""

import argparse
import sys
from pathlib import Path

from .assembler import AssemblerError, assemble
from .output import FORMATS, render

EXIT_OK, EXIT_ASM_ERROR, EXIT_USAGE = 0, 1, 2


def _format_of(path: Path, forced: str | None) -> str:
    if forced:
        return forced
    ext = path.suffix.lower().lstrip(".")
    if ext not in FORMATS:
        raise ValueError(f"no se reconoce el formato de '{path}': usar extension "
                         f"{', '.join('.' + f for f in FORMATS)} o -f")
    return ext


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="asm.py",
        description="Ensamblador del subconjunto RV32I del procesador (docs/spec/isa.md).")
    parser.add_argument("source", type=Path, help="programa en ensamblador (.s)")
    parser.add_argument("-o", "--output", type=Path, action="append", default=[],
                        help="archivo de salida; el formato sale de la extension "
                             "(.hex, .bin, .coe, .lst). Se puede repetir. Sin -o, hex por stdout")
    parser.add_argument("-f", "--format", choices=FORMATS,
                        help="fuerza el formato (de todas las salidas o de stdout)")
    parser.add_argument("--fill", action="store_true",
                        help="completa hex/bin/coe hasta 1024 palabras con HALT, "
                             "como queda la memoria despues de LOAD")
    parser.add_argument("-W", "--no-warnings", action="store_true", help="no mostrar advertencias")
    args = parser.parse_args(argv)

    try:
        source = args.source.read_text(encoding="utf-8")
    except OSError as e:
        print(f"asm.py: error: no se puede leer '{args.source}': {e.strerror}", file=sys.stderr)
        return EXIT_USAGE

    try:
        program = assemble(source, str(args.source))
    except AssemblerError as e:
        for err in e.errors:
            print(err, file=sys.stderr)
        n = len(e.errors)
        print(f"{n} error{'es' if n != 1 else ''}; no se genero salida", file=sys.stderr)
        return EXIT_ASM_ERROR

    if not args.no_warnings:
        for w in program.warnings:
            print(w, file=sys.stderr)

    try:
        if not args.output:
            data = render(program, args.format or "hex", args.fill, args.source.name)
            if args.format == "bin":
                sys.stdout.buffer.write(data)
            else:
                sys.stdout.write(data.decode())
        for out in args.output:
            fmt = _format_of(out, args.format)
            out.write_bytes(render(program, fmt, args.fill, args.source.name))
    except (ValueError, OSError) as e:
        print(f"asm.py: error: {e}", file=sys.stderr)
        return EXIT_USAGE
    return EXIT_OK
