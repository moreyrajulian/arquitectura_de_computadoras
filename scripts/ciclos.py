"""Ciclos por programa y costo de los stalls y del flush (verificacion.md §5 y §8.8, I-43).

Corre cada programa de sw/ en el modelo de referencia (tools/isasim, modo completo) y cuenta,
desde la traza ciclo a ciclo:

    n        instrucciones que llegan válidas a WB (las ejecutadas, el HALT incluido)
    stalls   ciclos con stall de carga-uso; entre paréntesis, los falsos positivos de la
             comparación conservadora (decisión 011): la instrucción frenada no usa el registro
    saltos   saltos tomados (beq/bne tomados, jal, jalr): cada uno cuesta 2 ciclos de flush

y comprueba que ciclos = n + 4 + stalls + 2 · saltos y que coincide con el `ciclos` del .exp,
escrito a mano. El RTL lo compara pipeline_tb con +FINAL (§8.7), así que con la regresión
aprobada los tres dan el mismo número. Imprime la tabla de §8.8 en Markdown: los 22 programas
del plan y, si tienen variante _nops, sus ciclos (lo que cuesta resolver los riesgos con nop,
sin forwarding, stall ni flush).

Usa isasim como biblioteca, como prep_tb.py, sin cambiar la herramienta.

Uso (desde la raíz del repositorio):

    python scripts/ciclos.py            # tabla de los 22 programas del plan
    python scripts/ciclos.py --todos    # todos los programas de sw/
"""

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "isasim"))
sys.path.insert(0, str(ROOT / "sw"))

from isasim import COMPLETO, decode, load_initial_state, load_program, parse_exp, simulate  # noqa: E402
from isasim.files import default_initial_state  # noqa: E402
from programas import PLAN, PROGRAMS  # noqa: E402

SW = ROOT / "sw"
LLENADO = 4             # el HALT entra a IF en el ciclo n y llega a WB 4 ciclos después
COSTO_SALTO = 2         # pipeline.md §10.5, decisión 012


@dataclass
class Ciclos:
    nombre: str
    n: int
    stalls: int
    falsos: int
    saltos: int
    ciclos: int
    exp: int

    @property
    def formula(self):
        return self.n + LLENADO + self.stalls + COSTO_SALTO * self.saltos


def contar(nombre):
    """Corre el programa en modo completo y cuenta n, stalls, falsos positivos y saltos."""
    prog = SW / f"{nombre}.s"
    init = default_initial_state(prog)
    regs, dmem = load_initial_state(init) if init else (None, None)
    r = simulate(load_program(prog), regs, dmem, COMPLETO)
    n = stalls = falsos = saltos = 0
    for snap in r.snapshots[:r.cycles]:          # sin la foto final
        v = snap.values
        n += v["mem_wb"]["valid"]
        saltos += any(e.startswith("redirect") for e in snap.events)
        if "stall" in snap.events:
            stalls += 1
            rd = v["id_ex"]["rd"]
            ins = decode(v["if_id"]["instr"])
            usa = (ins.reads_rs1 and ins.rs1 == rd) or (ins.reads_rs2 and ins.rs2 == rd)
            falsos += not usa
    exp = int(parse_exp((SW / f"{nombre}.exp").read_text(encoding="utf-8"))["ciclos"])
    return Ciclos(nombre, n, stalls, falsos, saltos, r.cycles, exp)


def porcentaje(parte, total):
    return f"{100 * parte / total:.0f} %" if parte else "—"


def con_falsos(c):
    """Stalls con los falsos positivos entre paréntesis: 5, o 1 (1 falso)."""
    if not c.falsos:
        return str(c.stalls)
    return f"{c.stalls} ({c.falsos} falso{'s' if c.falsos > 1 else ''})"


def fila(c, nops):
    stalls = con_falsos(c)
    variante = f"{nops.ciclos} (+{nops.ciclos - c.ciclos})" if nops else "—"
    return (f"| `{c.nombre}` | {c.n} | {stalls} | {c.saltos} | {c.ciclos} | "
            f"{c.ciclos / c.n:.2f} | {porcentaje(c.stalls, c.ciclos)} | "
            f"{porcentaje(COSTO_SALTO * c.saltos, c.ciclos)} | {variante} |")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--todos", action="store_true", help="todos los programas de sw/, no solo el plan")
    args = p.parse_args(argv)

    nombres = PROGRAMS if args.todos else PLAN
    datos = {n: contar(n) for n in set(nombres) | {f"{n}_nops" for n in nombres} if n in PROGRAMS}

    errores = []
    for c in datos.values():
        if c.ciclos != c.formula:
            errores.append(f"{c.nombre}: el modelo da {c.ciclos} ciclos y la fórmula {c.formula} "
                           f"(n = {c.n}, {c.stalls} stalls, {c.saltos} saltos tomados)")
        if c.ciclos != c.exp:
            errores.append(f"{c.nombre}: el modelo da {c.ciclos} ciclos y el .exp {c.exp}")
    if errores:
        print("error:", *errores, sep="\n  ", file=sys.stderr)
        return 1

    print("| Programa | `n` | Stalls | Saltos tomados | Ciclos | CPI | Stalls | Flush | Con `_nops` |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    filas = [datos[n] for n in nombres]
    for c in filas:
        print(fila(c, datos.get(f"{c.nombre}_nops")))
    tot = Ciclos("total", *(sum(getattr(c, f) for c in filas)
                            for f in ("n", "stalls", "falsos", "saltos", "ciclos", "exp")))
    print(f"| **Total** | {tot.n} | {con_falsos(tot)} | {tot.saltos} | "
          f"{tot.ciclos} | {tot.ciclos / tot.n:.2f} | {porcentaje(tot.stalls, tot.ciclos)} | "
          f"{porcentaje(COSTO_SALTO * tot.saltos, tot.ciclos)} | |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
