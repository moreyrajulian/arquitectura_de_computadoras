"""rvdebug: cliente del protocolo de la Debug Unit (docs/spec/protocolo_debug.md).

Uso:

    from rvdebug import DebugClient, open_serial
    client = DebugClient(open_serial("/dev/ttyUSB1"))
    client.connect()                  # INFO y versión del protocolo
    client.load(words)                # rechaza palabras fuera de isa.md (classify)
    client.step()                     # bloque de estado
    client.read_all()                 # estado + registros + latches + memoria usada
    client.run(); client.wait_halted()

La interfaz de texto (Textual) está en `rvdebug.tui` y no se importa acá, para que el
cliente, `model` y `session` se usen sin Textual.
"""

from .client import (DebugClient, DeviceError, HaltTimeout, InvalidProgramError,
                     NoResponseError, check_program, open_serial, response_timeout)
from .model import ABI, MemRange, Snapshot, fmt_dec, fmt_hex, reg_name
from .protocol import (BAUD, PROTO_VERSION, Cmd, DebugError, Dump, Err, Info, Latches,
                       ProtocolError, State, Status)
from .session import LoadedProgram, Session, read_program

__all__ = [
    "DebugClient", "open_serial", "check_program", "response_timeout",
    "DebugError", "DeviceError", "HaltTimeout", "InvalidProgramError", "NoResponseError",
    "ProtocolError",
    "Session", "LoadedProgram", "read_program", "Snapshot", "MemRange",
    "ABI", "reg_name", "fmt_hex", "fmt_dec",
    "BAUD", "PROTO_VERSION", "Cmd", "Err", "State", "Info", "Status", "Latches", "Dump",
]
