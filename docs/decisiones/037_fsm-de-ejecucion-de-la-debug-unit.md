# 037 - FSM de ejecución de la Debug Unit: STEP, enable, prioridades y gancho de la carga

- **Estado:** propuesta
- **Fecha:** 2026-11-13
- **Autores:** Costamagna, Matías

## Contexto
La I-47 pide los dos modos de la consigna, continuo y paso a paso, sin intervenir el clock. La
decisión [006](006_dos-fsm-debug-unit.md) separa la Debug Unit en dos FSM, y la
[036](036_fsm-de-protocolo-de-la-debug-unit.md) ya escribió la de protocolo (`debug_unit`):
valida cada trama, pulsa `o_cmd_valid` con el comando aceptado, toma el bloque de estado al
terminar el encabezado de la respuesta y manda el `EVT_HALTED` cuando ve `i_evt_pending` en
reposo. Falta la FSM de ejecución: el estado (`NO_PROG` … `HALTED`), `enable`, `core_rst`,
`cycles` y `evt_pending`.

La spec fija casi todo lo que se ve desde la PC (`protocolo_debug.md` §3.5 y §3.7, diagrama
`debug_unit_estados_core`), pero deja abiertas cuatro cosas:
- La 036 deja a la I-47 elegir dónde se genera el ciclo de `enable` del `STEP`: un estado
  `STEP_PULSE` en `debug_unit` o un pulso en la FSM de ejecución.
- La 006 dice que `enable` baja en el mismo ciclo en que llega `halt`, y la
  [018](018_paso-a-paso-sin-clock.md) avisa que eso pone el camino `halted` → `enable` → CE de
  todo el core en el análisis de timing.
- Qué gana cuando en un mismo ciclo coinciden un comando y el `halt`: `STOP` y `halt`, o
  `RESET`/`LOAD` y `halt`. Con dos FSM independientes puede pasar, porque el core corre mientras
  entra una trama.
- Quién mueve el estado en `LOAD` y `RESET`: la 036 le pide a la I-46 que un `LOAD` que falla
  deje `NO_PROG`, pero el registro de estado es de la FSM de ejecución.

La issue también pide definir qué pasa con un `STEP` después de `halted`. La tabla de §3.7 ya
responde `ERR_STATE`, y `debug_unit` lo rechaza en `CHECK_HDR`; falta dejar el porqué.

## Opciones consideradas

**Dónde sale el ciclo del `STEP`**
1. **Un estado `STEP_PULSE` en `debug_unit`**, como dibuja `debug_unit_fsm`.
   - Ventajas: el pulso está en la misma FSM que el comando.
   - Desventajas: `enable` saldría de los dos módulos (`RUNNING` de uno y `STEP_PULSE` del
     otro), y hay que cambiar `debug_unit`, que ya está probado.
2. **Un pulso en la FSM de ejecución**: con `o_cmd_valid` y `STEP`, un registro `step` vale 1
   durante el ciclo siguiente.
   - Ventajas: `enable` sale de un solo lugar y `debug_unit` no cambia. El ciclo del core es el
     siguiente a `o_cmd_valid`, y la foto del bloque de estado se toma 5 bytes después (decisión
     036), así que la respuesta ya ve ese ciclo y, si el HALT llegó a WB, el estado `HALTED`.
   - Desventajas: el diagrama `debug_unit_fsm` cambia (sin `STEP_PULSE`).

**Cómo baja `enable` con `halt`**
1. **Combinacional:** `enable = (RUNNING | step) & ~halted`.
   - Ventajas: es lo que dice la 006. El ciclo con el HALT en WB es el último con `enable = 1`, y
     `cycles`, que cuenta los ciclos con `enable = 1`, da los `ciclos` del `.exp`
     (`verificacion.md` §5) sin ninguna corrección.
   - Desventajas: `halted` (un flip-flop de `wb_stage`) pasa por una compuerta antes de llegar al
     CE de unos 1.400 flip-flops.
2. **Registrado:** `enable` sale de un flip-flop que baja en el flanco siguiente a `halted`.
   - Ventajas: el camino a los CE empieza en un flip-flop.
   - Desventajas: el core corre un ciclo más con `halted = 1`. No cambia el estado (detrás del
     HALT solo hay burbujas y `halted` mantiene la parada, `pipeline.md` §3.4), pero `cycles`
     tendría que excluir ese ciclo y dejaría de ser "ciclos con `enable = 1`".

**Prioridades dentro de un ciclo**
1. **`LOAD`/`RESET`, después `halt`, después `STOP`.** `LOAD` y `RESET` terminan la ejecución
   pase lo que pase. Si `STOP` y `halt` coinciden, el programa terminó: `HALTED` y
   `EVT_HALTED`.
2. **`STOP` antes que `halt`.** El core quedaría en `PAUSED` con `halted = 1`, un estado que el
   diagrama no tiene; un `RUN` o `STEP` después no haría nada.

**Un `EVT_HALTED` pendiente cuando llega `LOAD` o `RESET`**
1. **Se descarta.** La ejecución terminó con el `LOAD` o el `RESET`, que ya dicen el estado en
   su respuesta.
   - Ventajas: la FPGA no manda un evento con un bloque de estado de después del reset (estado
     `READY`, `cycles = 0`), que no es el final de ninguna ejecución.
   - Desventajas: ninguna para el cliente: ya descarta un `EVT_HALTED` que llega sin ejecución
     en curso (`client.py`, `_event`).
2. **Se manda igual**, después de la respuesta.
   - Desventajas: el evento llega con el estado del core reseteado.

**Quién mueve el estado en `LOAD` y `RESET`**
1. **La I-46**, como sugiere la 036.
   - Desventajas: el registro de estado tendría dos escritores en dos módulos.
2. **La FSM de ejecución, con dos entradas para la I-46:** `i_load_start` (se aceptó el
   encabezado de un `LOAD`: `NO_PROG`, `prog_valid = 0`) e `i_mem_busy` (mientras escribe `imem`
   o limpia `dmem`, de `LOAD_PREP` a `CLEAR`: mantiene `core_rst`). El `LOAD` que termina bien y
   el `RESET` llegan por `o_cmd_valid`.
   - Ventajas: un solo dueño del estado. Un `LOAD` que falla por checksum o por timeout ya quedó
     en `NO_PROG` desde el encabezado, así que la I-46 no tiene que hacer nada más para ese caso.
     Hasta que llegue la I-46, las dos entradas van en 0 y `LOAD`/`RESET` igual llevan el core a
     `READY` con un ciclo de `core_rst`.
   - Desventajas: la interfaz con la I-46 queda fijada antes de que exista; hay que acordarla
     con quien la hace.

**`STEP` después de `halted`**
1. **`ERR_STATE`, como §3.7.** Se vuelve a ejecutar con `RESET` o `LOAD`.
2. **OK sin efectos**, como `STOP` fuera de `RUNNING`.
   - Desventajas: con `halted = 1` el core no avanza (`stop_fetch` y `halted` mantienen la
     parada), así que `cycles` no sumaría 1. La PC usa justamente "`cycles` aumentó en 1" para
     saber si un `STEP` cuya respuesta se perdió se hizo (§5): un OK que no avanza rompe esa
     regla.
3. **Un `RESET` implícito.** Desventajas: un comando que hace otra cosa según el estado, y la PC
   perdería el estado final sin pedirlo.

## Decisión
- **Módulo `rtl/debug/debug_exec.v`**, la FSM de ejecución, aparte de `debug_unit` (006, 036).
- **El `STEP` es un pulso en `debug_exec`** (opción 2): `enable = 1` exactamente en el ciclo
  siguiente a `o_cmd_valid`. `debug_unit` no cambia y no tiene `STEP_PULSE`.
- **`enable = (RUNNING | step) & ~halted`, combinacional** (opción 1), como la 006. `cycles`
  cuenta los ciclos con `enable = 1`. Si la I-56 encuentra que el camino `halted` → CE limita la
  frecuencia, se pasa a la opción 2 y `cycles` excluye el ciclo extra (la 018 ya lo prevé).
- **`core_rst = i_rst | NO_PROG | pulso | i_mem_busy`**, donde el pulso es un ciclo después del
  `o_cmd_valid` de `LOAD` y de `RESET`.
- **Prioridades** (opción 1), de mayor a menor: `i_rst`, `i_load_start`, `LOAD`, `RESET`,
  `halted` (en `RUNNING` o `PAUSED`), `RUN`, `STEP`, `STOP`. `halted` marca el `EVT_HALTED`
  solo desde `RUNNING`: en `PAUSED` llegó con un `STEP` (lo dice su respuesta) o con un `STOP`
  del ciclo anterior (también lo dice la respuesta del `STOP`, tomada miles de ciclos después).
- **`LOAD` y `RESET` descartan un `EVT_HALTED` pendiente** (opción 1).
- **`debug_exec` es el único dueño del estado** (opción 2), con `i_load_start` e `i_mem_busy`
  para la I-46.
- **`STEP` y `RUN` en `HALTED` responden `ERR_STATE`** (opción 1, la tabla de §3.7). Los ignora
  también `debug_exec`, por si algún día llegaran.

## Consecuencias
- `protocolo_debug.md` §3.5 dice en qué ciclo cae el `STEP`, qué gana con `halt` y que `LOAD`
  y `RESET` descartan el evento pendiente; §7 lista los puertos de `debug_exec`. El diagrama
  `debug_unit_fsm` pierde `STEP_PULSE`, y `debug_unit_estados_core` muestra la fórmula de
  `enable` y la transición `PAUSED` → `HALTED` con `halt`.
- **I-46** maneja `i_load_start` (pulso al aceptar el encabezado de un `LOAD`, en `LOAD_PREP`) e
  `i_mem_busy` (de `LOAD_PREP` a `CLEAR`). No escribe el estado ni `prog_valid`. Si el `CLEAR` va
  después de `EXEC`, el `LOAD` y el `RESET` ya llegaron por `o_cmd_valid`; `i_mem_busy` solo
  mantiene el reset mientras tanto.
- **I-48** no cambia: lee con el core detenido, y `READ_*` en `RUNNING` ya es `ERR_STATE`.
- **I-49** conecta `debug_exec` entre `debug_unit` y el core: `o_state`, `o_prog_valid`,
  `o_cycles` y `o_evt_pending` van a `debug_unit`; `o_enable` y `o_core_rst`, al core; `halted`
  vuelve del core.
- **I-56** revisa el camino `halted` → `enable` → CE.
- `debug_run_tb` (`verificacion.md` §3.3) prueba los modos desde tramas UART con el core real y
  un core de referencia, y las prioridades sobre `debug_exec` solo. Entra a la regresión con los
  demás unitarios (decisión [032](032_testbenches-unitarios-en-la-regresion.md)): pasan a ser 23.
