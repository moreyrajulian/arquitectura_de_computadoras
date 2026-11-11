# rvdebug: cliente del protocolo de la Debug Unit

Capa de software que habla el protocolo de [`protocolo_debug.md`](../../docs/spec/protocolo_debug.md)
con la FPGA: arma y valida las tramas, maneja timeouts y reintentos, y recibe el
`EVT_HALTED`. Es la capa `client` de [`interfaz_pc.md`](../../docs/spec/interfaz_pc.md) §1:
Python puro, sin Textual, para que la usen la interfaz (I-52), la prueba en placa (I-49) y
los tests sin levantar la TUI.

| | |
|---|---|
| **Issue** | I-50 — Cliente del protocolo |
| **Requisitos** | Python ≥ 3.11. `pyserial` solo para el puerto real (`requirements.txt`). Tests: `pytest`, sin FPGA. Usa `classify` del ensamblador de [`tools/assembler`](../assembler/README.md) |
| **Protocolo** | Versión 1, 115200 8N1 |

## 1. Uso

```python
import sys; sys.path.insert(0, "tools/debugger")
from rvdebug import DebugClient, open_serial
from rvasm import assemble          # rvdebug ya agrega tools/assembler al path

client = DebugClient(open_serial("/dev/ttyUSB1"))     # en Windows, "COM10"
info = client.connect()             # INFO: versión, tamaños, palabras por latch, clk_khz

client.load(assemble(open("sw/fwd_exmem.s").read()).words)
client.step()                       # Status: state, flags, dmem_used, pc, cycles
dump = client.read_all()            # Dump: status, regs, latches, used

client.reset()
client.run()
status = client.wait_halted()       # el EVT_HALTED; HaltTimeout si pasan 5 s
```

| Método | Comando | Devuelve |
|---|---|---|
| `connect()` | Vacía la entrada, `INFO` y verifica `proto_version = 1` | `Info` |
| `info()`, `status()` | `INFO`, `STATUS` | `Info`, `Status` |
| `load(words)` | `LOAD`, después de validar el programa (§2) | `Status` |
| `reset()`, `step()`, `stop()` | `RESET`, `STEP`, `STOP` | `Status` |
| `run()` | `RUN`: vuelve con la confirmación | — |
| `wait_halted(timeout=None)` | Espera el final de `RUN` | `Status` |
| `read_regs()` | `READ_REGS` | 32 enteros sin signo |
| `read_latches()` | `READ_LATCHES`, partido con las palabras por latch de `INFO` | `Latches` |
| `read_dmem(addr, count)` | `READ_DMEM` (`addr` en bytes) | `count` palabras |
| `read_dmem_used()` | `READ_DMEM_USED` | Pares `(dirección, valor)` |
| `read_all()` | `READ_ALL` | `Dump` |

`Status` tiene `state` (`State.NO_PROG` … `State.HALTED`) y los bits de `flags` como
propiedades: `prog_valid`, `halted`, `imem_fault`, `dmem_oob`, `dmem_misaligned`.
`Latches` guarda las palabras de cada registro de segmentación (`if_id`, `id_ex`, `ex_mem`,
`mem_wb`), con la palabra 0 en los bits menos significativos; `packed(nombre)` las junta en un
número con el empaquetado de [`isasim`](../isasim/README.md) (los campos están en
[`pipeline.md`](../../docs/spec/pipeline.md) §8). El cliente guarda el último `Info` en
`device_info` y el último `Status` en `last_status`.

`DebugClient(port, on_frame=f)` llama a `f("tx" | "rx", bytes)` con cada trama, para el panel
de tramas de la interfaz.

## 2. Validación del programa antes de `LOAD`

`load` no manda nada si el programa está vacío, si tiene más palabras que `imem_words` (de
`INFO`) o si alguna palabra no es de [`isa.md`](../../docs/spec/isa.md) según `classify`
(decisión [025](../../docs/decisiones/025_filtro-de-palabras-en-el-toolchain.md)). Levanta
`InvalidProgramError` con un renglón por palabra rechazada: su dirección, la palabra, el
motivo y qué haría el hardware con ella. Así un `.hex` o `.bin` que no pasó por el
ensamblador tiene el mismo filtro que un `.word`.

```
programa rechazado antes de LOAD:
  0x004: 0x00000000 no es de isa.md (opcode 0000000 fuera de la tabla; el hardware la ejecutaría como NOP)
```

## 3. Errores, timeouts y reintentos

Sigue [`protocolo_debug.md`](../../docs/spec/protocolo_debug.md) §5.

| Situación | Qué hace |
|---|---|
| Pasa `T_RESP` sin respuesta, la respuesta llega con el `CHK` mal, o la FPGA responde `ERR_CHECKSUM` o `ERR_TIMEOUT` | Espera 150 ms, vacía la entrada y reintenta, hasta 3 veces. Después levanta `NoResponseError` |
| `STEP` o `RUN` fallan así | No los repite a ciegas: manda `STATUS`. `STEP` se da por hecho si `cycles` aumentó en 1; `RUN`, si el estado es `RUNNING` o `HALTED` |
| La FPGA responde otro error (`ERR_STATE`, `ERR_ADDR`, `ERR_LENGTH`, `ERR_UNKNOWN_CMD`) | `DeviceError` con `cmd` y `status`, sin reintentar: el comando no tuvo efecto |
| Una respuesta bien formada no tiene el tamaño del comando, o `INFO` trae otra versión | `ProtocolError` |
| `wait_halted` supera el watchdog (por defecto 5 s) | `HaltTimeout`. La ejecución sigue: se puede volver a esperar o mandar `stop()` |

Todas las excepciones heredan de `DebugError`.

Si se levanta `NoResponseError`, `last_status` queda en `None`: la FPGA pudo haber hecho el
comando aunque no llegó la respuesta, así que el próximo `step()` pide `STATUS` antes de
avanzar. `connect()` también lo borra.

Detalles que el protocolo deja al cliente:

- **Antes del `SOF` (`0x5A`) se descarta todo**, como hace la FPGA en reposo.
- **Un `LEN` mayor que el máximo posible para ese `CMD`** se toma como trama rota enseguida,
  sin esperar 65 535 bytes que no van a llegar.
- **Una respuesta a otro `CMD` se descarta.** Es la respuesta tardía a una petición que ya
  venció; como toda petición recibe exactamente una respuesta, la propia llega después.

### `EVT_HALTED`

El `EVT_HALTED` puede llegar en medio de cualquier lectura mientras el core está en
`RUNNING`. Se procesa donde aparezca y lo devuelve `wait_halted`:

- `run()` marca una ejecución en curso al recibir la confirmación. Un `EVT_HALTED` que llega
  antes es de otra corrida, porque la FPGA nunca lo manda antes de confirmar el `RUN` (§3.5).
- La ejecución termina con el primer bloque de estado que no dice `RUNNING`: el
  `EVT_HALTED`, o la respuesta a `STATUS`, `STOP`, `LOAD` o `RESET`. Por eso `wait_halted`
  también vuelve cuando otro hilo manda `stop()` (estado `PAUSED`), y un `EVT_HALTED` que se
  pierde al vaciar la entrada no deja la espera colgada: el próximo `STATUS` dice que terminó.
- Los métodos se pueden llamar desde varios hilos: un lock serializa el acceso al puerto.
  `wait_halted` lo suelta mientras espera, para que la interfaz pueda mandar `STOP` desde
  otro hilo.

## 4. Tests

```sh
pip install -r tools/debugger/requirements-dev.txt
python -m pytest tools/debugger
```

No hace falta la FPGA ni `pyserial`. `tests/fake_debug_unit.py` tiene un puerto simulado
con una Debug Unit detrás que sigue el protocolo a nivel de tramas: la tabla de estados
(§3.7), los errores (§5), el descarte de bytes en reposo y el timeout entre bytes. El core
simulado no ejecuta instrucciones, solo avanza el PC hasta el HALT. Un reloj falso hace que
los timeouts y las esperas de los reintentos no demoren el test. El puerto permite perder,
cortar o corromper la próxima petición o respuesta, e inyectar basura en la línea.

| Archivo | Qué prueba |
|---|---|
| `test_tramas.py` | Las tramas de ejemplo de §4, byte por byte. Checksum, tramas mal formadas y los bloques de §3. El volcado `READ_ALL` del modelo de referencia, partido con el cliente, coincide con el estado del modelo |
| `test_cliente.py` | Cada comando contra la Debug Unit simulada. El filtro de `classify` antes de `LOAD`. Reintentos ante respuesta perdida o rota, `ERR_CHECKSUM` y `ERR_TIMEOUT`. `STEP` y `RUN` sin repetir a ciegas. El `EVT_HALTED` en medio de otra respuesta, el watchdog y `STOP` desde otro hilo |

## 5. Estructura

```
tools/debugger/
├── requirements.txt       pyserial
├── requirements-dev.txt   pytest
├── rvdebug/
│   ├── protocol.py        Tramas, checksum y bloques (§2 y §3), sin E/S
│   └── client.py          DebugClient: comandos, timeouts, reintentos y EVT_HALTED (§5)
├── serial_comm.py         Script de prueba del TP2 (ALU por UART); no es parte del cliente
└── tests/
```

**Si cambia `protocolo_debug.md`:** se actualizan `protocol.py`, la Debug Unit simulada de
`tests/fake_debug_unit.py` y las tramas de ejemplo de `test_tramas.py`, en el mismo PR que el
RTL.
