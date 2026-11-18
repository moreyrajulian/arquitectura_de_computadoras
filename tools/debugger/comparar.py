"""Compara la placa con el modelo de referencia (I-54).

Carga un programa en la Basys 3 con el cliente del protocolo (rvdebug), lo lleva hasta un
ciclo y compara el volcado de READ_ALL con la foto del modelo de referencia (tools/isasim,
modo completo) en ese mismo ciclo: el bloque de estado (estado, flags, palabras usadas, PC
y ciclos), los 32 registros, la memoria usada y los cuatro latches, estos en los bits de su
máscara (isasim §3: en una burbuja, solo valid y el control).

A diferencia de placa.py (el nivel 5 de verificacion.md, con los programas del plan y su
.exp), sirve para cualquier programa (.s, .hex o .bin, también uno sin .exp o sin HALT) y
para cualquier ciclo, incluso el estado que dejó una sesión del debugger.

Uso, desde la raíz del repo (necesita pyserial):

    python tools/debugger/comparar.py COM10 sw/fwd_exmem.s          # LOAD, RUN hasta HALTED
    python tools/debugger/comparar.py COM10 fwd_exmem --ciclos 7    # LOAD y 7 STEP
    python tools/debugger/comparar.py COM10 mi_prog.s --cada-ciclo  # compara después de cada STEP
    python tools/debugger/comparar.py COM10 mi_prog.s --sin-cargar  # el estado actual de la placa

Con --sin-cargar no manda LOAD ni avanza: compara lo que hay en la placa, que tiene que ser
este programa corrido desde LOAD o RESET (con STEP, RUN o STOP, por ejemplo desde el
debugger). El debugger tiene que estar cerrado: el puerto lo usa uno solo.

Código de salida: 0 si coincide, 1 si hay diferencias (o la placa no termina y el modelo
sí), 2 si no se pudo comparar (argumentos, programa, puerto, la FPGA no responde o el ciclo
está fuera de lo que simuló el modelo).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_DEBUGGER = ROOT / "tools" / "debugger"
if str(_DEBUGGER) not in sys.path:
    sys.path.insert(0, str(_DEBUGGER))

import placa  # noqa: E402  (agrega tools/isasim, tools/assembler y sw al path)
from isasim import COMPLETO, LATCHES, ModelError, simulate  # noqa: E402
from isasim.isa import HALT_WORD  # noqa: E402
from isasim.latches import WORDS  # noqa: E402
from rvasm import AssemblerError  # noqa: E402
from rvdebug import (DebugClient, DebugError, Dump, HaltTimeout, State,  # noqa: E402
                     open_serial, read_program)
from rvdebug.session import ProgramFileError  # noqa: E402

SW = ROOT / "sw"
SUFFIXES = (".s", ".hex", ".bin")
MAX_DIFFS = 30            # renglones por comparación; el resto se cuenta


def program_path(name: str) -> Path:
    """Un nombre de sw/ sin extensión (`fwd_exmem`) o una ruta a un .s, .hex o .bin."""
    return Path(name) if name.lower().endswith(SUFFIXES) else SW / f"{name}.s"


# ---- comparación --------------------------------------------------------------------------

def expected_state(snap, k: int) -> State:
    """El estado de la Debug Unit con el core en la foto `snap`, después de k ciclos."""
    if snap.halted:
        return State.HALTED
    return State.READY if k == 0 else State.PAUSED


def compare_state(dump: Dump, snap, k: int) -> list[str]:
    """El volcado de la placa contra la foto del modelo después de k ciclos."""
    diffs = []
    st = dump.status
    want_flags = placa.flags_of(snap.halted, *(name in snap.warnings
                                               for name, _ in placa.AVISOS))
    for key, got, want in (("state", st.state, expected_state(snap, k)),
                           ("flags", st.flags, want_flags),
                           ("dmem_used", st.dmem_used, len(snap.used)),
                           ("pc", st.pc, snap.pc), ("cycles", st.cycles, k)):
        if got != want:
            diffs.append(f"{key}: placa 0x{int(got):X}, modelo 0x{int(want):X}")
    for i in range(32):
        if dump.regs[i] != snap.regs[i]:
            diffs.append(f"x{i}: placa 0x{dump.regs[i]:08X}, modelo 0x{snap.regs[i]:08X}")
    got_used = dict(dump.used)
    want_used = {4 * i: v for i, v in snap.used.items()}
    for addr in sorted(set(got_used) | set(want_used)):
        got, want = got_used.get(addr), want_used.get(addr)
        if got != want:
            g = "no usada" if got is None else f"0x{got:08X}"
            w = "no usada" if want is None else f"0x{want:08X}"
            diffs.append(f"dmem[0x{addr:03X}]: placa {g}, modelo {w}")
    diffs += placa.compare_latches(dump.latches, snap)
    return diffs


def report(diffs: list[str], k: int, dump: Dump, out) -> None:
    if not diffs:
        print(f"ciclo {k}: coincide con el modelo (estado, PC, 32 registros, "
              f"{len(dump.used)} palabras de memoria usada y 4 latches)", file=out)
        return
    n = len(diffs)
    print(f"ciclo {k}: {n} {'diferencia' if n == 1 else 'diferencias'} con el modelo",
          file=out)
    for d in diffs[:MAX_DIFFS]:
        print(f"    {d}", file=out)
    if n > MAX_DIFFS:
        print(f"    ... y {n - MAX_DIFFS} más", file=out)


# ---- modos --------------------------------------------------------------------------------

def compare_run(client: DebugClient, words, r, timeout, out) -> int:
    """LOAD, RUN hasta el EVT_HALTED y READ_ALL, contra la foto final del modelo."""
    client.load(words)
    client.run()
    try:
        client.wait_halted(timeout)
    except HaltTimeout:
        st = client.stop()
        print(f"la placa no llegó a HALTED y el modelo termina en {r.cycles} ciclos; "
              f"se detuvo con STOP en el ciclo {st.cycles}", file=out)
        return 1
    dump = client.read_all()
    print(f"LOAD y RUN hasta HALTED: ciclo {dump.status.cycles}", file=out)
    diffs = compare_state(dump, r.snapshots[r.cycles], r.cycles)
    report(diffs, r.cycles, dump, out)
    return 1 if diffs else 0


def compare_steps(client: DebugClient, words, r, limit: int, every: bool, out) -> int:
    """LOAD y STEP hasta `limit` ciclos o HALTED. Con `every`, READ_ALL y comparación después
    de LOAD y de cada STEP, cortando en la primera diferencia; si no, solo al final."""
    stop = min(limit, r.cycles) if r.halted else limit     # el modelo no pasa de su HALT
    client.load(words)
    print(f"LOAD y {stop} STEP" + (", comparando cada ciclo" if every else ""), file=out)
    k = 0
    while True:
        if every or k == stop:
            dump = client.read_all()
            diffs = compare_state(dump, r.snapshots[k], k)
            if diffs or k == stop:
                break
        st = client.step()
        k += 1
        # La placa no avanzó un ciclo o terminó antes que el modelo: se compara ahí
        if st.cycles != k or (st.state == State.HALTED and k < stop):
            dump = client.read_all()
            diffs = compare_state(dump, r.snapshots[k], k)
            break
    if every and not diffs:
        print(f"{k} ciclos: todos coinciden con el modelo", file=out)
        return 0
    if every:
        print(f"primera diferencia en el ciclo {k}:", file=out)
    report(diffs, k, dump, out)
    return 1 if diffs else 0


def compare_current(client: DebugClient, r, max_cycles: int, out) -> int | None:
    """READ_ALL del estado actual, contra la foto del modelo en su ciclo. None si no se
    puede comparar (el mensaje ya está en stderr)."""
    st = client.status()
    if st.state in (State.NO_PROG, State.RUNNING):
        print(f"error: la placa está en {st.state_name}: con --sin-cargar tiene que tener el "
              "programa cargado y detenido", file=sys.stderr)
        return None
    dump = client.read_all()
    k = dump.status.cycles
    if k >= len(r.snapshots):
        if not r.halted:
            print(f"error: la placa está en el ciclo {k} y el modelo simuló {max_cycles}: "
                  "subí --max-ciclos", file=sys.stderr)
            return None
        k_model = r.cycles      # la placa siguió después del HALT del modelo: difiere
    else:
        k_model = k
    print(f"estado actual de la placa: ciclo {k}", file=out)
    diffs = compare_state(dump, r.snapshots[k_model], k_model)
    report(diffs, k, dump, out)
    return 1 if diffs else 0


# ---- línea de comandos ----------------------------------------------------------------------

def build_parser():
    ap = argparse.ArgumentParser(
        description="Compara la placa con el modelo de referencia (tools/isasim) en un "
                    "ciclo: estado, PC, registros, memoria usada y latches.")
    ap.add_argument("puerto", help="puerto serie de la Basys 3 (COM10, /dev/ttyUSB1)")
    ap.add_argument("programa", help="un .s, .hex o .bin, o el nombre de un programa de sw/")
    ap.add_argument("--ciclos", type=int, metavar="N",
                    help="en lugar de RUN, N STEP (corta en HALTED) y compara ahí")
    ap.add_argument("--cada-ciclo", action="store_true",
                    help="compara después de LOAD y de cada STEP; corta en la primera "
                         "diferencia")
    ap.add_argument("--sin-cargar", action="store_true",
                    help="no manda LOAD ni avanza: compara el estado actual de la placa")
    ap.add_argument("--timeout", type=float, default=None,
                    help="segundos de espera del EVT_HALTED (por defecto, 5)")
    ap.add_argument("--max-ciclos", type=int, default=100_000, metavar="N",
                    help="ciclos que simula el modelo para un programa sin HALT "
                         "(por defecto 100000)")
    return ap


def main(argv=None, client: DebugClient | None = None, out=sys.stdout) -> int:
    args = build_parser().parse_args(argv)
    if args.ciclos is not None and args.ciclos < 1:
        print("error: --ciclos tiene que ser al menos 1", file=sys.stderr)
        return 2
    if args.sin_cargar and (args.ciclos is not None or args.cada_ciclo):
        print("error: --sin-cargar compara sin avanzar: no va con --ciclos ni --cada-ciclo",
              file=sys.stderr)
        return 2
    path = program_path(args.programa)
    if not path.exists():
        print(f"error: no existe {path}", file=sys.stderr)
        return 2
    try:
        words = read_program(path).words
    except (AssemblerError, ProgramFileError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    try:
        if client is None:
            client = DebugClient(open_serial(args.puerto))
        info = client.connect()
    except (OSError, ImportError, DebugError) as e:
        print(f"error: no se pudo conectar con la FPGA en {args.puerto}: {e}", file=sys.stderr)
        return 2
    want_words = tuple(WORDS[l] for l in LATCHES)
    if tuple(info.latch_words) != want_words:
        print(f"error: la FPGA informa {info.latch_words} palabras por latch y el modelo "
              f"{want_words}: pipeline.md §8 y el RTL no coinciden", file=sys.stderr)
        return 2

    try:
        imem = list(words) + [HALT_WORD] * (info.imem_words - len(words))
        r = simulate(imem, mode=COMPLETO, max_cycles=args.max_ciclos)
    except ModelError as e:
        print(f"error: el modelo no puede simular {path.name}: {e}", file=sys.stderr)
        return 2
    if not r.halted and not args.sin_cargar:
        if args.ciclos is None:
            print(f"error: {path.name} no llega a HALT en {args.max_ciclos} ciclos según el "
                  "modelo: usá --ciclos N", file=sys.stderr)
            return 2
        if args.ciclos > args.max_ciclos:
            print(f"error: --ciclos {args.ciclos} supera los {args.max_ciclos} que simula el "
                  "modelo: subí --max-ciclos", file=sys.stderr)
            return 2

    print(f"INFO: protocolo {info.proto_version}, imem {info.imem_words}, dmem "
          f"{info.dmem_words}, latches {'/'.join(map(str, info.latch_words))} palabras, "
          f"{info.clk_khz} kHz", file=out)
    print(f"{path.name}: {len(words)} palabras; el modelo "
          + (f"termina en {r.cycles} ciclos" if r.halted
             else f"no llega a HALT en {args.max_ciclos} ciclos"), file=out)
    try:
        if args.sin_cargar:
            code = compare_current(client, r, args.max_ciclos, out)
            return 2 if code is None else code
        if args.ciclos is None and not args.cada_ciclo:
            return compare_run(client, words, r, args.timeout, out)
        limit = args.ciclos if args.ciclos is not None else r.cycles
        return compare_steps(client, words, r, limit, args.cada_ciclo, out)
    except DebugError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
