# rvdebug: cliente del protocolo de la Debug Unit y debugger

Para empezar a usarlo con la placa, ver [*Inicio rápido*](#inicio-rápido).

`rvdebug` tiene dos partes, y dos scripts que la usan para verificar la placa:
- **El debugger de texto** (`debugger.py`, I-52): la interfaz de
  [`interfaz_pc.md`](../../docs/spec/interfaz_pc.md) con Textual. Cómo se usa, en la §7.
- **La verificación contra el modelo de referencia:** `placa.py` (§4) corre los programas
  del plan y los compara con su `.exp` y con el modelo; `comparar.py` (§8, I-54) compara
  cualquier programa con el modelo en cualquier ciclo.
- **El cliente del protocolo** (I-50), §1 a §3: la capa que habla el protocolo de [`protocolo_debug.md`](../../docs/spec/protocolo_debug.md)
con la FPGA: arma y valida las tramas, maneja timeouts y reintentos, y recibe el
`EVT_HALTED`. Es la capa `client` de [`interfaz_pc.md`](../../docs/spec/interfaz_pc.md) §1:
Python puro, sin Textual, para que la usen la interfaz (I-52), la prueba en placa (I-49) y
los tests sin levantar la TUI.

| | |
|---|---|
| **Issues** | I-50 — Cliente del protocolo; I-52 — Interfaz de usuario (decisión [040](../../docs/decisiones/040_interfaz-de-usuario.md)); I-53 — Vista del pipeline (decisión [043](../../docs/decisiones/043_vista-del-pipeline.md)); I-54 — Verificación automática y documentación |
| **Requisitos** | Python ≥ 3.11. `pyserial` para el puerto real y `textual` para el debugger (`requirements.txt`). Tests: `pytest`, sin FPGA; los de la interfaz necesitan `textual` y se saltean sin él. Usa `assemble`, `classify` y `disassemble` del ensamblador de [`tools/assembler`](../assembler/README.md) y el modelo de referencia de [`tools/isasim`](../isasim/README.md) |
| **Protocolo** | Versión 1, 115200 8N1 |

## Inicio rápido

### Instalación

Python 3.11 o más nuevo. Desde la raíz del repo, en un entorno virtual:

```sh
python -m venv .venv
.venv\Scripts\Activate.ps1                  # Windows (PowerShell)
source .venv/bin/activate                   # Linux
pip install -r tools/debugger/requirements.txt          # pyserial y textual
```

El ensamblador (`tools/assembler`) y el modelo de referencia (`tools/isasim`) no tienen
dependencias: los scripts los agregan solos al path. Para los tests, `requirements-dev.txt`
(§5).

### Programar la placa

1. En Vivado, *Tools > Run Tcl Script...* con `scripts/create_project.tcl` (crea el proyecto
   `riscv_basys3` en `build/vivado_riscv_basys3/`, [`fpga/README.md`](../../fpga/README.md)).
2. *Generate Bitstream* y, con la Basys 3 conectada por el USB de programación, *Open
   Hardware Manager > Program Device*.
3. Después de programar, LD0 (`NO_PROG`) encendido y LD15 latiendo a 2 Hz. Si LD15 está quieto
   no hay reloj o el botón de reset está apretado ([`fpga/README.md`](../../fpga/README.md)).

### Conexión

| | Windows | Linux |
|---|---|---|
| Puerto | `COMn`. En el *Administrador de dispositivos*, *Puertos (COM y LPT)* > *USB Serial Port (COMn)*. El FT2232 de la placa crea dos: la UART suele ser el de número más alto | `/dev/ttyUSBn`, la UART suele ser `ttyUSB1`. El usuario tiene que estar en el grupo `dialout` (`uucp` en Arch) |
| Listar los puertos | `python -m serial.tools.list_ports -v`: la placa tiene VID/PID `0403:6010` | Lo mismo |
| Otros programas | Cerrar PuTTY, el monitor serie de Vivado y cualquier otro que tenga el puerto abierto | Además, ModemManager puede tomarlo al conectar la placa |

La UART va a **115200 baudios, 8N1**. Lo fija el hardware (decisión
[003](../../docs/decisiones/003_baudrate-uart.md)): los scripts lo usan por defecto, y `--baud`
del debugger solo cambia si cambia el bitstream. Los detalles de cada sistema (terminal y
puerto) están en [`interfaz_pc.md`](../../docs/spec/interfaz_pc.md) §6.

Un puerto lo usa un solo programa a la vez: para correr `placa.py` o `comparar.py` hay que
cerrar el debugger, y al revés.

### Comandos

| Comando | Para qué |
|---|---|
| `python tools/debugger/debugger.py --port COM10 --prog sw/alu_r.s` | El debugger de texto: cargar, ejecutar, paso a paso y ver registros, latches, memoria y pipeline. Teclas en la §7 |
| `python tools/debugger/comparar.py COM10 sw/alu_r.s` | Comparar un programa en la placa con el modelo de referencia, al final o en un ciclo (§8) |
| `python tools/debugger/placa.py COM10` | La prueba en placa de todos los programas del plan, contra su `.exp` y el modelo (§4) |
| `python tools/assembler/asm.py prog.s -o prog.lst` | El listado con direcciones, para saber qué hay en cada PC ([README](../assembler/README.md)) |

### Problemas frecuentes

| Síntoma | Causa probable |
|---|---|
| `no se pudo conectar con la FPGA` o `NoResponseError` | El puerto es la otra interfaz del FT2232 (JTAG), la placa no está programada, o otro programa tiene el puerto. Con LD15 quieto, el reset está apretado |
| `Permission denied` al abrir el puerto (Linux) | Falta el grupo `dialout`: `sudo usermod -aG dialout $USER` y volver a iniciar sesión |
| `la FPGA informa (…) palabras por latch y el modelo (…)` | El bitstream es de otra versión de [`pipeline.md`](../../docs/spec/pipeline.md) §8: volver a generarlo |
| El debugger se ve cortado, con bordes `?` o sin colores | La terminal es chica (mínimo 160 × 45), no es UTF-8 (`export LANG=C.UTF-8`) o es la consola clásica de Windows en lugar de Windows Terminal |
| `RUN` no termina y aparece el aviso del watchdog | El programa no tiene HALT o queda en un lazo: Detener (F6) y seguir paso a paso |

### Capturas de pantalla

Textual guarda la pantalla del debugger como SVG: `Ctrl+P` > *Screenshot*. Una notificación
dice dónde quedó el archivo. Para la salida de `placa.py` y `comparar.py` alcanza con la
terminal.

Para capturar el debugger y la comparación del **mismo estado**, sin soltar la placa:

1. Con el debugger, llevar la placa al ciclo que interesa y sacar la captura. Va primero: al
   desconectar, los paneles quedan vacíos.
2. `F1` (desconectar) cierra el puerto. La placa conserva su estado: abrir o cerrar el puerto
   no la resetea, porque la UART solo tiene `rx` y `tx`.
3. En otra terminal, `comparar.py PUERTO programa.s --sin-cargar`, con **el mismo programa que
   se cargó**. Con otro programa, todas las diferencias que muestra son falsas.
4. `F1` vuelve a conectar. Es una sesión nueva: para ver de nuevo las etapas del pipeline hay
   que volver a cargar el programa.

Las capturas del informe están en [`docs/capturas/`](../../docs/capturas):

| Archivo | Qué muestra |
|---|---|
| `debugger_alu_r_ciclo14.svg` | El debugger con `alu_r.s` en el ciclo 14 (`PAUSED`), en la placa a 65 MHz |
| `comparar_alu_r_y_mixto_lazo.png` | `comparar.py --sin-cargar` sobre ese mismo estado («ciclo 14: coincide con el modelo») y `mixto_lazo --cada-ciclo` («83 ciclos: todos coinciden con el modelo») |

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

## 4. Prueba en placa (`placa.py`)

El nivel 5 de [`verificacion.md`](../../docs/spec/verificacion.md) (I-49 e I-55): carga
programas de `sw/` en la Basys 3 y compara lo que devuelve la Debug Unit con dos oráculos
escritos por separado, el `.exp` a mano y el modelo de referencia
([`isasim`](../isasim/README.md), modo completo).

```sh
pip install -r tools/debugger/requirements.txt          # pyserial
python tools/debugger/placa.py COM10                   # los 22 programas del plan
python tools/debugger/placa.py /dev/ttyUSB1 fwd_exmem mixto_lazo
python tools/debugger/placa.py COM10 --nops            # más las 10 variantes _nops
python tools/debugger/placa.py COM10 --sin-paso        # solo la pasada con RUN
```

Antes: programar la FPGA con el bitstream de `riscv_basys3` y cerrar cualquier otro programa
que tenga el puerto abierto. El nombre del puerto y los permisos en Linux están en
[`interfaz_pc.md`](../../docs/spec/interfaz_pc.md) §6 (*Puerto serie*).

Para cada programa hace dos pasadas:

| Pasada | Comandos | Contra qué compara |
|---|---|---|
| RUN | `LOAD`, `RUN`, `EVT_HALTED`, `READ_ALL` | El `.exp`: registros, dmem (las palabras usadas; el resto vale 0 después de `LOAD`), `halted`, `pipeline_vacio`, avisos y `ciclos`. El modelo: el bloque de estado entero (también el PC), registros, memoria usada y los latches finales |
| STEP | `RESET` y `STEP` hasta `HALTED`, con `READ_LATCHES` después de cada paso | Cada latch contra la foto del modelo en ese ciclo, en los bits de su máscara (en una burbuja, solo `valid` y el control, [`isasim`](../isasim/README.md) §3), y el relleno de la última palabra en 0. `cycles` aumenta de a 1 y pasa a `HALTED` en el ciclo del modelo. Al final, `READ_ALL` igual al de la pasada RUN |

Imprime un renglón por programa (`OK` o `FALLA`, con hasta 12 diferencias, que dicen la
pasada, el paso, el latch y el campo) y un resumen. Termina con 0 si todos coinciden, 1 si
alguno difiere y 2 si no pudo probar: un programa que no existe o es `indep_*` (necesitan el
estado inicial de `sw/estado_inicial`, y `LOAD` deja el banco en cero), el puerto no abre, la
FPGA no responde o informa otras palabras por latch que el modelo.

La pasada STEP manda dos peticiones por ciclo, y cada una espera la latencia del USB (hasta
16 ms con el *latency timer* del FT2232). Para los programas largos tarda unos segundos;
`--sin-paso` la saltea.

## 5. Tests

```sh
pip install -r tools/debugger/requirements-dev.txt
python -m pytest tools/debugger
```

No hace falta la FPGA ni `pyserial`. Sin `textual`, `test_tui.py` se saltea. `tests/fake_debug_unit.py` tiene un puerto simulado
con una Debug Unit detrás que sigue el protocolo a nivel de tramas: la tabla de estados
(§3.7), los errores (§5), el descarte de bytes en reposo y el timeout entre bytes. El core
de `FakeDebugUnit` no ejecuta instrucciones, solo avanza el PC hasta el HALT. El de
`ModelDebugUnit` es el modelo de referencia: después de k ciclos el volcado (PC, registros,
latches, memoria usada y avisos) es la foto k de `isasim`. Un reloj falso hace que los
timeouts y las esperas de los reintentos no demoren el test. El puerto permite perder,
cortar o corromper la próxima petición o respuesta, e inyectar basura en la línea.

| Archivo | Qué prueba |
|---|---|
| `test_tramas.py` | Las tramas de ejemplo de §4, byte por byte. Checksum, tramas mal formadas y los bloques de §3. El volcado `READ_ALL` del modelo de referencia, partido con el cliente, coincide con el estado del modelo |
| `test_model.py` | Nombres ABI, hex y decimal con y sin signo, `Snapshot`, los campos de cada latch (sin el relleno, y `None` con otras palabras por latch), `word_at` (resto en HALT, alias `addr[11:2]`) y `diff` (en una burbuja solo `valid` y el control) |
| `test_hazards.py` | La inferencia de riesgos (`interfaz_pc.md` §4.3): en cada ciclo de los programas del plan y sus variantes `_nops`, el stall, el salto tomado y el HALT deducidos coinciden con los eventos del modelo, sin inconsistencias. A mano: el stall y las cajas del ciclo 7 del boceto, el forwarding (prioridad, x0, operando que no se usa, burbujas), el flush, el HALT sin stalls falsos y cada inconsistencia |
| `test_session.py` | Cada control de `Session` contra la Debug Unit simulada (qué comandos manda y qué devuelve), la lectura de `.s`, `.hex` y `.bin`, los errores de ensamblado y las palabras rechazadas sin `LOAD`, Paso×N que corta en `HALTED`, el watchdog y la tabla de controles habilitados de `interfaz_pc.md` §3. Con `ModelDebugUnit`: el historial, contra qué volcado se compara cada acción, la columna «Escrito» y `run_to` (llega a WB, termina en `HALTED`, límite y cancelado) |
| `test_tui.py` | La app con `App.run_test()` y Pilot a 160 × 45: conectar con `--port` y F1, cargar con `--prog` y F2, la tabla de registros (ABI, `d`, `0`), los controles deshabilitados en cada estado, Paso×N, los errores de ensamblado, el watchdog y la confirmación de Cargar en `RUNNING`, y los selectores de archivo y de puerto. La vista del pipeline en el ciclo 7 del boceto (cajas, eventos, etapas en Programa, resaltado, «Escrito», historial y barra de estado), los latches con `c`, el historial con Enter y Esc, F4 y el final de `RUN` |
| `test_cliente.py` | Cada comando contra la Debug Unit simulada. El filtro de `classify` antes de `LOAD`. Reintentos ante respuesta perdida o rota, `ERR_CHECKSUM` y `ERR_TIMEOUT`. `STEP` y `RUN` sin repetir a ciegas. El `EVT_HALTED` en medio de otra respuesta, el watchdog y `STOP` desde otro hilo |
| `test_placa.py` | `placa.py` contra una Debug Unit simulada cuyo core es el modelo de referencia: los 22 programas del plan (y las variantes `_nops`) pasan; un registro mal, un aviso de más, un `valid` mal en un paso y el relleno distinto de 0 se informan donde corresponde; un dato de una burbuja no se compara; los `indep_*`, una FPGA muda y otras palabras por latch terminan con 2 |
| `test_comparar.py` | `comparar.py` contra la misma Debug Unit simulada: todos los `.s` de `sw/` coinciden con `RUN` (también los `indep_*`); `--ciclos` (corta en `HALTED`), `--cada-ciclo`, `--sin-cargar`, un `.hex` y un programa sin HALT. Un registro mal, un aviso de más y un `valid` mal en un paso se informan en su ciclo, y `--cada-ciclo` corta en la primera diferencia; un dato de una burbuja no se compara; una placa que no termina se detiene con `STOP`. Terminan con 2: un programa sin HALT sin `--ciclos`, un ciclo fuera de lo que simuló el modelo, la placa en `NO_PROG` o `RUNNING` con `--sin-cargar`, opciones incompatibles, errores de ensamblado, una FPGA muda y otras palabras por latch |

## 6. Estructura

```
tools/debugger/
├── debugger.py            Punto de entrada del debugger (§7)
├── requirements.txt       pyserial y textual
├── requirements-dev.txt   pytest y textual
├── rvdebug/
│   ├── protocol.py        Tramas, checksum y bloques (§2 y §3), sin E/S
│   ├── client.py          DebugClient: comandos, timeouts, reintentos y EVT_HALTED (§5)
│   ├── model.py           Snapshot, campos de los latches, word_at, diff, nombres ABI (sin Textual)
│   ├── hazards.py         analyze: las etapas y los riesgos inferidos de un volcado (sin Textual)
│   ├── session.py         Session: la secuencia de cada control, los controles habilitados,
│   │                      el historial y run_to (F4)
│   └── tui/               DebuggerApp (Textual): paneles, modales y estilo (debugger.tcss)
├── placa.py               Prueba en placa (§4)
├── comparar.py            Un programa en la placa contra el modelo de referencia (§8)
├── serial_comm.py         Script de prueba del TP2 (ALU por UART); no es parte del cliente
└── tests/
```

**Si cambia `protocolo_debug.md`:** se actualizan `protocol.py`, la Debug Unit simulada de
`tests/fake_debug_unit.py` y las tramas de ejemplo de `test_tramas.py`, en el mismo PR que el
RTL.

## 7. Debugger de texto

```sh
pip install -r tools/debugger/requirements.txt
python tools/debugger/debugger.py --port COM10 --prog sw/alu_r.s    # Windows
python tools/debugger/debugger.py --port /dev/ttyUSB1               # Linux
```

| Opción | Qué hace |
|---|---|
| `--port` | Puerto serie. Sin él, F1 lista los puertos y propone el FT2232 de la placa (VID/PID `0403:6010`) |
| `--prog` | Programa a cargar apenas conecta (`.s`, `.hex` o `.bin`) |
| `--baud` | Baudrate (115200 por defecto) |
| `--watchdog` | Segundos de `RUN` sin `EVT_HALTED` antes de preguntar si se detiene (5 por defecto) |

La terminal tiene que tener al menos 160 × 45. En Windows, con Windows Terminal; los
requisitos de cada sistema y del puerto están en
[`interfaz_pc.md`](../../docs/spec/interfaz_pc.md) §6.

| Tecla | Control | Cuándo se puede |
|---|---|---|
| `F1` | Conectar / desconectar (`INFO`, `STATUS`, `READ_ALL`) | Siempre |
| `F2` | Cargar un `.s` (lo ensambla), `.hex` o `.bin`: `LOAD` + `READ_ALL`. Los errores de ensamblado y las palabras fuera de `isa.md` se muestran sin mandar nada | Conectado (en `RUNNING` pide confirmación) |
| `F5` | Ejecutar: `RUN` hasta el `EVT_HALTED`, con `STATUS` cada 0,5 s y el aviso del watchdog | `READY`, `PAUSED` |
| `F10` | Paso: `STEP` + `READ_ALL` | `READY`, `PAUSED` |
| `Shift+F10` | Paso×N: N `STEP` (corta en `HALTED`) y un `READ_ALL` | `READY`, `PAUSED` |
| `F4` / Enter en Programa | Hasta cursor: `STEP` + `READ_LATCHES` hasta que la línea elegida llegue a WB, `HALTED` o 2000 ciclos, y un `READ_ALL`. Esc lo cancela | `READY`, `PAUSED`, con un programa cargado |
| `F6` | Detener: `STOP` + `READ_ALL` | `RUNNING` |
| `F3` | Reiniciar: `RESET` + `READ_ALL` | Conectado |
| `F8` | Reprogramar: vuelve a ensamblar el mismo archivo y lo carga | Con un programa cargado |
| `F9` | Refrescar: `READ_ALL` | Todos menos `RUNNING` |
| `d` / `0` | Registros: decimal con o sin signo / ocultar los que valen 0 | Siempre |
| `c` | Latches: campo por campo o las palabras de 32 bits crudas | Siempre |
| Enter en Historial | Muestra ese volcado (solo lectura); Esc vuelve al actual | Siempre |
| `t` | Mostrar u ocultar las tramas | Siempre |
| `q` | Salir | Siempre |

La pestaña «Rango» de Memoria pide dirección y cantidad (`READ_DMEM`). La comparación con el
modelo de referencia no está en el debugger: la hace `comparar.py --sin-cargar` sobre el
estado en que quedó la placa (§8).

**Vista del pipeline** (I-53, decisión
[043](../../docs/decisiones/043_vista-del-pipeline.md)):

- **Pipeline:** cinco cajas con la instrucción de cada etapa. La de ID sale de `IF/ID.instr`;
  las demás, de lo que se cargó con `LOAD` en el `pc` de su latch. Debajo, los riesgos que
  deduce la PC: stall, forwarding, salto tomado o flush, HALT en vuelo e inconsistencias
  (`interfaz_pc.md` §4.3).
- **Programa:** la etapa de cada instrucción (`*` = retenida por un stall).
- **Resaltado:** en amarillo lo que cambió en Registros, Memoria y Latches. El historial
  guarda cada volcado con sus eventos y sus cambios.

Si la placa ya tenía un programa que no cargó esta PC, las etapas que no son ID muestran `?`.

Las capas `model` y `session` no dependen de Textual:

```python
from rvdebug import DebugClient, Session, open_serial
s = Session(DebugClient(open_serial("COM10")))
s.connect()
s.load_file("sw/alu_r.s")           # LOAD + READ_ALL; AssemblerError si el .s está mal
snap = s.step_n(10)                 # Snapshot: status, regs, latches, used
snap.fields["mem_wb"]["pc"]         # los latches campo por campo (pipeline.md §8)
entry = s.last                      # Entry: action, snapshot, diff, analysis
entry.diff.summary(entry.snapshot)  # "x3=12, M[0x0]=12"
[e.text for e in entry.analysis.events]   # riesgos inferidos
s.run_to(0x14)                      # hasta que la instrucción de 0x14 llegue a WB
s.run(); snap = s.wait_halted()
```

## 8. Comparar con el modelo de referencia (`comparar.py`)

La I-54: lleva un programa a un ciclo en la placa y compara el volcado de `READ_ALL` con la
foto del modelo de referencia ([`isasim`](../isasim/README.md), modo completo) en ese mismo
ciclo. A diferencia de `placa.py` (§4), sirve para **cualquier programa** (`.s`, `.hex` o
`.bin`, sin `.exp` y también sin HALT) y para **cualquier ciclo**.

```sh
python tools/debugger/comparar.py COM10 sw/fwd_exmem.s           # LOAD, RUN hasta HALTED
python tools/debugger/comparar.py COM10 fwd_exmem --ciclos 7     # LOAD y 7 STEP (un nombre de sw/)
python tools/debugger/comparar.py COM10 mi_prog.s --cada-ciclo   # compara después de cada STEP
python tools/debugger/comparar.py COM10 mi_prog.s --sin-cargar   # el estado actual de la placa
```

| Opción | Qué hace |
|---|---|
| (ninguna) | `LOAD`, `RUN`, `EVT_HALTED` y `READ_ALL`: contra la foto final del modelo. Si la placa no termina en `--timeout` segundos (5 por defecto), manda `STOP` y termina con 1 |
| `--ciclos N` | `LOAD` y `N` `STEP` (corta en `HALTED`), y compara ahí. Hace falta para un programa sin HALT |
| `--cada-ciclo` | `READ_ALL` y comparación después de `LOAD` y de cada `STEP`, hasta `HALTED` (o `N` con `--ciclos`). Corta en la **primera** diferencia, que es la que importa |
| `--sin-cargar` | No manda `LOAD` ni avanza: compara el estado en que quedó la placa en su ciclo. La placa tiene que tener este programa corrido desde `LOAD` o `RESET`, con cualquier combinación de `STEP`, `RUN` y `STOP` (por ejemplo, desde el debugger, cerrándolo antes). No va con `--ciclos` ni `--cada-ciclo` |
| `--max-ciclos N` | Ciclos que simula el modelo para un programa sin HALT (100 000 por defecto) |

Qué se compara, igual que en `placa.py`: el bloque de estado (`state`, `flags` con `halted` y
los avisos, `dmem_used`, `pc` y `cycles`), los 32 registros, la memoria usada (dirección y
valor) y los cuatro latches en los bits de su máscara (en una burbuja, solo `valid` y el
control; [`isasim`](../isasim/README.md) §3). Las funciones de los latches y de los flags son
las de `placa.py`, así las dos comparan igual. Los `indep_*` sí se pueden comparar: los dos
lados parten de todo en cero después de `LOAD`, aunque no sea el estado de su `.exp`.

```
INFO: protocolo 1, imem 1024, dmem 1024, latches 3/6/4/4 palabras, 65000 kHz
fwd_exmem.s: 8 palabras; el modelo termina en 12 ciclos
LOAD y 12 STEP, comparando cada ciclo
primera diferencia en el ciclo 3:
ciclo 3: 1 diferencia con el modelo
    IF/ID.valid: placa 0x0, modelo 0x1
```

Termina con 0 si coincide, 1 si hay diferencias (o la placa no termina y el modelo sí) y 2 si
no se pudo comparar: el programa no existe o no ensambla, el modelo no lo puede simular, no
llega a HALT sin `--ciclos`, el ciclo pedido o el de la placa supera `--max-ciclos`, la placa
está en `NO_PROG` o `RUNNING` con `--sin-cargar`, el puerto no abre, la FPGA no responde o
informa otras palabras por latch que el modelo.
