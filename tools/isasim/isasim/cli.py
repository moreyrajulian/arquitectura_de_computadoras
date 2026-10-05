"""Línea de comandos del modelo de referencia."""

import argparse
import sys
from pathlib import Path

from .files import (compare_exp, default_initial_state, format_exp, load_initial_state,
                    load_program, parse_exp, write_outputs)
from .isa import ModelError
from .pipeline import COMPLETO, SIN_RIESGOS, Mode, simulate

MODOS = {"completo": COMPLETO, "sin_riesgos": SIN_RIESGOS}


def build_parser():
    p = argparse.ArgumentParser(
        prog="sim.py",
        description="Modelo de referencia: ejecuta un programa y genera el estado final "
                    "y la traza de los registros de segmentación.")
    p.add_argument("programa", help="programa .s (se ensambla con rvasm) o .hex")
    p.add_argument("--modo", choices=MODOS, default="completo",
                   help="completo (M8 en adelante) o sin_riesgos (M7: sin forwarding, "
                        "stall ni flush por saltos)")
    p.add_argument("--sin-forwarding", action="store_true")
    p.add_argument("--sin-stall", action="store_true")
    p.add_argument("--sin-flush", action="store_true")
    p.add_argument("--estado-inicial", metavar="DIR",
                   help="directorio con regs.hex y dmem.hex. Por defecto, los programas "
                        "indep_* usan estado_inicial/ junto al programa (sw/README.md)")
    p.add_argument("--exp", metavar="ARCHIVO",
                   help="compara con un .exp; con 'auto' usa el .exp junto al programa")
    p.add_argument("-o", "--salida", metavar="DIR",
                   help="escribe el estado, el volcado y las trazas en DIR")
    p.add_argument("--max-ciclos", type=int, default=100_000,
                   help="límite para programas sin HALT (por defecto 100000)")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    prog = Path(args.programa)
    if not prog.exists():
        print(f"error: no existe {prog}", file=sys.stderr)
        return 2
    base = MODOS[args.modo]
    mode = Mode(base.forwarding and not args.sin_forwarding,
                base.stall and not args.sin_stall,
                base.flush and not args.sin_flush)
    try:
        imem = load_program(prog)
        init = args.estado_inicial or default_initial_state(prog)
        regs, dmem = load_initial_state(init) if init else (None, None)
        r = simulate(imem, regs, dmem, mode, args.max_ciclos)
    except ModelError as e:
        print(f"error: {e}", file=sys.stderr)
        return 3

    print(format_exp(r, prog.stem), end="")
    if not r.halted:
        print(f"aviso: sin HALT en {args.max_ciclos} ciclos", file=sys.stderr)
    if args.salida:
        out = write_outputs(r, args.salida, prog.stem)
        print(f"# archivos en {out}/", file=sys.stderr)
    if args.exp:
        exp_path = prog.with_suffix(".exp") if args.exp == "auto" else Path(args.exp)
        diffs = compare_exp(r, parse_exp(exp_path.read_text(encoding="utf-8")))
        if diffs:
            print(f"DIFIERE de {exp_path}:", *diffs, sep="\n  ", file=sys.stderr)
            return 1
        print(f"# coincide con {exp_path}", file=sys.stderr)
    return 0
