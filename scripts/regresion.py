"""Prepara la regresión del pipeline: varios programas de sw/ para pipeline_tb (decisión 028).

Corre scripts/prep_tb.py para cada programa del modo y escribe build/regresion/corridas.txt,
la lista que lee scripts/regresion.tcl en Vivado. Cada corrida usa +FINAL: compara los
registros de segmentación en todos los ciclos y el estado final contra el .exp
(verificacion.md §6, niveles 2 y 3).

Programas por modo (verificacion.md §4.3; las listas están en sw/programas.py):

    sin_riesgos  M7 (I-38): los del plan sin riesgos, las variantes _nops y los indep_*
    completo     M8 (I-43): todos los programas de sw/

Uso (desde la raíz del repositorio):

    python scripts/regresion.py                      # sin_riesgos
    python scripts/regresion.py --modo completo
    python scripts/regresion.py alu_r fwd_x0         # solo esos programas
    python scripts/regresion.py --pausas 47          # además, cada uno con +PAUSAS=47

Después, en la consola Tcl de Vivado:

    source <ruta-al-repo>/scripts/regresion.tcl
"""

import argparse
import contextlib
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "sw"))

import prep_tb  # noqa: E402
from programas import PROGRAMS, SIN_RIESGOS  # noqa: E402

PROGRAMAS = {"sin_riesgos": SIN_RIESGOS, "completo": PROGRAMS}

SALIDA = ROOT / "build" / "regresion"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("programas", nargs="*",
                   help="nombres de sw/ sin .s (por defecto, todos los del modo)")
    p.add_argument("--modo", choices=PROGRAMAS, default="sin_riesgos",
                   help="modo del modelo y lista de programas (por defecto sin_riesgos)")
    p.add_argument("--pausas", type=int, metavar="SEMILLA",
                   help="agrega una segunda corrida de cada programa con +PAUSAS=SEMILLA")
    args = p.parse_args(argv)

    nombres = args.programas or PROGRAMAS[args.modo]
    faltan = [n for n in nombres if n not in PROGRAMS]
    if faltan:
        print(f"error: no existen en sw/: {', '.join(faltan)}", file=sys.stderr)
        return 2

    errores = []
    for n in nombres:
        salida = io.StringIO()
        with contextlib.redirect_stdout(salida):
            rc = prep_tb.main([str(ROOT / "sw" / f"{n}.s"), "--modo", args.modo])
        if rc != 0:
            errores.append(n)
            continue
        print(salida.getvalue().splitlines()[0])
    if errores:
        print(f"error: prep_tb.py falló en {', '.join(errores)}", file=sys.stderr)
        return 3

    # Una corrida por línea: etiqueta, programa y plusargs además de DIR
    corridas = [f"{n} {n} FINAL" for n in nombres]
    if args.pausas is not None:
        corridas += [f"{n}_pausas {n} FINAL PAUSAS={args.pausas}" for n in nombres]
    SALIDA.mkdir(parents=True, exist_ok=True)
    (SALIDA / "corridas.txt").write_text("\n".join(corridas) + "\n", encoding="utf-8")

    print(f"{len(corridas)} corridas ({args.modo}) en {SALIDA / 'corridas.txt'}")
    print(f"Vivado: source {(ROOT / 'scripts' / 'regresion.tcl').as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
