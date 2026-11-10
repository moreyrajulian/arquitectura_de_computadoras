"""Prepara la regresión del pipeline: varios programas de sw/ para pipeline_tb (decisión 028).

Corre scripts/prep_tb.py para cada programa del modo y escribe build/regresion/corridas.txt,
la lista que lee scripts/regresion.tcl en Vivado. Cada corrida usa +FINAL: compara los
registros de segmentación en todos los ciclos y el estado final contra el .exp
(verificacion.md §6, niveles 2 y 3). La excepción son los programas que en el modo se comparan
solo contra la traza (SOLO_TRAZA): el modelo los ejecuta igual que el RTL, pero su .exp
necesita un mecanismo que el RTL todavía no tiene, así que corren sin +FINAL.

Programas por modo (verificacion.md §4.3; las listas están en sw/programas.py):

    sin_riesgos  M7 (I-38): los del plan sin riesgos, las variantes _nops y los indep_*
    forwarding   I-39 e I-40 (decisión 029): los de sin_riesgos y los que solo necesitan
                 forwarding, y salto_depende sin +FINAL (I-40)
    forwarding_stall
                 I-41: los de forwarding, loaduse_rs1_rs2 y halt_stall, y
                 salto_depende y loaduse_sw_beq sin +FINAL
    completo     desde I-42 (por defecto): todos los programas de sw/, con +FINAL

Solo completo corresponde al RTL de master. Los otros modos describen el RTL de una
integración anterior y sirven con su commit (por ejemplo, para repetir la regresión de una
PR vieja): con el RTL de master, que siempre hace flush, fallan los programas con saltos
tomados, como las variantes _nops, indep_saltos y mem_avisos.

Uso (desde la raíz del repositorio):

    python scripts/regresion.py                           # completo, el RTL de master
    python scripts/regresion.py --modo forwarding_stall   # el RTL de I-41 (commits anteriores a I-42)
    python scripts/regresion.py --modo forwarding         # el RTL de I-39 e I-40
    python scripts/regresion.py --modo sin_riesgos        # el RTL de M7
    python scripts/regresion.py alu_r fwd_x0         # solo esos programas
    python scripts/regresion.py --pausas 47          # además, cada uno con +PAUSAS=47
    python scripts/regresion.py --mutante sin_forwarding   # la regresión con un mutante del RTL
    python scripts/regresion.py --mutante todos            # con cada mutante (scripts/mutantes.py)

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

import mutantes  # noqa: E402
import prep_tb  # noqa: E402
from programas import (COMPLETO, FORWARDING, FORWARDING_STALL, PROGRAMS,  # noqa: E402
                       SIN_RIESGOS, SOLO_TRAZA_FORWARDING, SOLO_TRAZA_FORWARDING_STALL)

PROGRAMAS = {"sin_riesgos": SIN_RIESGOS, "forwarding": FORWARDING,
             "forwarding_stall": FORWARDING_STALL, "completo": COMPLETO}
# Se suman a los del modo, pero sin +FINAL: solo la traza (verificacion.md §8.2)
SOLO_TRAZA = {"forwarding": SOLO_TRAZA_FORWARDING,
              "forwarding_stall": SOLO_TRAZA_FORWARDING_STALL}

SALIDA = ROOT / "build" / "regresion"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("programas", nargs="*",
                   help="nombres de sw/ sin .s (por defecto, todos los del modo)")
    p.add_argument("--modo", choices=PROGRAMAS, default="completo",
                   help="modo del modelo y lista de programas (por defecto completo, el RTL de "
                        "master; los otros sirven con el RTL de su integración)")
    p.add_argument("--pausas", type=int, metavar="SEMILLA",
                   help="agrega una segunda corrida de cada programa con +PAUSAS=SEMILLA")
    p.add_argument("--mutante", action="append", metavar="NOMBRE",
                   choices=[*mutantes.MUTANTES, "todos"],
                   help="corre la regresión con ese mutante del RTL (se puede repetir; 'todos' "
                        "son los de scripts/mutantes.py). regresion.tcl dice qué corridas lo detectan")
    args = p.parse_args(argv)

    solo_traza = SOLO_TRAZA.get(args.modo, [])
    nombres = args.programas or PROGRAMAS[args.modo] + solo_traza
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
    def plusargs(n):
        return "" if n in solo_traza else " FINAL"

    corridas = [f"{n} {n}{plusargs(n)}" for n in nombres]
    if args.pausas is not None:
        corridas += [f"{n}_pausas {n}{plusargs(n)} PAUSAS={args.pausas}" for n in nombres]
    SALIDA.mkdir(parents=True, exist_ok=True)
    (SALIDA / "corridas.txt").write_text("\n".join(corridas) + "\n", encoding="utf-8")

    # Mutantes (decisión 031): una línea por mutante con su nombre, el archivo original y la
    # copia mutada, relativos a la raíz. Sin --mutante se borra la lista: una regresión
    # normal nunca corre con un mutante que quedó de antes
    lista_mut = SALIDA / "mutantes.txt"
    lista_mut.unlink(missing_ok=True)
    elegidos = args.mutante or []
    if "todos" in elegidos:
        elegidos = list(mutantes.MUTANTES)
    elegidos = list(dict.fromkeys(elegidos))
    if elegidos:
        lineas = []
        for m in elegidos:
            try:
                copia = mutantes.escribir(m)
            except ValueError as e:
                print(f"error: {e}", file=sys.stderr)
                return 4
            lineas.append(f"{m} {mutantes.MUTANTES[m].archivo} {copia.relative_to(ROOT).as_posix()}")
        lista_mut.write_text("\n".join(lineas) + "\n", encoding="utf-8")

    sin_final = [n for n in nombres if n in solo_traza]
    nota = f", sin +FINAL: {', '.join(sin_final)}" if sin_final else ""
    print(f"{len(corridas)} corridas ({args.modo}{nota}) en {SALIDA / 'corridas.txt'}")
    if elegidos:
        print(f"{len(elegidos)} mutantes, cada uno con todas las corridas: {', '.join(elegidos)}")
    print(f"Vivado: source {(ROOT / 'scripts' / 'regresion.tcl').as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
