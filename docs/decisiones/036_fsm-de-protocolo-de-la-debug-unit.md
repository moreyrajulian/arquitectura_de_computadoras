# 036 - FSM de protocolo de la Debug Unit: alcance, puertos y reglas de validación

- **Estado:** propuesta
- **Fecha:** 2026-11-12
- **Autores:** Moreyra, Julián

## Contexto
La I-45 pide `rtl/debug/debug_unit.v` con la FSM de
[`protocolo_debug.md`](../spec/protocolo_debug.md): que reconozca todos los comandos, que
maneje los inválidos y los timeouts, y que un comando simple funcione de punta a punta. La
decisión [006](006_dos-fsm-debug-unit.md) ya separa la Debug Unit en dos FSM: la de protocolo
(recibe, valida, ejecuta y responde) y la de ejecución (`NO_PROG` … `HALTED`, `enable`,
`core_rst`, `halt`).

Los efectos de los comandos son de otras issues, de los dos integrantes:
- **I-46** (A): `LOAD` y `RESET`. Escribe `imem` por el puerto B, limpia `dmem` y el mapa de
  usadas (`memoria.md` §4 y §7). En el diagrama son los estados `LOAD_PREP` y `CLEAR`.
- **I-47** (B): la FSM de ejecución, `RUN`, `STEP` y `STOP`, y el `EVT_HALTED`. El diagrama
  tiene un estado `STEP_PULSE`.
- **I-48** (B): los datos de `READ_REGS`, `READ_LATCHES`, `READ_DMEM`, `READ_DMEM_USED` y
  `READ_ALL`, a partir de los buses de la decisión [023](023_interfaz-debug-del-core.md).
- **I-49** (B): el top que conecta core, memorias, Debug Unit y `uart`.

Hay que fijar dónde termina la I-45, con qué puertos se enganchan las demás, y tres reglas que
la spec deja abiertas:
- `protocolo_debug.md` §5 lista tres errores de encabezado (`ERR_UNKNOWN_CMD`, `ERR_LENGTH`,
  `ERR_STATE`), pero no dice cuál se responde si hay más de uno, ni qué pasa si además el `CHK`
  está mal.
- §5 dice "`LEN` inválido para el comando", pero solo §3.3 da la regla de `LOAD`.
- El bloque de estado (§3.1) tiene `pc` y `cycles`, que cambian en cada ciclo mientras el core
  corre (`STATUS` se acepta en `RUNNING`), y sale de a un byte cada ~87 µs.

El cliente de la PC ya existe (I-50). Su modelo de la FPGA (`tools/debugger/tests/fake_debug_unit.py`)
responde, en este orden: comando desconocido (también `0xE0` como petición), `LEN` (`LOAD`: 4N
con `1 ≤ N ≤ imem_words`; `READ_DMEM`: 6; el resto: 0), estado y checksum.

## Opciones consideradas

**Alcance de `debug_unit`**
1. **Toda la Debug Unit en un módulo** (protocolo, ejecución, carga y volcado).
   - Ventajas: un solo archivo con todo.
   - Desventajas: contradice la 006 (dos FSM, dos testbenches). Las I-46, I-47 e I-48 tocarían
     el mismo módulo a la vez, y el testbench de la I-45 no se podría escribir sin ellas.
2. **`debug_unit` es la FSM de protocolo, con puertos hacia el resto.** La FSM de ejecución es
   otro módulo (I-47). Las I-46 a I-48 se enganchan a puertos fijados acá.
   - Ventajas: es lo que pide la issue y lo que dice la 006. Cada issue tiene su frontera. El
     testbench de la I-45 reemplaza al resto con un modelo chico.
   - Desventajas: hay que acordar los puertos antes de que existan los módulos que los usan.

**Cómo avisa qué comando se aceptó**
1. **Un pulso por comando** (`o_run`, `o_stop`, `o_step`, …).
   - Ventajas: la FSM de ejecución no decodifica nada.
   - Desventajas: doce puertos, y cada consumidor mira solo dos o tres.
2. **Un pulso genérico, `o_cmd_valid`, y el código, `o_cmd`.**
   - Ventajas: un solo contrato para todos los consumidores. Cada uno decodifica con las
     constantes `DBG_CMD_*` de `riscv_defs.vh`.
   - Desventajas: la decodificación queda repetida en dos o tres módulos (una comparación cada
     una).

**De dónde salen los bytes de las lecturas**
1. **`debug_unit` recibe los buses** (latches, puerto de registros, puerto B de `dmem`) y arma
   el payload.
   - Ventajas: todo el formato del protocolo en un módulo.
   - Desventajas: la I-48 tendría que reescribir la FSM de la I-45, y el testbench de la I-45
     necesitaría el core.
2. **Índice y byte**: `debug_unit` publica el índice del byte que va a mandar (`o_pl_idx`) y
   recibe ese byte (`i_pl_byte`). La I-48 arma la fuente.
   - Ventajas: la FSM de protocolo no cambia en la I-48. Como cada byte espera a que la UART
     termine el anterior, la fuente tiene tiempo de leer una BRAM.
   - Desventajas: hay que fijar la latencia permitida.

**Orden de los errores de encabezado**
1. **Desconocido, `LEN`, estado; el `CHK` se mira solo si el encabezado está bien.**
   - Ventajas: es el orden del modelo del cliente, así que la PC y la FPGA no difieren. Va del
     más general al más particular: sin `CMD` conocido no se sabe qué `LEN` vale, y con `LEN`
     mal la trama no tiene la forma del comando.
   - Desventajas: una trama con el encabezado mal y el `CHK` mal responde el error de
     encabezado, aunque quizás el encabezado llegó corrompido. No cambia nada: no tiene efectos
     y la PC reintenta igual.
2. **El `CHK` primero.**
   - Ventajas: un error de transmisión no se reporta como un error de la PC.
   - Desventajas: habría que esperar el `CHK` para responder, y el modelo del cliente hace lo
     contrario.

**Cuándo se toma el bloque de estado**
1. **Byte por byte, de las entradas.**
   - Ventajas: sin registros.
   - Desventajas: en `RUNNING`, los bytes de `pc` y de `cycles` salen de ciclos distintos y el
     valor que arma la PC puede no haber existido nunca.
2. **Una foto (snapshot) al terminar de enviar el encabezado.**
   - Ventajas: los 12 bytes son del mismo ciclo. Para entonces ya pasaron los efectos del
     comando (un `STEP`, un `LOAD`), porque el encabezado tarda 5 bytes.
   - Desventajas: 96 flip-flops.

## Decisión
- **`rtl/debug/debug_unit.v` es solo la FSM de protocolo** (opción 2), con los estados del
  diagrama `debug_unit_fsm` de recepción, validación, `DISCARD`, `RX_CHK`, `EXEC` y transmisión.
  `RX_LEN` son dos estados, `RX_LEN_L` y `RX_LEN_H`. `LOAD_PREP` y `CLEAR` los agrega la I-46, y
  `STEP_PULSE` la I-47 si lo necesita. No usa `enable` (decisión
  [018](018_paso-a-paso-sin-clock.md)).
- **`uart` queda afuera**: `debug_unit` usa la interfaz de bytes de la decisión
  [035](035_uart-de-la-debug-unit.md), y el top (I-49) instancia los dos.
- **Puertos** (cabecera de `debug_unit.v` y `protocolo_debug.md` §7):
  - Entradas para el bloque de estado: `i_state` (de la FSM de ejecución), `i_prog_valid`,
    `i_halted`, `i_imem_fault`, `i_dmem_oob`, `i_dmem_misaligned`, `i_dmem_used`, `i_pc` e
    `i_cycles`. `debug_unit` arma el bloque de §3.1.
  - Comando aceptado: `o_cmd_valid` (opción 2), un pulso en `EXEC` solo si no hubo ningún
    error, con `o_cmd`, y `o_arg_addr` / `o_arg_count` para `READ_DMEM`. Una trama con error no
    pulsa nada: es la regla de §5 de que ningún comando con error tiene efectos.
  - Evento: `i_evt_pending` y `o_evt_done`, un pulso con el último byte del `EVT_HALTED`. Quien
    maneja `i_evt_pending` lo baja en ese mismo flanco.
  - Lecturas: `o_pl_idx` / `i_pl_byte` (opción 2). `i_pl_byte` puede llegar hasta 2 ciclos
    después de que cambie `o_pl_idx`, que cuenta desde el primer byte del payload. En
    `READ_ALL`, los 12 primeros bytes son el bloque de estado y los arma `debug_unit`; el índice
    no se reinicia, así que la fuente entrega desde `o_pl_idx = 12` (el byte 12 es `x0[7:0]`).
- **`INFO` sale completo de `debug_unit`**: la versión, `IMEM_WORDS`, `DMEM_WORDS`, las palabras
  de cada latch, calculadas como `ceil(NB / 32)` de los anchos de los buses (parámetros
  `NB_*_LATCH`), y `clk_khz = CLK_FREQ_HZ / 1000`.
- **Validación**: `ERR_UNKNOWN_CMD` (también `0xE0`), después `ERR_LENGTH` y después
  `ERR_STATE` (opción 1). Un error de encabezado se responde después de consumir `LEN + 1` bytes,
  aunque el `CHK` esté mal. `LEN` válido: `LOAD`, 4N con `1 ≤ N ≤ IMEM_WORDS`; `READ_DMEM`, 6;
  los demás, 0. `ERR_ADDR` de `READ_DMEM` se valida en `EXEC`.
- **Bloque de estado**: snapshot al terminar el encabezado (opción 2).
- **Codificaciones** del protocolo (`DBG_SOF_*`, `DBG_CMD_*`, `DBG_OK`, `DBG_ERR_*` y los estados
  `DBG_ST_*`) en `rtl/common/riscv_defs.vh`, porque las comparten la FSM de protocolo y la de
  ejecución (decisión [010](010_convenciones-rtl.md)).

## Consecuencias
- `protocolo_debug.md` §3.1 dice cuándo se toma el bloque, §5 da el orden de los errores y los
  `LEN` válidos, y §7 lista los puertos de `debug_unit` y qué issue engancha cada uno.
  `verificacion.md` §3.3 detalla los casos de `debug_cmd_fsm_tb.v`.
- **I-46** agrega `LOAD_PREP` al aceptar el encabezado de un `LOAD` (`core_rst = 1`,
  `prog_valid = 0`), el armado de palabras en `RX_PAYLOAD` y la escritura en `imem`, y `CLEAR`
  antes de la respuesta de `LOAD` y `RESET`. También tiene que dejar `NO_PROG` cuando un `LOAD`
  falla por checksum o por timeout: hoy `debug_unit` responde el error y no pulsa `o_cmd_valid`.
- **I-47** escribe la FSM de ejecución como otro módulo: genera `i_state`, `i_cycles` e
  `i_evt_pending` (lo baja con `o_evt_done`), y reacciona a `o_cmd_valid` con `RUN`, `STEP` y
  `STOP`. El `STEP` puede ser un pulso de `enable` en el ciclo siguiente a `o_cmd_valid`, o un
  estado `STEP_PULSE` en `debug_unit`. El snapshot asegura que la respuesta ya ve el `halt`
  (decisión 006).
- **I-48** arma la fuente de `i_pl_byte` con `o_cmd`, `o_pl_idx` y `o_arg_*`. No cambia la FSM.
- **I-49** conecta `uart` y `debug_unit` (y la FSM de ejecución) con el mismo `CLK_FREQ_HZ`.
- Si cambia el ancho de un latch en `pipeline.md` §8, `INFO` lo sigue cambiando el parámetro
  `NB_*_LATCH` en el top.
- El testbench tiene un modelo chico de las I-46 e I-47 (cambia el estado al aceptar `LOAD`,
  `RUN`, `STEP` y `STOP`, y baja `evt_pending`). Cuando existan, sus testbenches prueban la
  Debug Unit entera.
- `debug_cmd_fsm_tb` entra a la regresión con los demás unitarios (decisión
  [032](032_testbenches-unitarios-en-la-regresion.md)): pasan a ser 22.
