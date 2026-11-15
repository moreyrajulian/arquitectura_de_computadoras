# 039 - Volcado de estado de la Debug Unit: latches, mapa de usadas y fuente del payload

- **Estado:** propuesta
- **Fecha:** 2026-11-15
- **Autores:** Costamagna, Matías

## Contexto
La I-48 manda a la PC lo que pide la consigna: los 32 registros, los latches intermedios y la
memoria de datos usada (`READ_REGS`, `READ_LATCHES`, `READ_DMEM`, `READ_DMEM_USED` y
`READ_ALL`, [`protocolo_debug.md`](../spec/protocolo_debug.md) §3.6). Hay varias cosas ya
fijadas:
- **Qué es la memoria usada** (decisión [005](005_memoria-de-datos-usada.md)): un bit por
  palabra que se marca con cada store y un contador `dmem_used`, en la Debug Unit, en RAM
  distribuida de 1024 × 1 ([`memoria.md`](../spec/memoria.md) §7). El core le pasa
  `dmem_we = enable & ex_mem_mem_write` y `dmem_addr = ex_mem_result[11:2]` (decisión
  [027](027_logica-de-mem-en-dmem.md)).
- **Los latches** llegan como un bus por registro de segmentación con todo su contenido, en el
  orden de [`pipeline.md`](../spec/pipeline.md) §8 (decisión
  [023](023_interfaz-debug-del-core.md)). La Debug Unit los parte en palabras.
- **La interfaz con la FSM de protocolo** (decisión [036](036_fsm-de-protocolo-de-la-debug-unit.md)):
  `debug_unit` arma el encabezado, el bloque de estado y el LEN, y pide cada byte de las lecturas
  con `o_pl_idx`. El byte `i_pl_byte` puede llegar hasta 2 ciclos después del índice.
- **El borrado del mapa y el puerto B de `dmem`** (decisión
  [038](038_carga-de-programa-en-la-debug-unit.md)): `CLEAR` pulsa `o_used_clr` con
  `o_dmem_b_addr`, y las lecturas comparten el puerto B con un multiplexor que elige
  `debug_unit` cuando `o_dmem_b_en = 1`.

Falta decidir:
- **El reparto en palabras de `READ_LATCHES`**, el punto abierto de `protocolo_debug.md` §3.6.
- **Cómo se encuentra a tiempo la k-ésima palabra usada.** La RAM distribuida de 1024 × 1 se
  lee de a un bit, así que encontrar la próxima palabra marcada lleva hasta 1024 ciclos. El
  primer par hay que tenerlo listo después de los 5 bytes del encabezado: con `DVSR = 2` (los
  testbenches, 320 ciclos por byte) son ~1600 ciclos y alcanza, pero con `DVSR = 1` (~800) no.
  Para el par siguiente hay 8 bytes de tiempo solo si se busca mientras se envía el anterior, y
  eso obliga a guardar el valor del par en curso, porque el puerto B ya apunta al siguiente. Si
  se busca cuando el envío llega al par, queda un byte de tiempo. El límite de 2 ciclos de la
  036 se cumpliría solo por el baudrate, y no en todos los casos.
- **En qué módulos va todo** y dónde está el multiplexor del puerto B.
- **Qué hace el reset del sistema con el mapa y el contador.**

## Opciones consideradas

**Reparto de los latches en palabras**
1. **La tabla provisoria de §3.6** (2, 6, 4 y 3 palabras, con campos elegidos).
   - Desventajas: la Debug Unit tendría que conocer los campos, y el resultado no coincide con
     el empaquetado de la traza del modelo ni con los buses de la 023.
2. **Cada bus partido en palabras de 32 bits, la menos significativa primero**, con la última
   rellena con ceros: 3, 6, 4 y 4 palabras (68 bytes).
   - Ventajas: es lo que propone la decisión [020](020_modelo-de-referencia.md). `debug_unit`
     ya informa esas palabras en `INFO` y el cliente de la PC ya las parsea así (`Latches`).
     La Debug Unit no conoce ningún campo: si cambia `pipeline.md` §8, cambia el bus y nada más.

**Cómo se espera la palabra usada**
1. **Handshake `i_pl_ready`**: `debug_unit` no escribe un byte de la fuente externa mientras
   `i_pl_ready = 0`.
   - Ventajas: no depende del baudrate. El mapa queda como dice `memoria.md` §7, y sirve si
     alguna vez hace falta paginar.
   - Desventajas: cambia el contrato de la 036 y suma una entrada a `debug_unit`. Los
     testbenches que la instancian sin la I-48 la atan a 1.
2. **Confiar en el baudrate**: buscar el primer par desde `o_cmd_valid`, buscar cada par
   siguiente mientras se envía el anterior (con un registro para el valor en curso) y
   documentar que hace falta `DVSR ≥ 2`.
   - Ventajas: no toca `debug_unit`.
   - Desventajas: la restricción es implícita y nada la comprueba. Aparece cuando alguien cambia
     el reloj o el baudrate. La búsqueda adelantada es más lógica que el handshake.
3. **RAM distribuida de 32 × 32** con un codificador de prioridad: ~33 ciclos en el peor caso.
   - Ventajas: no depende del baudrate y no toca `debug_unit`.
   - Desventajas: marcar y borrar pasan a ser lectura-modificación-escritura, y cambia
     `memoria.md` §7.

**Módulos**
1. **Un solo módulo** con el mapa y la fuente de bytes.
2. **`debug_used_map`** (mapa, contador y búsqueda) **instanciado dentro de `debug_dump`**
   (fuente de bytes y multiplexor del puerto B).
   - Ventajas: el mapa es una unidad con su propio contrato (marcar, borrar, contar y buscar).
     El top de la I-49 instancia uno solo, y el multiplexor queda probado en el testbench de la
     I-48 en lugar de escribirse por primera vez en el top.

## Decisión
- **`READ_LATCHES`** (opción 2): IF/ID, ID/EX, EX/MEM y MEM/WB en ese orden, cada bus en
  `ceil(NB / 32)` palabras de 32 bits, la palabra 0 con los bits `[31:0]`, cada una
  little-endian. Los bits de relleno valen 0. Con los anchos de hoy son 3 + 6 + 4 + 4 = 17
  palabras, `LEN = 68`. Los parámetros `NB_*_LATCH` fijan el reparto en `debug_unit` (`INFO`,
  `LEN`) y en `debug_dump` (los bytes).
- **Handshake** (opción 1). `debug_unit` tiene `i_pl_ready`, y en `TX_PAYLOAD` de una lectura
  solo escribe con `i_tx_full = 0` e `i_pl_ready = 1`. Los bytes que arma `debug_unit` (`INFO`,
  el bloque de estado y los 12 primeros de `READ_ALL`) no lo esperan. El límite de 2 ciclos
  sigue valiendo para registros, latches y `READ_DMEM`.
- **Dos módulos** (opción 2):
  - `rtl/debug/debug_used_map.v`: la RAM distribuida de 1024 × 1 con lectura asíncrona y una
    sola dirección, elegida por un multiplexor (marcar, borrar o buscar; nunca coinciden, porque
    el core marca con `enable = 1` y las otras dos se hacen con el core detenido). El contador
    `dmem_used` de 11 bits sube cuando se marca una palabra que valía 0. La búsqueda empieza
    desde 0 o desde la palabra siguiente a la última encontrada, y avanza un bit por ciclo.
  - `rtl/debug/debug_dump.v`: instancia el mapa y arma cada byte a partir de `o_pl_idx` y
    `o_cmd`, restando 12 en `READ_ALL`. Los registros salen del puerto de debug del banco y los
    latches de los buses; `READ_DMEM` y los valores de los pares, del puerto B de `dmem`. Pide la
    primera palabra usada con el `o_cmd_valid` de `READ_DMEM_USED` o `READ_ALL`, y la siguiente
    cuando el índice pasa al par siguiente. El byte sale de un registro, con el índice para el
    que se calculó, e `i_pl_ready` dice que ese índice es el actual.
  - **El multiplexor del puerto B de `dmem` está en `debug_dump`**: elige `debug_unit` con
    `o_dmem_b_en = 1` (`CLEAR`), y si no, las lecturas. `debug_dump` solo lee entre el
    `o_cmd_valid` de una lectura y el del comando siguiente, con el core detenido
    (`memoria.md` §3.5).
- **Reset**: `i_rst` pone `dmem_used` en 0, y cada `o_used_clr` también. El mapa no se resetea,
  porque es memoria (decisión [010](010_convenciones-rtl.md)). Queda consistente: después de un
  `i_rst` el estado es `NO_PROG`, y el core solo vuelve a escribir después de un `LOAD` o un
  `RESET`, que lo borran entero en `CLEAR`. Hasta entonces `dmem_used = 0`, así que ninguna
  respuesta pide un par.

## Consecuencias
- `riscv_core` suma `o_dmem_we` y `o_dmem_addr[9:0]` (027). El banco incremental y
  `pipeline_tb` no los usan.
- `protocolo_debug.md`:
  - §3.6: la tabla definitiva y el punto abierto del encabezado cerrado.
  - §1: 68 bytes de latches.
  - §7: `i_pl_ready` en `debug_unit` y los puertos de `debug_dump`.
  - §8: el ítem del checklist tildado.
- `memoria.md` §7 dice cómo se busca la palabra siguiente y qué hace el reset.
  `verificacion.md` §3.3 detalla `debug_dump_tb.v`, y §8.7 pasa a 25 testbenches unitarios.
- **El cliente de la PC no cambia**: ya parte los latches con las palabras de `INFO`, la menos
  significativa primero, y el handshake no se ve desde la línea serie.
- **036**: el contrato de `o_pl_idx` / `i_pl_byte` se amplía con `i_pl_ready`; no se reemplaza.
  `debug_cmd_fsm_tb`, `debug_load_tb` y `debug_run_tb` atan `i_pl_ready = 1`.
- **Peor caso de una lectura**: la búsqueda de cada par empieza cuando el envío llega a ese
  par, así que cada par puede frenar el envío hasta ~1024 ciclos (~10 µs a 100 MHz). Un par son
  8 bytes serie (~700 µs a 115200), así que en el peor caso el volcado tarda menos de un 1,5 %
  más. Con `DVSR = 2` el encabezado tapa la búsqueda del primer par, pero la de los siguientes
  se nota: en `debug_dump_tb`, el tercer par de `usadas_orden` (la palabra 1023) espera unos
  700 ciclos con `i_pl_ready = 0`.
- **Si el mapa y el contador no coincidieran** (no pasa con el RTL; haría falta un bit
  alterado), la búsqueda llega al final sin encontrar la palabra. `debug_dump` entrega ceros en
  ese par en lugar de dejar a `debug_unit` esperando para siempre.
- **I-49**: el top instancia `uart`, `debug_unit`, `debug_exec`, `debug_dump` y el core.
  `debug_dump` maneja el puerto B de `dmem` del core, y `debug_unit` el de `imem`.
- **El criterio de la issue "los registros que todavía no existen se envían en cero"** se
  cumple con los parámetros `NB_*_LATCH`: el core ya tiene los cuatro registros, y un bus más
  angosto se rellena con ceros hasta su última palabra.
