"""Capa `session` de la interfaz (docs/spec/interfaz_pc.md §1, decisiones 040 y 043): las
secuencias de comandos de cada control, qué controles se pueden usar en cada estado y el
historial de volcados. Python puro, sin Textual: la TUI llama a estos métodos desde un hilo
de trabajo y solo dibuja lo que devuelven.

Cada acción que cambia el procesador termina con un READ_ALL (interfaz_pc.md §3), salvo
RUN, que termina cuando llega el final de la ejecución (§5). Cada READ_ALL agrega un
renglón al historial con lo que cambió (`diff`) y lo que hizo el pipeline (`analyze`).
Contra qué volcado se compara depende de la acción (decisión 043):

| Acción | Se compara con |
|---|---|
| STEP, Paso×N, hasta cursor, STOP | el volcado anterior |
| Final de RUN (también por STOP) | el volcado anterior al RUN (§5) |
| Conectar, LOAD, RESET | nada: vacían el historial y empiezan de nuevo |
| Refrescar | el volcado anterior; si no cambió nada no agrega renglón |
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, replace
from pathlib import Path

from .client import DebugClient
from .hazards import Analysis, analyze
from .model import IMEM_WORDS, Diff, MemRange, Snapshot, decode_latches, diff
from .protocol import Info, State, Status

from rvasm import Program, assemble  # noqa: E402  (client agrega tools/assembler al path)

# Acciones de la interfaz (interfaz_pc.md §3). La comparación con el modelo de referencia
# no es una acción: es tools/debugger/comparar.py (I-54).
CONNECT, LOAD, RUN, STEP, STEP_N, RUN_TO, STOP, RESET, REPROGRAM, REFRESH, RANGE = (
    "connect", "load", "run", "step", "step_n", "run_to", "stop", "reset", "reprogram",
    "refresh", "range")

ALL_STATES = frozenset(State)
_RUNNABLE = frozenset({State.READY, State.PAUSED})

# Estados en que cada acción tiene sentido (interfaz_pc.md §3 y protocolo_debug.md §3.7).
# STOP solo en RUNNING: en los demás la FPGA lo acepta pero no hace nada.
ENABLED = {
    LOAD: ALL_STATES,
    RESET: ALL_STATES,
    REPROGRAM: ALL_STATES,
    RUN: _RUNNABLE,
    STEP: _RUNNABLE,
    STEP_N: _RUNNABLE,
    RUN_TO: _RUNNABLE,
    STOP: frozenset({State.RUNNING}),
    REFRESH: ALL_STATES - {State.RUNNING},
    RANGE: ALL_STATES - {State.RUNNING},
}

# Cargar o reprogramar en RUNNING corta la ejecución: la interfaz pide confirmación
CONFIRM_IN_RUNNING = frozenset({LOAD, REPROGRAM})

PROGRAM_SUFFIXES = (".s", ".hex", ".bin")

# Acciones que empiezan de cero: el historial anterior ya no corresponde
_FRESH = frozenset({CONNECT, LOAD, REPROGRAM, RESET})

HISTORY_MAX = 10_000      # renglones del historial (los más viejos se descartan)
RUN_TO_LIMIT = 2_000      # ciclos máximos de «correr hasta cursor» (decisión 043)
_PREVIOUS = object()      # base del diff: el volcado anterior


@dataclass(frozen=True)
class Entry:
    """Un renglón del historial: el volcado, con qué acción se llegó, qué cambió respecto
    de su base y qué hizo el pipeline (inferido)."""
    action: str
    snapshot: Snapshot
    diff: Diff
    analysis: Analysis


@dataclass(frozen=True)
class LoadedProgram:
    """Lo que se mandó con LOAD: las palabras y, si vino de un `.s`, su texto y el
    `Program` del ensamblador (con el `source_map`)."""
    path: Path
    words: tuple[int, ...]
    program: Program | None = None
    source: str | None = None


class ProgramFileError(ValueError):
    """El archivo no se puede leer como programa (extensión o contenido)."""


def read_program(path: str | Path) -> LoadedProgram:
    """Lee un programa: un `.s` se ensambla (levanta AssemblerError con cada línea mala);
    un `.hex` (una palabra por línea, como lo escribe el ensamblador) o un `.bin`
    (little-endian, el payload de LOAD) se leen tal cual. La validación de cada palabra
    con `classify` la hace `DebugClient.load` (decisión 025)."""
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix == ".s":
        source = path.read_text(encoding="utf-8")
        program = assemble(source, str(path))
        return LoadedProgram(path, tuple(program.words), program, source)
    if suffix == ".hex":
        words = []
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            text = line.split("//")[0].split("#")[0].strip()
            if not text:
                continue
            try:
                value = int(text, 16)
            except ValueError:
                raise ProgramFileError(f"{path}:{n}: '{text}' no es una palabra hex") from None
            if not 0 <= value <= 0xFFFF_FFFF:
                raise ProgramFileError(f"{path}:{n}: '{text}' no entra en 32 bits")
            words.append(value)
        return LoadedProgram(path, tuple(words))
    if suffix == ".bin":
        data = path.read_bytes()
        if len(data) % 4:
            raise ProgramFileError(f"{path}: {len(data)} bytes, no es un múltiplo de 4")
        return LoadedProgram(path, struct.unpack(f"<{len(data) // 4}I", data))
    raise ProgramFileError(f"{path}: se espera un .s, .hex o .bin")


class Session:
    """Orquesta los comandos de la interfaz sobre un `DebugClient` conectado."""

    def __init__(self, client: DebugClient):
        self.client = client
        self.info: Info | None = None
        self.snapshot: Snapshot | None = None
        self.before_run: Snapshot | None = None   # el volcado anterior al último RUN (§5)
        self.loaded: LoadedProgram | None = None
        self.running = False      # hubo un RUN y todavía no se esperó su final
        self.history: list[Entry] = []
        # Dirección de la memoria usada -> (ciclo del volcado en que se vio el cambio, si
        # ese volcado es del ciclo siguiente al anterior: si no, pudo ser antes)
        self.written: dict[int, tuple[int, bool]] = {}
        self.run_to_result: str | None = None     # reached, halted, limit o cancel

    # ---- estado --------------------------------------------------------------------

    @property
    def connected(self) -> bool:
        return self.info is not None

    @property
    def status(self) -> Status | None:
        return self.client.last_status or (self.snapshot.status if self.snapshot else None)

    @property
    def state(self) -> State | None:
        if self.running:          # la confirmación de RUN no trae bloque de estado
            return State.RUNNING
        status = self.status
        return status.state if status else None

    @property
    def last(self) -> Entry | None:
        """El último renglón del historial: el volcado que se muestra."""
        return self.history[-1] if self.history else None

    @property
    def words(self) -> tuple[int, ...] | None:
        """Las palabras que se mandaron con LOAD (None si esta PC no cargó el programa)."""
        return self.loaded.words if self.loaded else None

    def enabled(self, action: str) -> bool:
        """Si la acción se puede usar ahora (los controles deshabilitados del footer)."""
        if action == CONNECT:
            return True
        if not self.connected or self.state is None:
            return False
        if action in (REPROGRAM, RUN_TO) and self.loaded is None:
            return False
        return self.state in ENABLED[action]

    def needs_confirm(self, action: str) -> bool:
        return action in CONFIRM_IN_RUNNING and self.state == State.RUNNING

    # ---- acciones ------------------------------------------------------------------

    def connect(self) -> Snapshot | None:
        """INFO (verifica la versión), STATUS y READ_ALL (F1). Si la placa está en RUNNING
        no se puede leer: devuelve None y el volcado llega cuando termine."""
        self.running = False
        self.info = self.client.connect()
        self.history.clear()
        self.written.clear()
        status = self.client.status()
        if status.state == State.RUNNING:
            self.snapshot = None
            return None
        return self._read_all(CONNECT)

    def load_file(self, path: str | Path) -> Snapshot:
        """Lee o ensambla el archivo y, si está bien, LOAD + READ_ALL (F2). Si hay errores
        de ensamblado o una palabra fuera de isa.md no manda nada."""
        loaded = read_program(path)
        self.client.load(loaded.words)
        self.loaded = loaded
        return self._read_all(LOAD)

    def reprogram(self) -> Snapshot:
        """Vuelve a leer el archivo ya cargado, para editar el `.s` y recargarlo (F8)."""
        if self.loaded is None:
            raise ProgramFileError("no hay un programa cargado para reprogramar")
        snap = self.load_file(self.loaded.path)
        self.history[-1] = replace(self.history[-1], action=REPROGRAM)
        return snap

    def step(self) -> Snapshot:
        """STEP + READ_ALL (F10)."""
        self.client.step()
        return self._read_all(STEP)

    def step_n(self, n: int) -> Snapshot:
        """Hasta `n` STEP, cortando si el core llega a HALTED, y un solo READ_ALL al final
        (Shift+F10)."""
        if n < 1:
            raise ValueError("la cantidad de pasos tiene que ser al menos 1")
        for _ in range(n):
            if self.client.step().state == State.HALTED:
                break
        return self._read_all(STEP_N)

    def run_to(self, addr: int, limit: int = RUN_TO_LIMIT, cancel=None) -> Snapshot:
        """STEP hasta que la instrucción de `addr` llegue a WB (`MEM/WB.valid` y
        `MEM/WB.pc = addr`), el core quede en HALTED, pasen `limit` ciclos o `cancel()`
        devuelva True (F4). El PC de WB solo está en los latches, así que cada ciclo es
        STEP + READ_LATCHES; al final, un READ_ALL. `run_to_result` dice por qué paró."""
        if self.snapshot is not None and self.snapshot.fields is None:
            raise ValueError("los latches tienen otro formato: no se puede leer el PC de WB")
        before = self.snapshot
        result = "limit"
        for _ in range(limit):
            if cancel is not None and cancel():
                result = "cancel"
                break
            if self.client.step().state == State.HALTED:
                result = "halted"
                break
            wb = decode_latches(self.client.read_latches())["mem_wb"]
            if wb["valid"] and wb["pc"] == addr:
                result = "reached"
                break
        self.run_to_result = result
        return self._read_all(RUN_TO, base=before)

    def run(self) -> None:
        """RUN (F5). Vuelve con la confirmación; el final se espera con `wait_halted`."""
        self.before_run = self.snapshot
        self.client.run()
        self.running = True

    def wait_halted(self, timeout: float | None = None) -> Snapshot:
        """Espera el final de RUN (HaltTimeout si vence `timeout`) y hace READ_ALL."""
        self.client.wait_halted(timeout)
        self.running = False
        return self._read_all(RUN, base=self.before_run)

    def poll_status(self) -> Status:
        """STATUS durante RUN, para el contador de ciclos (§5)."""
        status = self.client.status()
        if self.snapshot is not None:
            self.snapshot = self.snapshot.with_status(status)
        return status

    def stop(self) -> Snapshot:
        """STOP + READ_ALL (F6)."""
        self.client.stop()
        return self._read_all(STOP)

    def reset(self) -> Snapshot:
        """RESET + READ_ALL (F3): el mismo programa desde cero."""
        self.client.reset()
        return self._read_all(RESET)

    def refresh(self) -> Snapshot:
        """READ_ALL (F9)."""
        return self._read_all(REFRESH)

    def read_range(self, addr: int, count: int) -> Snapshot | None:
        """READ_DMEM de `count` palabras desde `addr` (pestaña «Rango»)."""
        words = self.client.read_dmem(addr, count)
        rng = MemRange(addr, tuple(words))
        if self.snapshot is not None:
            self.snapshot = self.snapshot.with_range(rng)
        return self.snapshot

    def _read_all(self, action: str, base=_PREVIOUS) -> Snapshot:
        # El rango leído antes queda viejo después de cualquier acción: se vuelve a pedir
        prev = self.snapshot if base is _PREVIOUS else base
        self.snapshot = Snapshot.from_dump(self.client.read_all())
        self._record(action, self.snapshot, prev)
        return self.snapshot

    def _record(self, action: str, snap: Snapshot, prev: Snapshot | None) -> None:
        """Agrega el renglón del historial (decisión 043)."""
        if action in _FRESH:
            self.history.clear()
            self.written.clear()
            prev = None
        last = self.last
        if action == REFRESH and last is not None and _same(last.snapshot, snap):
            return
        # El análisis anterior sirve si es el del volcado base: sigue la causa de las burbujas
        prev_analysis = last.analysis if last is not None and _same(last.snapshot, prev) else None
        imem_words = self.info.imem_words if self.info else IMEM_WORDS
        changes = diff(prev, snap)
        exact = prev is not None and snap.status.cycles == prev.status.cycles + 1
        for addr in changes.mem:
            self.written[addr] = (snap.status.cycles, exact)
        self.history.append(Entry(action, snap, changes,
                                  analyze(snap, prev, prev_analysis, self.words, imem_words)))
        del self.history[:-HISTORY_MAX]


def _same(a: Snapshot | None, b: Snapshot | None) -> bool:
    """El mismo volcado, sin contar el rango leído aparte ni un STATUS más nuevo."""
    return (a is not None and b is not None and a.regs == b.regs and a.latches == b.latches
            and a.used == b.used and a.status.cycles == b.status.cycles
            and a.status.pc == b.status.pc)
