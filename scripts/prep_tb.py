"""Prepara un programa de sw/ para el banco de pruebas incremental (I-17).

Escribe en build/tb/<programa>/ todo lo que lee tb/integration/pipeline_tb.v, con
nombres fijos para que el banco no cambie de un programa a otro (decisión 021):

    imem.hex                 programa, 1024 palabras rellenas con HALT (como LOAD)
    regs_init.hex            estado inicial de los registros (indep_*) o ceros
    dmem_init.hex            estado inicial de dmem (indep_*) o ceros
    modelo.ciclo.<latch>.hex traza por ciclo del modelo de referencia (decisión 020)
    modelo.ciclo.<latch>.mask.hex
    modelo.traza.txt         la misma traza, legible (para depurar)
    corte.hex                largo de la traza y ciclos de corte (ver CORTE)
    exp_regs.hex             .exp escrito a mano, pasado a $readmemh
    exp_dmem.hex
    exp_misc.hex             halted, pipeline_vacio, avisos, ciclos

Uso (desde la raíz del repositorio):

    python scripts/prep_tb.py sw/indep_alu_r.s
    python scripts/prep_tb.py sw/alu_r.s --modo completo
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "isasim"))

from isasim import (COMPLETO, SIN_RIESGOS, LATCHES, ModelError,  # noqa: E402
                    compare_exp, load_initial_state, load_program, parse_exp,
                    simulate, write_outputs)
from isasim.files import default_initial_state  # noqa: E402
from isasim.isa import DMEM_WORDS, HALT_WORD  # noqa: E402

MODOS = {"sin_riesgos": SIN_RIESGOS, "completo": COMPLETO}

# Orden de las líneas de corte.hex (el banco las lee por posición)
CORTE = ["lineas", "halt_if_id", "halt_id_ex", "halt_ex_mem", "halt_mem_wb", "redirect"]

# Bits de avisos en exp_misc.hex (mismo orden que el bloque de estado)
AVISO_BIT = {"imem_fault": 2, "dmem_oob": 1, "dmem_misaligned": 0}


def write_words(path, words, comment):
    lines = [f"// {comment}"] + [f"{w & 0xFFFF_FFFF:08X}" for w in words]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def halt_in(latch, values):
    """Hay un HALT válido en el latch (IF/ID no tiene bit halt: se mira la palabra)."""
    if not values["valid"]:
        return False
    if latch == "if_id":
        return values["instr"] == HALT_WORD
    return bool(values["halt"])


def cortes(r):
    """Ciclos de corte: primer ciclo con el HALT en cada latch y primer redirect (0 = no hay)."""
    out = {"lineas": len(r.snapshots)}
    for latch in LATCHES:
        out[f"halt_{latch}"] = next(
            (s.cycle for s in r.snapshots if halt_in(latch, s.values[latch])), 0)
    out["redirect"] = next(
        (s.cycle for s in r.snapshots if any(e.startswith("redirect") for e in s.events)), 0)
    return out


def exp_files(exp, outdir):
    """El .exp escrito a mano, en tres archivos $readmemh (verificacion.md §5)."""
    regs = [exp["regs"].get(i, 0) for i in range(32)]
    dmem = [0] * DMEM_WORDS
    for addr, value in exp["dmem"].items():
        if addr % 4:
            raise ModelError(f"dirección 0x{addr:03X} del .exp no alineada")
        dmem[addr // 4] = value
    avisos = 0
    texto = exp.get("avisos", "ninguno").strip()
    if texto != "ninguno":
        for nombre in (a.strip() for a in texto.split(",")):
            if nombre not in AVISO_BIT:
                raise ModelError(f"aviso desconocido en el .exp: {nombre!r}")
            avisos |= 1 << AVISO_BIT[nombre]
    misc = [int(exp.get("halted", "1")), int(exp.get("pipeline_vacio", "1")), avisos,
            int(exp["ciclos"].split()[0])]
    write_words(outdir / "exp_regs.hex", regs, "registros x0..x31 esperados (.exp)")
    write_words(outdir / "exp_dmem.hex", dmem, "dmem esperada, por palabra (.exp)")
    write_words(outdir / "exp_misc.hex", misc,
                "halted, pipeline_vacio, avisos {imem_fault, dmem_oob, dmem_misaligned}, ciclos")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("programa", help="programa .s de sw/")
    p.add_argument("--modo", choices=MODOS, default="sin_riesgos",
                   help="modo del modelo: sin_riesgos (M3 a M7, por defecto) o completo (M8)")
    p.add_argument("-o", "--salida", default=str(ROOT / "build" / "tb"),
                   help="directorio base (por defecto build/tb)")
    args = p.parse_args(argv)

    prog = Path(args.programa)
    if not prog.exists():
        print(f"error: no existe {prog}", file=sys.stderr)
        return 2
    outdir = Path(args.salida).resolve() / prog.stem
    outdir.mkdir(parents=True, exist_ok=True)

    try:
        imem = load_program(prog)
        init = default_initial_state(prog)
        regs, dmem = load_initial_state(init) if init else ([0] * 32, [0] * DMEM_WORDS)
        r = simulate(imem, regs, dmem, MODOS[args.modo])
    except ModelError as e:
        print(f"error: {e}", file=sys.stderr)
        return 3
    if not r.halted:
        print("error: el programa no llega al HALT", file=sys.stderr)
        return 3

    write_words(outdir / "imem.hex", imem, f"{prog.name}: imem completa, rellena con HALT")
    write_words(outdir / "regs_init.hex", regs,
                f"registros iniciales ({init.name if init else 'todo en cero'})")
    write_words(outdir / "dmem_init.hex", dmem,
                f"dmem inicial ({init.name if init else 'todo en cero'})")
    write_outputs(r, outdir, "modelo")
    c = cortes(r)
    write_words(outdir / "corte.hex", [c[k] for k in CORTE], ", ".join(CORTE))

    exp_path = prog.with_suffix(".exp")
    if exp_path.exists():
        exp = parse_exp(exp_path.read_text(encoding="utf-8"))
        exp_files(exp, outdir)
        diffs = compare_exp(r, exp)
        if diffs:
            print(f"aviso: el modelo ({args.modo}) difiere de {exp_path.name}:",
                  *diffs, sep="\n  ", file=sys.stderr)
    else:
        for name in ("exp_regs.hex", "exp_dmem.hex", "exp_misc.hex"):
            (outdir / name).unlink(missing_ok=True)
        print(f"aviso: {exp_path.name} no existe; +FINAL no se puede usar", file=sys.stderr)

    print(f"{prog.stem}: modo {args.modo}, {r.cycles} ciclos, "
          f"HALT en IF/ID {c['halt_if_id']}, ID/EX {c['halt_id_ex']}, "
          f"EX/MEM {c['halt_ex_mem']}, MEM/WB {c['halt_mem_wb']}, "
          f"primer redirect {c['redirect'] or '-'}")
    print(f"archivos en {outdir}")
    print("xsim:   -testplusarg DIR=" + outdir.as_posix())
    print("Vivado: set_property -name {xsim.simulate.xsim.more_options} "
          f"-value {{-testplusarg DIR={outdir.as_posix()}}} -objects [get_filesets sim_1]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
