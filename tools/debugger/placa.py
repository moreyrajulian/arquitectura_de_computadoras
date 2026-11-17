"""Prueba en placa (nivel 5 de verificacion.md, I-49 e I-55).

Carga programas de sw/ en la Basys 3 con el cliente del protocolo (rvdebug) y compara lo
que devuelve la Debug Unit con dos oráculos escritos por separado:

- el `.exp` escrito a mano (verificacion.md §5): registros, dmem, halted, avisos,
  pipeline_vacio y ciclos;
- el modelo de referencia (tools/isasim, modo completo): el bloque de estado entero
  (también el PC), los registros, la memoria usada y los latches, ciclo por ciclo.

Por cada programa hace dos pasadas:

1. LOAD, RUN hasta el EVT_HALTED y READ_ALL: contra el .exp y contra el estado final del
   modelo.
2. RESET y STEP hasta HALTED, con READ_LATCHES después de cada paso: cada latch contra
   la foto del modelo en ese ciclo, comparando los bits de su máscara (isasim §3: en una
   burbuja, solo valid y el control). Al final, READ_ALL tiene que dar lo mismo que con RUN
   (el criterio del nivel 4, ahora en la placa). Se saltea con --sin-paso.

Uso, desde la raíz del repo (necesita pyserial):

    python tools/debugger/placa.py COM10                   # los 22 programas del plan
    python tools/debugger/placa.py /dev/ttyUSB1 fwd_exmem mixto_lazo
    python tools/debugger/placa.py COM10 --nops            # más las variantes _nops
    python tools/debugger/placa.py COM10 --sin-paso        # solo RUN

Los programas indep_* no se pueden correr: empiezan de un estado inicial de registros
(sw/estado_inicial) que el protocolo no puede cargar, porque LOAD y RESET ponen el banco
en cero (memoria.md §4.1).

Código de salida: 0 si todos coinciden, 1 si alguno falla, 2 si no se pudo probar
(argumentos, puerto o la FPGA no responde).
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
for _path in (ROOT / "tools" / "debugger", ROOT / "tools" / "isasim",
              ROOT / "tools" / "assembler", ROOT / "sw"):
    if str(_path) not in sys.path:
        sys.path.insert(0, str(_path))

from isasim import COMPLETO, LATCHES, WIDTH, parse_exp, simulate, unpack  # noqa: E402
from isasim.isa import HALT_WORD, IMEM_WORDS  # noqa: E402
from isasim.latches import WORDS  # noqa: E402
from programas import INDEP, NOPS, PLAN  # noqa: E402
from rvasm import assemble  # noqa: E402
from rvdebug import (DebugClient, DebugError, Dump, Latches, NoResponseError, State,  # noqa: E402
                     open_serial)
from rvdebug.protocol import (FLAG_DMEM_MISALIGNED, FLAG_DMEM_OOB, FLAG_HALTED,  # noqa: E402
                              FLAG_IMEM_FAULT, FLAG_PROG_VALID)

SW = ROOT / "sw"
TITLES = {"if_id": "IF/ID", "id_ex": "ID/EX", "ex_mem": "EX/MEM", "mem_wb": "MEM/WB"}
AVISOS = (("imem_fault", FLAG_IMEM_FAULT), ("dmem_oob", FLAG_DMEM_OOB),
          ("dmem_misaligned", FLAG_DMEM_MISALIGNED))
MAX_DIFFS = 12            # renglones por pasada; el resto se cuenta


# ---- programas ------------------------------------------------------------------------

def program_paths(names, nops=False):
    """Los .s a probar: los nombrados (nombre de sw/ o ruta), o el plan (más las
    variantes _nops con `nops`). Levanta ValueError con un indep_* o un nombre que no
    existe."""
    if not names:
        names = list(PLAN) + ([f"{n}_nops" for n in NOPS] if nops else [])
    paths = []
    for name in names:
        path = Path(name) if name.endswith(".s") else SW / f"{name}.s"
        if path.stem in INDEP:
            raise ValueError(f"{path.stem}: los indep_* necesitan el estado inicial de "
                             "sw/estado_inicial, y LOAD deja el banco en cero")
        if not path.exists():
            raise ValueError(f"{name}: no existe {path}")
        if not path.with_suffix(".exp").exists():
            raise ValueError(f"{path.stem}: falta {path.with_suffix('.exp').name}")
        paths.append(path)
    return paths


# ---- comparaciones --------------------------------------------------------------------

def flags_of(halted, imem_fault, dmem_oob, dmem_misaligned):
    return (FLAG_PROG_VALID | (FLAG_HALTED if halted else 0)
            | (FLAG_IMEM_FAULT if imem_fault else 0) | (FLAG_DMEM_OOB if dmem_oob else 0)
            | (FLAG_DMEM_MISALIGNED if dmem_misaligned else 0))


def dmem_of(dump: Dump) -> dict[int, int]:
    """dmem completa según la placa: después de LOAD vale 0 todo lo que no se escribió,
    así que las palabras usadas alcanzan."""
    return {addr: value for addr, value in dump.used}


def valid_of(latch: str, number: int) -> int:
    return (number >> (WIDTH[latch] - 1)) & 1


def compare_exp(dump: Dump, exp: dict) -> list[str]:
    """La placa contra el .exp escrito a mano (verificacion.md §5)."""
    diffs = []
    for i in range(32):
        want = exp["regs"].get(i, 0)
        if dump.regs[i] != want:
            diffs.append(f"x{i}: placa 0x{dump.regs[i]:08X}, .exp 0x{want:08X}")
    got_dmem = dmem_of(dump)
    for addr in sorted(set(got_dmem) | set(exp["dmem"])):
        got, want = got_dmem.get(addr, 0), exp["dmem"].get(addr, 0)
        if got != want:
            diffs.append(f"dmem[0x{addr:03X}]: placa 0x{got:08X}, .exp 0x{want:08X}")
    st = dump.status
    vacio = int(all(valid_of(l, dump.latches.packed(l)) == 0 for l in LATCHES))
    for key, got in (("halted", str(int(st.halted))), ("pipeline_vacio", str(vacio)),
                     ("ciclos", str(st.cycles))):
        if key in exp and exp[key].split()[0] != got:
            diffs.append(f"{key}: placa {got}, .exp {exp[key].split()[0]}")
    if "avisos" in exp:
        want = {a.strip() for a in exp["avisos"].split(",")} - {"ninguno"}
        got = {name for name, bit in AVISOS if st.flags & bit}
        if want != got:
            diffs.append(f"avisos: placa {', '.join(sorted(got)) or 'ninguno'}, "
                         f".exp {', '.join(sorted(want)) or 'ninguno'}")
    return diffs


def compare_latch(latch: str, got: int, snapshot, where: str) -> list[str]:
    """Un latch de la placa contra la foto del modelo, en los bits de su máscara. Los bits
    de relleno de la última palabra tienen que valer 0 (protocolo_debug.md §3.6)."""
    diffs = []
    mask = snapshot.mask(latch)
    want = snapshot.packed(latch)
    if got >> WIDTH[latch]:
        diffs.append(f"{where}{TITLES[latch]}: relleno distinto de 0 "
                     f"(0x{got >> WIDTH[latch]:X})")
        got &= (1 << WIDTH[latch]) - 1
    if (got ^ want) & mask:
        g, w, m = unpack(latch, got), unpack(latch, want), unpack(latch, mask)
        for name in g:
            if (g[name] ^ w[name]) & m[name]:
                diffs.append(f"{where}{TITLES[latch]}.{name}: placa 0x{g[name]:X}, "
                             f"modelo 0x{w[name]:X}")
    return diffs


def compare_latches(latches: Latches, snapshot, where: str = "") -> list[str]:
    diffs = []
    for latch in LATCHES:
        diffs += compare_latch(latch, latches.packed(latch), snapshot, where)
    return diffs


def compare_model(dump: Dump, r) -> list[str]:
    """La placa contra el estado final del modelo de referencia."""
    diffs = []
    st = dump.status
    want_state = State.HALTED if r.halted else State.PAUSED
    want_flags = flags_of(r.halted, r.imem_fault, r.dmem_oob, r.dmem_misaligned)
    for key, got, want in (("state", st.state, want_state), ("flags", st.flags, want_flags),
                           ("dmem_used", st.dmem_used, len(r.used)), ("pc", st.pc, r.pc),
                           ("cycles", st.cycles, r.cycles)):
        if got != want:
            diffs.append(f"{key}: placa 0x{int(got):X}, modelo 0x{int(want):X}")
    for i in range(32):
        if dump.regs[i] != r.regs[i]:
            diffs.append(f"x{i}: placa 0x{dump.regs[i]:08X}, modelo 0x{r.regs[i]:08X}")
    want_used = tuple((4 * i, r.dmem[i]) for i in sorted(r.used))
    if dump.used != want_used:
        diffs.append("memoria usada: placa "
                     + (" ".join(f"{a:03X}={v:08X}" for a, v in dump.used) or "vacía")
                     + ", modelo "
                     + (" ".join(f"{a:03X}={v:08X}" for a, v in want_used) or "vacía"))
    diffs += compare_latches(dump.latches, r.final, "final ")
    return diffs


def compare_dumps(step: Dump, run: Dump) -> list[str]:
    """El volcado después de STEP repetido contra el de RUN: tienen que ser iguales."""
    diffs = []
    if step.status != run.status:
        diffs.append(f"bloque de estado: STEP {step.status}, RUN {run.status}")
    for i in range(32):
        if step.regs[i] != run.regs[i]:
            diffs.append(f"x{i}: STEP 0x{step.regs[i]:08X}, RUN 0x{run.regs[i]:08X}")
    if step.used != run.used:
        diffs.append("memoria usada distinta")
    for latch in LATCHES:
        if step.latches.packed(latch) != run.latches.packed(latch):
            diffs.append(f"{TITLES[latch]} distinto")
    return diffs


# ---- una corrida -----------------------------------------------------------------------

@dataclass
class Result:
    name: str
    cycles: int = 0
    steps: int = 0
    diffs: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.diffs


def verify_program(client: DebugClient, path: Path, step: bool = True,
                  halt_timeout: float | None = None) -> Result:
    """Las dos pasadas sobre un programa. NoResponseError sale de acá: sin respuesta no
    tiene sentido seguir con los demás."""
    res = Result(path.stem)
    words = assemble(path.read_text(encoding="utf-8"), path.name).words
    exp = parse_exp(path.with_suffix(".exp").read_text(encoding="utf-8"))
    r = simulate(list(words) + [HALT_WORD] * (IMEM_WORDS - len(words)), mode=COMPLETO)
    res.cycles = r.cycles

    def add(prefix, diffs):
        res.diffs.extend(f"{prefix}: {d}" for d in diffs)

    try:
        # Pasada 1: RUN
        st = client.load(words)
        if st.state != State.READY:
            add("LOAD", [f"estado {st.state_name}, se esperaba READY"])
            return res
        client.run()
        client.wait_halted(halt_timeout)
        run = client.read_all()
        add("RUN vs .exp", compare_exp(run, exp))
        add("RUN vs modelo", compare_model(run, r))
        if not step:
            return res

        # Pasada 2: STEP, con los latches de cada ciclo
        st = client.reset()
        if st.state != State.READY:
            add("RESET", [f"estado {st.state_name}, se esperaba READY"])
            return res
        diffs = []
        for k in range(1, r.cycles + 1):
            st = client.step()
            res.steps = k
            want_state = State.HALTED if k == r.cycles else State.PAUSED
            if st.cycles != k or st.state != want_state:
                diffs.append(f"paso {k}: estado {st.state_name} y cycles {st.cycles}, "
                             f"modelo {want_state.name} y {k}")
                break
            diffs += compare_latches(client.read_latches(), r.snapshots[k], f"paso {k}: ")
            if len(diffs) > MAX_DIFFS:
                break
        add("STEP vs modelo", diffs)
        if st.state == State.HALTED:
            add("STEP vs RUN", compare_dumps(client.read_all(), run))
    except NoResponseError:
        raise
    except DebugError as e:
        add("protocolo", [str(e)])
    return res


# ---- línea de comandos ------------------------------------------------------------------

def report(res: Result, out) -> None:
    detail = f"RUN: {res.cycles} ciclos" + (f"; STEP: {res.steps} pasos" if res.steps else "")
    print(f"{res.name:<26} {'OK   ' if res.ok else 'FALLA'} ({detail})", file=out)
    for d in res.diffs[:MAX_DIFFS]:
        print(f"    {d}", file=out)
    if len(res.diffs) > MAX_DIFFS:
        print(f"    ... y {len(res.diffs) - MAX_DIFFS} diferencias más", file=out)


def build_parser():
    ap = argparse.ArgumentParser(
        description="Prueba en placa: corre programas de sw/ en la Basys 3 y los compara "
                    "con el .exp y con el modelo de referencia (verificacion.md, nivel 5).")
    ap.add_argument("puerto", help="puerto serie de la Basys 3 (COM10, /dev/ttyUSB1)")
    ap.add_argument("programas", nargs="*",
                    help="nombres de sw/ o rutas a .s; por defecto, los 22 del plan")
    ap.add_argument("--nops", action="store_true",
                    help="suma las variantes _nops (solo sin programas nombrados)")
    ap.add_argument("--sin-paso", action="store_true",
                    help="solo la pasada con RUN, sin STEP ni latches por ciclo")
    ap.add_argument("--timeout", type=float, default=None,
                    help="segundos de espera del EVT_HALTED (por defecto, 5)")
    return ap


def main(argv=None, client: DebugClient | None = None, out=sys.stdout) -> int:
    args = build_parser().parse_args(argv)
    try:
        paths = program_paths(args.programas, args.nops)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    try:
        if client is None:
            client = DebugClient(open_serial(args.puerto))
        info = client.connect()
    except (OSError, ImportError, DebugError) as e:
        print(f"error: no se pudo conectar con la FPGA en {args.puerto}: {e}", file=sys.stderr)
        return 2
    print(f"INFO: protocolo {info.proto_version}, imem {info.imem_words}, dmem "
          f"{info.dmem_words}, latches {'/'.join(map(str, info.latch_words))} palabras, "
          f"{info.clk_khz} kHz", file=out)
    want_words = tuple(WORDS[l] for l in LATCHES)
    if tuple(info.latch_words) != want_words:
        print(f"error: la FPGA informa {info.latch_words} palabras por latch y el modelo "
              f"{want_words}: pipeline.md §8 y el RTL no coinciden", file=sys.stderr)
        return 2

    results = []
    for path in paths:
        try:
            res = verify_program(client, path, step=not args.sin_paso,
                                halt_timeout=args.timeout)
        except NoResponseError as e:
            print(f"error: la FPGA dejó de responder en {path.stem}: {e}", file=sys.stderr)
            return 2
        report(res, out)
        results.append(res)
    bad = [res.name for res in results if not res.ok]
    print(f"{len(results)} programas: {len(results) - len(bad)} OK"
          + (f", {len(bad)} con diferencias ({', '.join(bad)})" if bad else ""), file=out)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
