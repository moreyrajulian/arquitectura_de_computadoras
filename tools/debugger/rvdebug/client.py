"""Cliente de la Debug Unit: un método por comando, con timeouts, reintentos y
EVT_HALTED (docs/spec/protocolo_debug.md §3 y §5).

Trabaja sobre cualquier objeto con la interfaz de pyserial que usa: `write`, `read`
(respeta `timeout`), `reset_input_buffer`, `in_waiting` y `timeout`. Así los tests
usan un puerto simulado sin FPGA, y `open_serial` abre el puerto real.
"""

from __future__ import annotations

import sys
import threading
import time
from collections import deque
from pathlib import Path

from . import protocol as p
from .protocol import Cmd, DebugError, Dump, Err, Info, Latches, ProtocolError, Response, State, Status

# classify sale del ensamblador del proyecto (decisión 025), como en isasim y sw/
_ASSEMBLER = Path(__file__).resolve().parents[2] / "assembler"
if str(_ASSEMBLER) not in sys.path:
    sys.path.insert(0, str(_ASSEMBLER))
from rvasm import classify  # noqa: E402
from rvasm.isa import SUPPORTED, UNRECOGNIZED  # noqa: E402


class NoResponseError(DebugError):
    """La FPGA no respondió bien después de todos los reintentos (§5)."""


class DeviceError(DebugError):
    """La FPGA respondió con un STATUS de error que no se reintenta."""

    def __init__(self, cmd: int, status: int):
        self.cmd = cmd
        self.status = status
        text = p.ERR_TEXT.get(status, "código fuera de la tabla de §5")
        super().__init__(f"{p.name_of(cmd, Cmd)}: {p.name_of(status, Err)} ({text})")


class InvalidProgramError(DebugError, ValueError):
    """El programa no se puede mandar con LOAD. `problems` tiene un renglón por motivo."""

    def __init__(self, problems: list[str]):
        self.problems = problems
        shown = problems[:10]
        more = f"\n  ... y {len(problems) - 10} más" if len(problems) > 10 else ""
        super().__init__("programa rechazado antes de LOAD:\n  " + "\n  ".join(shown) + more)


class HaltTimeout(DebugError):
    """Venció el watchdog de la ejecución continua sin EVT_HALTED (§5)."""


class _Transient(Exception):
    """Fallo que se resuelve reintentando: timeout, trama rota, ERR_CHECKSUM o ERR_TIMEOUT."""


class _Silence(_Transient):
    """No llegó ningún comienzo de trama antes del plazo."""


RETRYABLE = (Err.ERR_CHECKSUM, Err.ERR_TIMEOUT)


def response_timeout(nbytes: int, baud: int) -> float:
    """T_RESP de §5: 200 ms más 1,5 veces lo que tardan `nbytes` bytes en la línea."""
    return 0.2 + 1.5 * 10 * nbytes / baud


def check_program(words, imem_words: int) -> None:
    """Rechaza un programa vacío, más largo que la memoria o con alguna palabra fuera de
    isa.md (decisión 025, interfaz_pc.md §3). No manda nada."""
    if not words:
        raise InvalidProgramError(["el programa no tiene instrucciones"])
    problems = []
    if len(words) > imem_words:
        problems.append(f"{len(words)} palabras: la memoria de programa tiene {imem_words}")
    for i, word in enumerate(words):
        if not 0 <= word <= 0xFFFF_FFFF:
            problems.append(f"0x{4 * i:03X}: {word} no entra en 32 bits")
            continue
        result = classify(word)
        if result.kind == SUPPORTED:
            continue
        if result.kind == UNRECOGNIZED:
            effect = "el hardware la ejecutaría como NOP"
        else:
            effect = "el hardware la ejecutaría según su opcode, con resultado no especificado"
        problems.append(f"0x{4 * i:03X}: 0x{word:08X} no es de isa.md ({result.reason}; {effect})")
    if problems:
        raise InvalidProgramError(problems)


def open_serial(port: str, baud: int = p.BAUD):
    """Abre el puerto real en 8N1 (§1). Importa pyserial recién acá: los tests no lo usan."""
    import serial
    return serial.Serial(port, baud, bytesize=8, parity="N", stopbits=1, timeout=0.02)


class DebugClient:
    """Habla con la Debug Unit por un puerto serie.

    Los métodos se pueden llamar desde varios hilos: un lock serializa el acceso al
    puerto. `wait_halted` lo suelta mientras espera, para que otro hilo pueda mandar
    `stop()` o `status()` durante una ejecución continua.
    """

    def __init__(self, port, *, baud: int | None = None, retries: int = 3,
                 retry_wait: float = 0.15, halt_watchdog: float = 5.0,
                 poll: float = 0.02, clock=time.monotonic, sleep=time.sleep,
                 on_frame=None):
        self.port = port
        self.baud = baud or getattr(port, "baudrate", None) or p.BAUD
        self.retries = retries            # reintentos después del primer intento (§5: 3)
        self.retry_wait = retry_wait      # espera antes de reintentar (§5: más que T_BYTE)
        self.halt_watchdog = halt_watchdog
        self.poll = poll                  # cada cuánto se mira el puerto mientras se espera
        self.on_frame = on_frame          # on_frame("tx" | "rx", bytes), para el panel de tramas
        self._clock = clock
        self._sleep = sleep
        self._lock = threading.RLock()
        self.device_info: Info | None = None
        self.last_status: Status | None = None
        self._running = False             # hubo un RUN y todavía no llegó cómo terminó
        self._ended: deque[Status] = deque()
        port.timeout = poll

    # ---- comandos -----------------------------------------------------------------

    def connect(self) -> Info:
        """Vacía los buffers, manda INFO y verifica la versión del protocolo (§5)."""
        with self._lock:
            self.port.reset_input_buffer()
            info = self.info()
            if info.proto_version != p.PROTO_VERSION:
                raise ProtocolError(f"la FPGA habla la versión {info.proto_version} del "
                                    f"protocolo y el cliente la {p.PROTO_VERSION}")
            return info

    def info(self) -> Info:
        info = p.parse_info(self._command(Cmd.INFO, expect=p.INFO_SIZE).payload)
        self.device_info = info
        return info

    def status(self) -> Status:
        return self._status_of(self._command(Cmd.STATUS, expect=p.STATUS_SIZE))

    def load(self, words) -> Status:
        """Carga el programa desde la dirección 0. Antes de mandarlo verifica cada
        palabra con `classify` (decisión 025); si alguna está fuera de isa.md, no manda
        nada y levanta InvalidProgramError con su dirección."""
        words = list(words)
        with self._lock:
            check_program(words, self._info().imem_words)
            payload = p.load_payload(words)
            return self._status_of(self._command(Cmd.LOAD, payload, expect=p.STATUS_SIZE))

    def reset(self) -> Status:
        return self._status_of(self._command(Cmd.RESET, expect=p.STATUS_SIZE))

    def step(self) -> Status:
        """Un ciclo de reloj. STEP no es idempotente: si la respuesta se pierde, antes de
        reintentar compara `cycles` con STATUS (§5)."""
        request = p.build_request(Cmd.STEP)
        with self._lock:
            before = self.last_status or self.status()
            for _ in range(self.retries + 1):
                try:
                    return self._status_of(self._transact(Cmd.STEP, request, p.STATUS_SIZE))
                except _Transient:
                    pass
                self._recover()
                now = self.status()
                if now.cycles == (before.cycles + 1) & 0xFFFF_FFFF:
                    return now                          # el paso se hizo
                before = now
            raise self._no_response(Cmd.STEP)

    def run(self) -> None:
        """Arranca la ejecución continua. Vuelve con la confirmación; el final se espera
        con `wait_halted`. RUN no es idempotente: si la confirmación se pierde, antes de
        reintentar mira el estado con STATUS (§5)."""
        request = p.build_request(Cmd.RUN)
        with self._lock:
            self._running = False       # los EVT_HALTED anteriores a la confirmación son viejos
            self._ended.clear()
            for _ in range(self.retries + 1):
                try:
                    self._transact(Cmd.RUN, request, 0)
                    self._running = True
                    return
                except _Transient:
                    pass
                self._recover()
                now = self.status()
                if now.state == State.RUNNING:
                    self._running = True
                    return
                if now.state == State.HALTED:           # arrancó y ya terminó
                    self._ended.append(now)
                    return
            raise self._no_response(Cmd.RUN)

    def wait_halted(self, timeout: float | None = None) -> Status:
        """Espera el final de la ejecución continua y devuelve su bloque de estado.

        Normalmente es el EVT_HALTED (estado HALTED). Si otro hilo la terminó con
        `stop()`, `load()` o `reset()`, devuelve el estado con que respondió ese comando.
        Si vence `timeout` (por defecto el watchdog, 5 s) levanta HaltTimeout y la
        ejecución sigue: se puede volver a esperar o mandar `stop()`.
        """
        limit = self.halt_watchdog if timeout is None else timeout
        end = self._clock() + limit
        while True:
            with self._lock:
                if self._ended:
                    return self._ended.popleft()
                if not self._running:
                    raise DebugError("no hay una ejecución continua en curso (falta run())")
                if self.port.in_waiting:
                    self._read_pending()
                    continue
            if self._clock() >= end:
                raise HaltTimeout(f"el programa no terminó en {limit:g} s: puede ser un bucle "
                                  "sin HALT; stop() lo pausa")
            self._sleep(self.poll)      # sin el lock, para que otro hilo pueda mandar STOP

    def stop(self) -> Status:
        return self._status_of(self._command(Cmd.STOP, expect=p.STATUS_SIZE))

    def read_regs(self) -> tuple[int, ...]:
        return p.parse_regs(self._command(Cmd.READ_REGS, expect=p.REGS_SIZE).payload)

    def read_latches(self) -> Latches:
        with self._lock:
            info = self._info()
            r = self._command(Cmd.READ_LATCHES, expect=info.latches_size)
            return p.parse_latches(r.payload, info.latch_words)

    def read_dmem(self, addr: int, count: int) -> tuple[int, ...]:
        """`count` palabras desde `addr` (en bytes, alineada a palabra)."""
        r = self._command(Cmd.READ_DMEM, p.read_dmem_payload(addr, count), expect=4 * count)
        return p.parse_dmem(r.payload, count)

    def read_dmem_used(self) -> tuple[tuple[int, int], ...]:
        return p.parse_dmem_used(self._command(Cmd.READ_DMEM_USED).payload)

    def read_all(self) -> Dump:
        with self._lock:
            info = self._info()
            dump = p.parse_read_all(self._command(Cmd.READ_ALL).payload, info.latch_words)
            self._note(dump.status)
            return dump

    # ---- transacciones --------------------------------------------------------------

    def _info(self) -> Info:
        return self.device_info or self.info()

    def _command(self, cmd: Cmd, payload: bytes = b"", *, expect: int | None = None) -> Response:
        """Petición idempotente: reintenta los fallos transitorios hasta `retries` veces."""
        request = p.build_request(cmd, payload)
        with self._lock:
            for attempt in range(self.retries + 1):
                if attempt:
                    self._recover()
                try:
                    return self._transact(cmd, request, expect)
                except _Transient:
                    pass
            raise self._no_response(cmd)

    def _transact(self, cmd: Cmd, request: bytes, expect: int | None) -> Response:
        """Un intento: manda la petición y lee hasta su respuesta. Los EVT_HALTED que
        lleguen antes se procesan; las respuestas a otro CMD (de una petición anterior
        que venció) se descartan."""
        self.port.write(request)
        if hasattr(self.port, "flush"):
            self.port.flush()
        self._trace("tx", request)
        size = p.RESPONSE_HEADER + 1 + (expect or 0)
        deadline = self._clock() + response_timeout(len(request) + size, self.baud)
        while True:
            r = self._read_frame(deadline)
            if r.is_event:
                self._event(r)
                continue
            if r.cmd != cmd:
                continue
            if r.status in RETRYABLE:
                raise _Transient(p.name_of(r.status, Err))
            if not r.ok:
                raise DeviceError(cmd, r.status)
            if expect is not None and len(r.payload) != expect:
                raise ProtocolError(f"{cmd.name}: respuesta de {len(r.payload)} B, se esperaban {expect}")
            return r

    def _read_frame(self, deadline: float) -> Response:
        """Lee una trama completa. Descarta lo que haya antes del SOF. Al encontrar el SOF
        el plazo se estira lo que haga falta para el resto de la trama."""
        while self._read(1, deadline, first=True)[0] != p.SOF_RESPONSE:
            pass
        deadline = max(deadline, self._clock() + response_timeout(4, self.baud))
        header = self._read(4, deadline)
        cmd, status, length = header[0], header[1], header[2] | header[3] << 8
        if length > self._max_len(cmd):
            raise _Transient(f"LEN = {length} imposible para {p.name_of(cmd, Cmd)}")
        deadline = max(deadline, self._clock() + response_timeout(length + 1, self.baud))
        rest = self._read(length + 1, deadline)
        raw = bytes([p.SOF_RESPONSE]) + header + rest
        self._trace("rx", raw)
        if p.checksum(raw[1:-1]) != raw[-1]:
            raise _Transient("checksum de la respuesta")
        return Response(cmd, status, rest[:-1], raw)

    def _read(self, n: int, deadline: float, first: bool = False) -> bytes:
        buf = bytearray()
        while len(buf) < n:
            if self._clock() >= deadline:
                raise (_Silence if first else _Transient)("timeout")
            buf += self.port.read(n - len(buf))
        return bytes(buf)

    def _read_pending(self) -> None:
        """Lee una trama que llegó sin petición mientras se espera el final de RUN."""
        try:
            r = self._read_frame(self._clock() + response_timeout(p.RESPONSE_HEADER, self.baud))
        except _Silence:
            return                      # solo basura antes de un SOF
        except _Transient:
            # trama rota: pudo ser el EVT_HALTED. STATUS dice si la ejecución terminó.
            self._recover()
            self.status()
            return
        if r.is_event:
            self._event(r)

    def _max_len(self, cmd: int) -> int:
        """LEN máximo posible de una respuesta. Uno mayor es un LEN corrompido que el CHK
        no llegó a detectar todavía: no tiene sentido esperar esos bytes."""
        fixed = {Cmd.INFO: p.INFO_SIZE, Cmd.RUN: 0, Cmd.READ_REGS: p.REGS_SIZE}
        if cmd in fixed:
            return fixed[cmd]
        if cmd in (Cmd.STATUS, Cmd.LOAD, Cmd.RESET, Cmd.STEP, Cmd.STOP, Cmd.EVT_HALTED):
            return p.STATUS_SIZE
        info = self.device_info
        if info is None:
            return p.MAX_LEN
        used = 8 * info.dmem_words
        return min(p.MAX_LEN, {
            Cmd.READ_LATCHES: info.latches_size,
            Cmd.READ_DMEM: 4 * info.dmem_words,
            Cmd.READ_DMEM_USED: used,
            Cmd.READ_ALL: p.STATUS_SIZE + p.REGS_SIZE + info.latches_size + used,
        }.get(cmd, p.MAX_LEN))

    def _recover(self) -> None:
        """§5: esperar más que T_BYTE, para que la FPGA abandone una trama a medias, y
        vaciar la entrada."""
        self._sleep(self.retry_wait)
        self.port.reset_input_buffer()

    def _no_response(self, cmd: Cmd) -> NoResponseError:
        return NoResponseError(f"{cmd.name}: la FPGA no responde después de {self.retries} "
                               "reintentos (revisar cable, puerto, baudrate o apretar el "
                               "reset de la placa)")

    # ---- estado y eventos -------------------------------------------------------------

    def _status_of(self, r: Response) -> Status:
        return self._note(p.parse_status(r.payload))

    def _note(self, status: Status) -> Status:
        """Guarda el último estado. Si había una ejecución continua y el estado ya no es
        RUNNING, terminó (por HALT, STOP, LOAD o RESET): lo recibe `wait_halted`."""
        self.last_status = status
        if self._running and status.state != State.RUNNING:
            self._running = False
            self._ended.append(status)
        return status

    def _event(self, r: Response) -> None:
        status = p.parse_status(r.payload)
        if self._running:
            self._note(status)
        # sin ejecución en curso es un evento viejo (anterior al último RUN, o de una
        # ejecución cuyo final ya se supo por STATUS): se descarta

    def _trace(self, direction: str, raw: bytes) -> None:
        if self.on_frame is not None:
            self.on_frame(direction, raw)
