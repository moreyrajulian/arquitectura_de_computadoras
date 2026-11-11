"""rvdebug: cliente del protocolo de la Debug Unit (docs/spec/protocolo_debug.md).

Uso:

    from rvdebug import DebugClient, open_serial
    client = DebugClient(open_serial("/dev/ttyUSB1"))
    client.connect()                  # INFO y versión del protocolo
    client.load(words)                # rechaza palabras fuera de isa.md (classify)
    client.step()                     # bloque de estado
    client.read_all()                 # estado + registros + latches + memoria usada
    client.run(); client.wait_halted()
"""

from .client import (DebugClient, DeviceError, HaltTimeout, InvalidProgramError,
                     NoResponseError, check_program, open_serial, response_timeout)
from .protocol import (BAUD, PROTO_VERSION, Cmd, DebugError, Dump, Err, Info, Latches,
                       ProtocolError, State, Status)

__all__ = [
    "DebugClient", "open_serial", "check_program", "response_timeout",
    "DebugError", "DeviceError", "HaltTimeout", "InvalidProgramError", "NoResponseError",
    "ProtocolError",
    "BAUD", "PROTO_VERSION", "Cmd", "Err", "State", "Info", "Status", "Latches", "Dump",
]
