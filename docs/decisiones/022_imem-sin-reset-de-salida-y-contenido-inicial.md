# 022 - Memoria de programa: sin reset del registro de salida y contenido inicial sin archivo

- **Estado:** propuesta
- **Fecha:** 2026-10-08
- **Autores:** Moreyra, Julián

## Contexto
La I-20 genera el IP `imem_bram` (`ip/imem_bram.tcl`) y su envolvente `rtl/memory/imem.v`.
Al configurar el IP quedan dos cosas sin cerrar:

1. **Punto abierto de la decisión [009](009_memorias-sincronicas.md):** el Block Memory
   Generator tiene un pin `RSTA` que pone el registro de salida en un valor configurable. Con
   ese valor en NOP (`0x0000_0013`), el flush de IF/ID podría forzar la salida a NOP en lugar
   de anularla con `if_id_valid`. La 009 lo deja "a decidir al generar el IP (I-20)" y
   `memoria.md` §3.2 lo marca como opcional.
2. **Cómo se inicializa la memoria en simulación.** La issue pide "inicialización desde un
   archivo `.mem` para simulación", y la consecuencia para I-22 de la decisión
   [014](014_bram-y-escritura-de-programa.md) y `memoria.md` §3.6 hablan de un `.coe` generado
   por el ensamblador. Después, la decisión [021](021_banco-incremental.md) fijó que los
   testbenches cargan el programa **por el puerto B**, porque el archivo del IP queda fijo al
   generarlo y la ruta del arreglo interno del modelo depende de la versión del IP
   (`blk_mem_gen_v8_4_13`; comentario de Matías en la I-20 y en la I-32).

Restricciones:
- El flush de IF/ID viene de `redirect`, que se resuelve en EX y ya es parte del camino
  crítico candidato de la decisión [012](012_resolucion-saltos.md).
- `if_id_valid` hace falta igual: lo usan la unidad de control (`pipeline.md` §4.4), el volcado
  de latches y la detección de pipeline vacío (009).
- La memoria tiene que arrancar llena de HALT al configurar la FPGA (`memoria.md` §3.6,
  decisión [001](001_instruccion-halt.md)).

## Opciones consideradas

**Reset del registro de salida**
1. **`RSTA` con valor NOP**, conectado a `rst | flush_if_id`.
   - Ventajas: después de un flush o de un reset, `if_id_instr` vale NOP y no basura; las
     formas de onda se leen más fácil.
   - Desventajas: `redirect` llega al pin de reset de la BRAM, que tiene su propio *setup*, y
     se suma al camino crítico de la 012. Hay que fijar la prioridad entre `RSTA` y `ena`
     (opción *Reset Priority* del IP) para que un stall no pise el reset. No ahorra nada:
     `if_id_valid` sigue siendo necesario para el volcado y para el pipeline vacío.
2. **Sin `RSTA`; la salida se anula con `if_id_valid = 0`** (lo que ya describen
   `pipeline.md` §3.3 y la 009).
   - Ventajas: un solo mecanismo para flush y reset; `redirect` solo llega a flip-flops
     comunes; el IP queda más simple.
   - Desventajas: después de un flush o un reset `if_id_instr` tiene basura (la instrucción
     anulada o la salida sin inicializar de la BRAM); quien lea la traza tiene que mirar
     `if_id_valid`.

**Contenido inicial e inicialización en simulación**
1. **Archivo de inicialización del IP (`.coe`) con el programa.** El contenido queda fijo al
   generar el IP: hay que regenerarlo para cada programa (021, opción 1).
2. **`$readmemh` por jerarquía sobre el arreglo del modelo de simulación del IP.** La ruta no
   está documentada y cambia con la versión del IP (021, opción 2).
3. **IP sin archivo, con *Fill remaining* = HALT; el programa se escribe por el puerto B.**
   El testbench lee el `.hex` del ensamblador con `$readmemh` en un arreglo propio y lo escribe
   por el puerto B con el core en reset, como `LOAD` (021, opción 3).

## Decisión
- **Sin pines `RSTA`/`RSTB`** en `imem_bram`: el flush y el reset de IF/ID se resuelven solo con
  `if_id_valid`, como fija `pipeline.md` §3.3. Cierra el punto abierto de la 009.
- **IP sin archivo de inicialización** (`Load_Init_File = false`) y con **Fill remaining =
  `00100073`**: las 1024 palabras arrancan en HALT, en la FPGA y en la simulación.
- **El programa se carga por el puerto B** en todos los testbenches (021). El "archivo para
  simulación" que pide la issue es el `.hex` del ensamblador, que lee el testbench, no la
  memoria.

Motivo: el reset de la salida no evita ningún mecanismo (el `valid` hace falta igual) y mete
`redirect` en un pin más de la BRAM. Un archivo dentro del IP obliga a regenerarlo por programa
y no prueba el puerto que usa la Debug Unit.

## Consecuencias
- `ip/imem_bram.tcl` deja explícitos `Use_RSTA_Pin`, `Use_RSTB_Pin` y `Load_Init_File` en
  `false`, y el relleno con HALT.
- `rtl/memory/imem.v` no tiene `i_rst`: la BRAM no se resetea.
- `memoria.md` §3.2 (fila de `RSTA`/`RSTB`) y §3.6 (carga en los testbenches) remiten a esta
  decisión. La consecuencia para I-22 de la 014 (cargar con un `.coe`) queda reemplazada por la
  021 y por esta nota.
- `imem_tb.v` comprueba el contenido inicial HALT y la carga por el puerto B sin acceder al
  arreglo interno del IP.
- **I-22 (integración IF):** después de un reset o de un flush, `if_id_instr` no es NOP; ID
  tiene que mirar `if_id_valid` (`pipeline.md` §4.4).
