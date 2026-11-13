# 038 - Carga de programa en la Debug Unit: contrato con la FSM de ejecución y con el mapa de usadas

- **Estado:** propuesta
- **Fecha:** 2026-11-13
- **Autores:** Moreyra, Julián

## Contexto
La I-46 agrega `LOAD` y `RESET` a la FSM de protocolo (`rtl/debug/debug_unit.v`, decisión
[036](036_fsm-de-protocolo-de-la-debug-unit.md)). El mecanismo ya está fijado:
- La decisión [004](004_carga-y-reprogramacion.md) fija qué limpia `LOAD` (memoria de datos,
  registros, pipeline y mapa de usadas) y que el resto de `imem` se rellena con HALT. También
  responde las preguntas de la consigna.
- La decisión [014](014_bram-y-escritura-de-programa.md) y [`memoria.md`](../spec/memoria.md)
  §4 fijan cómo se escribe: por el puerto B con el core detenido y en reset, una palabra por
  cada 4 bytes. `CLEAR` recorre las BRAM una vez.
- La FSM de ejecución es `rtl/debug/debug_exec.v` (I-47, decisión
  [037](037_fsm-de-ejecucion-de-la-debug-unit.md)) y es la única dueña del estado
  (`NO_PROG` … `HALTED`), de `prog_valid` y de `cycles`, también en `LOAD` y `RESET`. Un `LOAD`
  la afecta dos veces: con `i_load_start`, al aceptar el encabezado, pasa a `NO_PROG` con
  `prog_valid = 0` (así un `LOAD` que falla ya queda así), y con el `o_cmd_valid` del `LOAD`
  pasa a `READY` con `prog_valid = 1` y `cycles = 0`. Calcula
  `core_rst = i_rst | NO_PROG | i_mem_busy`, más un ciclo después del `o_cmd_valid` de `LOAD` y
  de `RESET`. La 037 deja a la I-46 manejar `i_load_start` e `i_mem_busy`, y describe
  `i_mem_busy` como activa "de `LOAD_PREP` a `CLEAR`".

Falta decidir cómo saca `debug_unit` esas dos señales y las fronteras con otra issue:
- **El mapa de palabras usadas** (`memoria.md` §7) lo marca el core, lo borra `CLEAR` y lo
  recorren las lecturas. Los casos de marcado (un `sb` marca la palabra, un store fuera de
  rango marca su alias, un load no marca) están en el testbench de la I-48
  (`verificacion.md` §3.3).
- **El puerto B de `dmem`** lo usan `CLEAR` (I-46) para escribir ceros y las lecturas (I-48)
  para leer.

## Opciones consideradas

**Cómo se avisa el comienzo del `LOAD` (`i_load_start`)**
1. **`o_cmd_valid` también al aceptar el encabezado.**
   - Desventajas: `o_cmd_valid` dejaría de significar "trama terminada sin errores" (036), y
     un `LOAD` todavía puede fallar después.
2. **Un pulso propio, `o_load_start`, en `LOAD_PREP`.**
   - Ventajas: el significado de `o_cmd_valid` no cambia, y es el pulso que pide la 037.

**Qué ciclos cubre `i_mem_busy`**
1. **De `LOAD_PREP` a `CLEAR`**, como lo describe la 037.
   - Desventajas: es una señal más ancha sin efecto: de `LOAD_PREP` a `EXEC` el estado ya es
     `NO_PROG` (lo puso `i_load_start`), y eso mantiene `core_rst`. En un `RESET` no hay
     `LOAD_PREP` ni payload, así que hay que distinguir los dos casos.
2. **Solo `CLEAR`: `o_clearing = (estado == CLEAR)`**.
   - Ventajas: es lo único que `NO_PROG` no cubre: el `CLEAR` de un `RESET` desde `READY`,
     `PAUSED`, `HALTED` o `RUNNING`, y el de un `LOAD` que ya pasó a `READY` en `EXEC`. Sale de
     una comparación con el estado.
   - Desventajas: no coincide con el texto de la 037, aunque el `core_rst` que resulta es el
     mismo en todos los ciclos.

**El mapa de palabras usadas**
1. **Lo crea la I-46** (marcado, borrado y contador).
   - Desventajas: el marcado no es parte de la carga, necesita del core señales que hoy no
     saca, y sus casos de prueba son de la I-48.
2. **La I-46 solo pide borrarlo**: en `CLEAR`, `o_used_clr` con la dirección de
   `o_dmem_b_addr`. El mapa (marcado, `dmem_used`, recorrido) lo hace la I-48.
   - Ventajas: cada issue prueba lo suyo. La I-48 recibe un borrado ya probado, palabra por
     palabra.

## Decisión
- **Estados nuevos en `debug_unit`**, en el orden del diagrama:
  - `LOAD_PREP`, un ciclo después de un encabezado de `LOAD` válido: pulsa `o_load_start` y
    pone el puntero de `imem` en 0.
  - En `RX_PAYLOAD` de un `LOAD`, la palabra se escribe en `imem` con el 4.º byte, como en
    `memoria.md` §4.2. El registro de 32 bits de la 014 es `arg_reg`, que ya guarda el payload,
    y el contador de bytes son los dos bits bajos de `cnt_reg`. Hacen lo mismo con 34
    flip-flops menos.
  - `EXEC` y después `CLEAR` (solo `LOAD` y `RESET`), antes de responder. `CLEAR` recorre
    `0 … max(IMEM_WORDS, DMEM_WORDS) − 1`: HALT en `imem[N …]` (solo `LOAD`), cero en `dmem` y
    `o_used_clr`. Mientras dura, `o_clearing = 1`.
- **`o_load_start`** (opción 2) va a `i_load_start` de `debug_exec`, y **`o_clearing`** (opción 2,
  solo `CLEAR`) va a `i_mem_busy`. Lo que hace `debug_exec` con cada evento (037):

  | Evento | `debug_exec` |
  |---|---|
  | `o_load_start` | `prog_valid ← 0` y estado `NO_PROG`: en el ciclo siguiente `core_rst = 1` y `enable = 0` |
  | `o_cmd_valid` con `LOAD` | `prog_valid ← 1`, estado `READY`, `cycles ← 0` y un ciclo de `core_rst` |
  | `o_cmd_valid` con `RESET` | estado `READY` si `prog_valid`, si no `NO_PROG`; `cycles ← 0` y un ciclo de `core_rst` |
  | `o_clearing` | `core_rst = 1` mientras dura |

  Así el core está en reset desde el ciclo siguiente a `LOAD_PREP` hasta el último de `CLEAR`:
  por `NO_PROG` hasta `EXEC`, por el pulso de `LOAD`/`RESET` en el primer ciclo de `CLEAR` y por
  `o_clearing` en todo `CLEAR`.

  Un `LOAD` que falla por checksum o por timeout después de `LOAD_PREP` no llega a `EXEC`: no
  hay `o_cmd_valid` ni `CLEAR`, y la FSM queda en `NO_PROG` con el core en reset
  (`memoria.md` §4.3). Un `ERR_LENGTH` no llega a `LOAD_PREP`: no cambia nada.
- **Mapa de usadas** (opción 2): `debug_unit` pulsa `o_used_clr` en cada dirección de `CLEAR`,
  junto con la escritura de `dmem`.
- **Puerto B de `dmem`**: `debug_unit` lo usa solo en `CLEAR` (`o_dmem_b_en = 1`, `we = 1111`,
  dato 0). Las lecturas de la I-48 lo comparten con un multiplexor que elige `debug_unit`
  cuando `o_dmem_b_en = 1`. Nunca coinciden, porque las lecturas se hacen en `TX_PAYLOAD`. El
  puerto B de `imem` es solo de `debug_unit`.

## Consecuencias
- `protocolo_debug.md` §7 suma los puertos nuevos de `debug_unit`. `memoria.md` §4.2 dice quién
  hace cada cosa de la secuencia. `verificacion.md` §3.3 detalla los casos de
  `debug_load_tb.v`, y §8.7 pasa a 24 testbenches unitarios.
- **037**: `i_mem_busy` se describe "de `LOAD_PREP` a `CLEAR`"; con la I-46 vale 1 solo en
  `CLEAR`, y `protocolo_debug.md` §7 lo dice. La 037 ya descarta un `evt_pending` con
  `i_load_start` y con `RESET`: si el core llega al HALT mientras se recibe un `LOAD`, no sale un
  evento de un programa que ya no está.
- **I-48**: el mapa de usadas recibe `o_used_clr` con `o_dmem_b_addr` y pone `dmem_used` en 0
  con el borrado. Su testbench prueba que después de un `LOAD` el mapa queda vacío y
  `dmem_used = 0`. El de la I-46 prueba que `CLEAR` borra las 1024 palabras.
- **I-49**: conecta `o_load_start` y `o_clearing` a `debug_exec`, el puerto B de `imem` directo
  y el de `dmem` con el multiplexor de arriba.
- El testbench `debug_load_tb.v` usa el core real con las BRAM, así que corre solo en xsim, y
  un modelo de la FSM de ejecución con la tabla de arriba.
- Las preguntas de la consigna sobre qué se vacía al cargar siguen respondidas en la 004 y en
  `protocolo_debug.md` §3.3. La I-46 las implementa: el pipeline y los registros con
  `core_rst`, y `dmem`, el mapa de usadas y el resto de `imem` en `CLEAR`.
