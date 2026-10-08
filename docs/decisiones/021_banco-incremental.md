# 021 - Banco de pruebas incremental: carga, comparación y cortes por etapa

- **Estado:** propuesta
- **Fecha:** 2026-10-07
- **Autores:** Costamagna, Matías

## Contexto
La I-17 pide un único testbench que valide cada etapa al integrarla y quede como regresión
de las siguientes: carga el programa y el estado inicial, compara ciclo a ciclo cada registro
de segmentación contra la traza del modelo de referencia y, desde M7, el estado final contra
el `.exp` ([`verificacion.md`](../spec/verificacion.md) §1, §5 y §6).

Restricciones:
- **El formato de la traza ya está fijado** por la decisión [020](020_modelo-de-referencia.md):
  un `$readmemh` por latch con una línea por ciclo y una máscara. El banco solo calcula
  `(dut ^ ref) & mask`. (La issue dice que el formato está en `pipeline.md`; no está ahí.)
- **Verilog, no SystemVerilog** (decisión [010](010_convenciones-rtl.md)): no hay `string`
  ni clases, y un testbench no puede leer el `.exp` ni ejecutar el modelo por su cuenta.
- **El banco se escribe antes que el core.** `riscv_core` lo crea I-22, que depende de esta
  issue; el banco fija la interfaz que el core tiene que tener.
- **xsim corre en `build/vivado_<diseño>/…/xsim`**, así que una ruta relativa al repositorio
  no sirve para leer archivos.
- **El modelo simula siempre el pipeline completo** (decisión 020), pero el RTL de M3 a M7
  no tiene todavía la parada por HALT (I-37) ni la realimentación del salto a IF (I-36: I-19
  deja esa entrada en 0 hasta M7).

## Opciones consideradas

**Cómo elegir el programa**
1. **Parámetro o `define` con la ruta.** Hay que recompilar para cambiar de programa, y la
   ruta queda escrita en el código.
2. **Plusarg `+DIR=<directorio>`** con nombres de archivo fijos dentro del directorio. Se
   cambia de programa sin recompilar; en Vivado va en *more_options* de la simulación.

**Cómo cargar `imem` y `dmem`**
1. **Archivo `.coe` del IP** (decisión [014](014_bram-y-escritura-de-programa.md)). Hay que
   regenerar el IP para cada programa.
2. **`$readmemh` por jerarquía sobre el modelo de simulación de la BRAM.** El nombre del
   arreglo interno del Block Memory Generator no está documentado y puede cambiar.
3. **Escribir por el puerto B con el core en reset**, como `LOAD` (`memoria.md` §4). Usa un
   puerto que el core ya expone para la Debug Unit, funciona igual con cualquier
   implementación de la memoria y prueba ese puerto. Cuesta 1024 ciclos por memoria, que no
   cuentan para el watchdog.

**Cómo leer los latches del core**
1. **El bus de `READ_LATCHES`.** Su empaquetado todavía es provisorio
   (`protocolo_debug.md` §3.6) y lo arma la Debug Unit (I-48), que llega después.
2. **Referencias jerárquicas con los nombres de `pipeline.md` §8**
   (`u_dut.id_ex_alu_ctrl`), como ya fija `verificacion.md` §7. Exige que los campos sean
   señales del módulo superior del core.

**Cómo comparar con el `.exp`**
1. **Comparar con el estado final del modelo.** Rompe la regla de `verificacion.md` §2: el
   `.exp` es el oráculo escrito a mano.
2. **Convertir el `.exp` a `$readmemh` con un script** que solo traduce el formato (usa
   `parse_exp` de `isasim`), sin ejecutar nada.

**Qué hacer con lo que el RTL todavía no tiene**
1. **Cortar la comparación** de cada latch en el punto donde el RTL se aparta del modelo por
   una razón conocida: el HALT que llega al latch (sin I-37) y el primer salto tomado (sin
   I-36). Con los saltos, `indep_saltos` empieza con un `beq` tomado y de M3 a M6 queda
   cubierto solo hasta el ciclo 4-7 según el latch.
2. **Un modo `--sin-redirect` en `isasim`.** La capa de la ISA tendría que seguir al pipeline
   en lugar de a `isa.md`, lo que debilita el oráculo y toca la herramienta de I-16.
3. **Adelantar la realimentación del salto a I-31 (M5).** Se probaría antes el cableado del
   salto, pero se pierde que de M3 a M6 el pipeline sea una cadena solo hacia adelante, sin
   ningún camino de vuelta: es lo que hace que cada falla quede acotada a la etapa nueva.
   Además habría que reescribir I-19, I-29, I-31 e I-36.

**Cómo probar el banco antes del core**
1. **No probarlo hasta I-22.** I-22 depuraría a la vez el core y el banco.
2. **Un `riscv_core` falso** (`_riscv_core_stub.v`) que reproduce la traza del modelo. El
   prefijo `_` lo deja fuera del proyecto de Vivado, así que no choca con el core real.

## Decisión
- **`scripts/prep_tb.py`** prepara cada programa en `build/tb/<nombre>/` con nombres fijos:
  `imem.hex`, estado inicial, la traza del modelo (escrita con `write_outputs` de `isasim`),
  `corte.hex` y el `.exp` escrito a mano convertido a `$readmemh`. Va en `scripts/` y no en
  `tools/isasim` para no cambiar la herramienta de I-16; la usa como biblioteca.
- **`+DIR=<ruta absoluta>`** elige el programa; `+FINAL` agrega el estado final.
- **Carga por el puerto B** de `imem` y `dmem`, con el core en reset. El banco de registros,
  que no tiene puerto de escritura de debug, se carga por jerarquía (`` `REGFILE ``) justo
  después de soltar el reset, porque el reset lo pone en cero (decisión 007).
- **Latches por jerarquía**, con el prefijo del latch también en las señales de control.
- **Defines acumulativos por etapa**: `STAGE_IF`, `STAGE_ID`, `STAGE_EX`, `STAGE_MEM` y
  `STAGE_WB`, más `STAGE_REDIRECT` (I-36) y `STAGE_HALT` (I-37) para las dos partes del
  control que se integran en M7.
- **Cortes:** sin `STAGE_HALT`, cada latch se compara hasta que el HALT llega a él; sin
  `STAGE_REDIRECT`, el latch `k` hasta el ciclo `r + 1 + k` del primer salto tomado. El banco
  lo avisa con `INFO:`. Los saltos se integran en M7, como estaba planificado.
- **Ante el primer ciclo con diferencias**, informa cada campo distinto y termina.
- **Stub** para probar el banco hoy, con fallas a propósito (`STUB_ERROR`, `STUB_SIN_HALT`).

El detalle de uso está en [`verificacion.md`](../spec/verificacion.md) §8.

## Consecuencias
- **I-22 (integración IF)** implementa la interfaz de `verificacion.md` §8.5: puertos B de las
  memorias como entradas del core (la Debug Unit ata `dinb` de `dmem` a 0, no el core:
  `memoria.md` §3.3) y los campos de los latches como señales del módulo superior.
- **Cada integración** (I-22, I-27, I-31, I-34, I-35, I-36, I-37) descomenta su define en
  `pipeline_tb.v` y corre los programas que la etapa puede ejecutar. I-27 ajusta
  `` `REGFILE `` al camino real del banco de registros.
- **De M3 a M6, `indep_saltos` se compara solo hasta su primer salto tomado.** La lógica del
  salto la cubren los testbenches unitarios (I-24, I-25, I-29); el cableado entre módulos se
  prueba recién en I-36, junto con WB y la parada por HALT.
- **Si cambia un campo de `pipeline.md` §8 o su orden**, cambian `latches.py` y la
  concatenación de `pipeline_tb.v` (y las tablas de campos que usa para informar errores).
- **I-38 e I-43** usan el mismo banco con `+FINAL`; `verificacion.md` §7 ya no nombra
  `stage_<etapa>_tb.v` ni `core_tb.v`. Si hace falta una regresión que corra todos los
  programas, es un script que llama a `prep_tb.py` y a xsim por cada uno (no existe todavía).
- **Requisito de xsim:** una ruta con `=` en un `.bat` de Windows se parte en dos; el
  plusarg va entre comillas (`-testplusarg "DIR=..."`).
