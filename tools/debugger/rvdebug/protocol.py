"""Tramas y bloques del protocolo de la Debug Unit (docs/spec/protocolo_debug.md).

Python puro, sin E/S: arma peticiones, valida respuestas y parte los payloads en
bloques. El manejo del puerto (timeouts, reintentos y eventos) está en client.py.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from enum import IntEnum
from functools import reduce

PROTO_VERSION = 1
BAUD = 115200

SOF_REQUEST = 0xA5    # PC -> FPGA
SOF_RESPONSE = 0x5A   # FPGA -> PC

MAX_LEN = 0xFFFF      # LEN es de 16 bits

REQUEST_HEADER = 4    # SOF CMD LEN_L LEN_H
RESPONSE_HEADER = 5   # SOF CMD STATUS LEN_L LEN_H


class Cmd(IntEnum):
    """Códigos de comando (§3)."""
    INFO = 0x01
    STATUS = 0x02
    LOAD = 0x10
    RESET = 0x11
    RUN = 0x20
    STEP = 0x21
    STOP = 0x22
    READ_REGS = 0x30
    READ_LATCHES = 0x31
    READ_DMEM = 0x32
    READ_DMEM_USED = 0x33
    READ_ALL = 0x34
    EVT_HALTED = 0xE0


class Err(IntEnum):
    """Códigos de STATUS de una respuesta (§5)."""
    OK = 0x00
    ERR_UNKNOWN_CMD = 0x01
    ERR_CHECKSUM = 0x02
    ERR_LENGTH = 0x03
    ERR_STATE = 0x04
    ERR_ADDR = 0x05
    ERR_TIMEOUT = 0x06


ERR_TEXT = {
    Err.ERR_UNKNOWN_CMD: "comando desconocido",
    Err.ERR_CHECKSUM: "checksum incorrecto",
    Err.ERR_LENGTH: "LEN inválido para el comando",
    Err.ERR_STATE: "comando no permitido en el estado actual",
    Err.ERR_ADDR: "dirección desalineada o fuera de rango",
    Err.ERR_TIMEOUT: "timeout entre bytes de la trama",
}


class State(IntEnum):
    """Estado de ejecución del bloque de estado (§3.1)."""
    NO_PROG = 0
    READY = 1
    RUNNING = 2
    PAUSED = 3
    HALTED = 4


# bits de `flags` (§3.1)
FLAG_PROG_VALID = 1 << 0
FLAG_HALTED = 1 << 1
FLAG_IMEM_FAULT = 1 << 2
FLAG_DMEM_OOB = 1 << 3
FLAG_DMEM_MISALIGNED = 1 << 4

LATCH_NAMES = ("if_id", "id_ex", "ex_mem", "mem_wb")   # orden de READ_LATCHES (§3.6)

STATUS_SIZE = 12
INFO_SIZE = 13
REGS_SIZE = 128


class DebugError(Exception):
    """Base de los errores del cliente de la Debug Unit."""


class ProtocolError(DebugError):
    """Una trama o un payload no respetan el protocolo."""


def name_of(code, enum):
    """Nombre de un código, o su valor en hex si no está en la tabla."""
    try:
        return enum(code).name
    except ValueError:
        return f"0x{code:02X}"


# ---- tramas -------------------------------------------------------------------------

def checksum(data) -> int:
    """XOR de todos los bytes (§2): se aplica desde CMD hasta el fin del payload."""
    return reduce(lambda a, b: a ^ b, data, 0)


def build_request(cmd: int, payload: bytes = b"") -> bytes:
    """Petición PC -> FPGA: SOF CMD LEN PAYLOAD CHK."""
    if len(payload) > MAX_LEN:
        raise ValueError(f"payload de {len(payload)} B: el máximo es {MAX_LEN}")
    body = bytes([cmd]) + struct.pack("<H", len(payload)) + bytes(payload)
    return bytes([SOF_REQUEST]) + body + bytes([checksum(body)])


def build_response(cmd: int, status: int = Err.OK, payload: bytes = b"") -> bytes:
    """Respuesta o evento FPGA -> PC: SOF CMD STATUS LEN PAYLOAD CHK.

    La usa el puerto simulado de los tests; la PC no la necesita.
    """
    if len(payload) > MAX_LEN:
        raise ValueError(f"payload de {len(payload)} B: el máximo es {MAX_LEN}")
    body = bytes([cmd, status]) + struct.pack("<H", len(payload)) + bytes(payload)
    return bytes([SOF_RESPONSE]) + body + bytes([checksum(body)])


@dataclass(frozen=True)
class Response:
    """Respuesta o evento recibido, ya con el checksum verificado."""
    cmd: int
    status: int
    payload: bytes
    raw: bytes

    @property
    def ok(self) -> bool:
        return self.status == Err.OK

    @property
    def is_event(self) -> bool:
        return self.cmd == Cmd.EVT_HALTED


def parse_response(raw: bytes) -> Response:
    """Valida una respuesta completa (SOF, LEN y CHK) y la devuelve partida."""
    if len(raw) < RESPONSE_HEADER + 1:
        raise ProtocolError(f"trama de {len(raw)} B: el mínimo es {RESPONSE_HEADER + 1}")
    if raw[0] != SOF_RESPONSE:
        raise ProtocolError(f"SOF 0x{raw[0]:02X}: se esperaba 0x{SOF_RESPONSE:02X}")
    length = raw[3] | raw[4] << 8
    if len(raw) != RESPONSE_HEADER + length + 1:
        raise ProtocolError(f"LEN = {length} pero la trama trae {len(raw) - RESPONSE_HEADER - 1} B de payload")
    if checksum(raw[1:-1]) != raw[-1]:
        raise ProtocolError(f"checksum 0x{raw[-1]:02X}: se esperaba 0x{checksum(raw[1:-1]):02X}")
    return Response(raw[1], raw[2], bytes(raw[RESPONSE_HEADER:-1]), bytes(raw))


def parse_request(raw: bytes) -> tuple[int, bytes]:
    """Valida una petición completa y devuelve (CMD, payload). Para los tests."""
    if len(raw) < REQUEST_HEADER + 1 or raw[0] != SOF_REQUEST:
        raise ProtocolError("petición mal formada")
    length = raw[2] | raw[3] << 8
    if len(raw) != REQUEST_HEADER + length + 1 or checksum(raw[1:-1]) != raw[-1]:
        raise ProtocolError("petición mal formada")
    return raw[1], bytes(raw[REQUEST_HEADER:-1])


# ---- payloads de las peticiones -------------------------------------------------------

def load_payload(words) -> bytes:
    """Payload de LOAD: las palabras little-endian desde la dirección 0 (§3.3)."""
    for i, w in enumerate(words):
        if not 0 <= w <= 0xFFFF_FFFF:
            raise ValueError(f"palabra {i} (0x{4 * i:03X}) fuera de 32 bits: {w}")
    return struct.pack(f"<{len(words)}I", *words)


def read_dmem_payload(addr: int, count: int) -> bytes:
    """Payload de READ_DMEM: addr (4 B, en bytes) + count (2 B, en palabras) (§3.6)."""
    if not 0 <= addr <= 0xFFFF_FFFF:
        raise ValueError(f"dirección fuera de 32 bits: {addr}")
    if not 1 <= count <= MAX_LEN // 4:
        raise ValueError(f"count = {count}: tiene que estar entre 1 y {MAX_LEN // 4}")
    return struct.pack("<IH", addr, count)


# ---- bloques de las respuestas --------------------------------------------------------

@dataclass(frozen=True)
class Info:
    """Bloque de información de INFO (§3.2)."""
    proto_version: int
    imem_words: int
    dmem_words: int
    latch_words: tuple[int, int, int, int]   # IF/ID, ID/EX, EX/MEM, MEM/WB
    clk_khz: int

    @property
    def latches_size(self) -> int:
        """Bytes de READ_LATCHES."""
        return 4 * sum(self.latch_words)


@dataclass(frozen=True)
class Status:
    """Bloque de estado (§3.1)."""
    state: State | int
    flags: int
    dmem_used: int
    pc: int
    cycles: int

    @property
    def state_name(self) -> str:
        return name_of(self.state, State)

    @property
    def prog_valid(self) -> bool:
        return bool(self.flags & FLAG_PROG_VALID)

    @property
    def halted(self) -> bool:
        return bool(self.flags & FLAG_HALTED)

    @property
    def imem_fault(self) -> bool:
        return bool(self.flags & FLAG_IMEM_FAULT)

    @property
    def dmem_oob(self) -> bool:
        return bool(self.flags & FLAG_DMEM_OOB)

    @property
    def dmem_misaligned(self) -> bool:
        return bool(self.flags & FLAG_DMEM_MISALIGNED)


@dataclass(frozen=True)
class Latches:
    """Palabras de READ_LATCHES. La palabra 0 tiene los 32 bits menos significativos del
    latch; qué campo va en cada bit lo define pipeline.md §8."""
    if_id: tuple[int, ...]
    id_ex: tuple[int, ...]
    ex_mem: tuple[int, ...]
    mem_wb: tuple[int, ...]

    def words(self, name: str) -> tuple[int, ...]:
        return getattr(self, name)

    def packed(self, name: str) -> int:
        """El latch como un solo número, con el mismo empaquetado que el modelo de
        referencia (isasim.latches)."""
        return sum(w << (32 * i) for i, w in enumerate(self.words(name)))


@dataclass(frozen=True)
class Dump:
    """Volcado de READ_ALL (§3.6): estado, registros, latches y memoria usada."""
    status: Status
    regs: tuple[int, ...]
    latches: Latches
    used: tuple[tuple[int, int], ...]   # pares (dirección en bytes, valor), en orden creciente


def _expect(payload: bytes, size: int, what: str) -> None:
    if len(payload) != size:
        raise ProtocolError(f"{what}: {len(payload)} B, se esperaban {size}")


def parse_info(payload: bytes) -> Info:
    _expect(payload, INFO_SIZE, "bloque de información")
    version, imem, dmem, l0, l1, l2, l3, clk = struct.unpack("<BHH4BI", payload)
    return Info(version, imem, dmem, (l0, l1, l2, l3), clk)


def parse_status(payload: bytes) -> Status:
    _expect(payload, STATUS_SIZE, "bloque de estado")
    state, flags, used, pc, cycles = struct.unpack("<BBHII", payload)
    try:
        state = State(state)
    except ValueError:
        raise ProtocolError(f"estado {state} fuera de la tabla de §3.1") from None
    return Status(state, flags, used, pc, cycles)


def parse_regs(payload: bytes) -> tuple[int, ...]:
    _expect(payload, REGS_SIZE, "registros")
    return struct.unpack("<32I", payload)


def parse_latches(payload: bytes, latch_words) -> Latches:
    _expect(payload, 4 * sum(latch_words), "latches")
    words = struct.unpack(f"<{len(payload) // 4}I", payload)
    parts, start = [], 0
    for n in latch_words:
        parts.append(tuple(words[start:start + n]))
        start += n
    return Latches(*parts)


def parse_dmem(payload: bytes, count: int) -> tuple[int, ...]:
    _expect(payload, 4 * count, "memoria de datos")
    return struct.unpack(f"<{count}I", payload)


def parse_dmem_used(payload: bytes, expected: int | None = None) -> tuple[tuple[int, int], ...]:
    if len(payload) % 8 or (expected is not None and len(payload) != 8 * expected):
        want = "un múltiplo de 8" if expected is None else str(8 * expected)
        raise ProtocolError(f"memoria usada: {len(payload)} B, se esperaban {want}")
    values = struct.unpack(f"<{len(payload) // 4}I", payload)
    return tuple(zip(values[0::2], values[1::2]))


def parse_read_all(payload: bytes, latch_words) -> Dump:
    """Parte READ_ALL: el tamaño de la memoria usada sale de `dmem_used` del propio
    bloque de estado."""
    if len(payload) < STATUS_SIZE:
        raise ProtocolError(f"READ_ALL: {len(payload)} B, menos que el bloque de estado")
    status = parse_status(payload[:STATUS_SIZE])
    latches_size = 4 * sum(latch_words)
    _expect(payload, STATUS_SIZE + REGS_SIZE + latches_size + 8 * status.dmem_used, "READ_ALL")
    at = STATUS_SIZE
    regs = parse_regs(payload[at:at + REGS_SIZE])
    at += REGS_SIZE
    latches = parse_latches(payload[at:at + latches_size], latch_words)
    at += latches_size
    used = parse_dmem_used(payload[at:], status.dmem_used)
    return Dump(status, regs, latches, used)
