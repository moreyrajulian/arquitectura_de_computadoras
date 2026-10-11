# 023 - Interfaz de debug del core y estructura de la etapa IF

- **Estado:** propuesta
- **Fecha:** 2026-10-11
- **Autores:** Costamagna, Matías

## Contexto
La I-22 integra la etapa IF en `riscv_core` y pide dejar definida la interfaz de debug del
core: `cpu_en`, `halted`, el puerto de escritura de la memoria de programa y el bus de latches.
La Debug Unit (I-46 a I-48) se escribe después contra esa interfaz.

Hay dos cosas ya fijadas:
- **El banco incremental** (decisión [021](021_banco-incremental.md),
  [`verificacion.md`](../spec/verificacion.md) §8.5) define los puertos `i_clk`, `i_rst`,
  `i_enable`, `i_imem_b_*` y `o_halted`, y lee los campos de los latches por jerarquía. La
  señal que la issue llama `cpu_en` es `enable` (decisión [018](018_paso-a-paso-sin-clock.md)).
- **La puerta del bus de latches.** `if_id_reg` ya entrega `o_latch = {valid, pc, instr}`, en
  el orden de [`pipeline.md`](../spec/pipeline.md) §8 (I-21).

Falta decidir cómo llega el contenido de los latches a la Debug Unit.
[`protocolo_debug.md`](../spec/protocolo_debug.md) §7 propone un par
`dbg_latch_sel` / `dbg_latch_data[31:0]`: la Debug Unit elige una palabra y el core la
devuelve. Pero el reparto en palabras de `READ_LATCHES` todavía es provisorio (§3.6, punto
abierto de su checklist).

Restricciones:
- El core no debería depender del formato de una trama del protocolo.
- Los registros de segmentación suman 445 bits (`pipeline.md` §8). Hay 381 en flip-flops y 64
  en las salidas de las BRAM.
- La lectura se hace con el core detenido (`enable = 0`), así que los latches no cambian
  mientras la Debug Unit los recorre (decisión 018).

## Opciones consideradas

**Cómo exponer los latches**
1. **`dbg_latch_sel` / `dbg_latch_data[31:0]` en el core** (lo que propone
   `protocolo_debug.md` §7). El core arma las palabras y tiene el multiplexor.
   - Ventajas: el bus entre el core y la Debug Unit es angosto (unos 37 bits).
   - Desventajas: el core tiene que conocer el reparto en palabras de `READ_LATCHES`, que es un
     detalle del protocolo y todavía no está cerrado. Cada etapa nueva modifica el multiplexor
     del core. El banco de pruebas no lo puede usar sin una Debug Unit (021).
2. **Un bus por latch con todo su contenido** (`o_if_id_latch[64:0]`, `o_id_ex_latch[160:0]`,
   ...), en el orden de `pipeline.md` §8. La Debug Unit lo parte en palabras.
   - Ventajas: el core solo publica lo que ya tiene, con el mismo empaquetado que la traza del
     modelo (`tools/isasim/isasim/latches.py`). El reparto en palabras queda en un solo lugar,
     junto al protocolo. Cada integración agrega un puerto sin tocar los anteriores.
   - Desventajas: 445 cables entre el core y la Debug Unit. El multiplexor existe igual en la
     opción 1, solo cambia de módulo, así que no cuesta lógica de más. El ruteo no es un problema
     en una FPGA y no está en el camino crítico, porque se lee con el core detenido.

**Dónde está la memoria de programa**
1. **`if_stage` con `pc_logic`, `imem` e `if_id_reg` adentro.** La salida de `imem` es
   `if_id_instr` y su `ena` es `en_if_id` (decisión [009](009_memorias-sincronicas.md)), así que
   la BRAM y el registro IF/ID funcionan como una sola cosa.
2. **`imem` en `riscv_core`, al lado de `if_stage`.** La etapa quedaría separada de la memoria,
   pero el cable `pc_reg` → BRAM → `if_id_instr` saldría y volvería a entrar a la etapa.

## Decisión
- **Interfaz de debug de `riscv_core` en M3:** `i_enable`, `i_rst` (`core_rst`), `i_imem_b_en`,
  `i_imem_b_we`, `i_imem_b_addr[9:0]`, `i_imem_b_din[31:0]`, `o_halted`, `o_pc[31:0]` (para el
  bloque de estado) y `o_if_id_latch[64:0]`.
- **Un bus por latch** con todo su contenido en el orden de `pipeline.md` §8 (opción 2). La
  Debug Unit (I-48) elige las palabras de `READ_LATCHES`. Reemplaza el par `dbg_latch_sel` /
  `dbg_latch_data` de `protocolo_debug.md` §7.
- **Cada integración agrega su parte:** `o_id_ex_latch[160:0]` y el puerto de lectura del banco
  de registros (I-27), `o_ex_mem_latch[108:0]` (I-31), `o_mem_wb_latch[109:0]` y el puerto B de
  `dmem` (I-34), y los avisos `o_imem_fault`, `o_dmem_oob` y `o_dmem_misaligned` (I-35).
  `o_halted` existe desde M3 y vale 0 hasta que I-35 agrega el registro `halted`.
- **`if_stage` incluye `pc_logic`, `imem` e `if_id_reg`** (opción 1). Recibe `en_pc`,
  `en_if_id` y `flush_if_id` ya calculados, porque los genera la unidad de riesgos
  (`pipeline.md` §10.4). Hasta I-42 los calcula `riscv_core`, con `stall`, `redirect`,
  `stop_fetch` y `halted` en 0.

## Consecuencias
- `protocolo_debug.md` §7 lista los buses de latch en lugar de `dbg_latch_sel` /
  `dbg_latch_data`. El reparto en palabras de `READ_LATCHES` (§3.6) se cierra en I-48, en la
  Debug Unit, sin tocar el core.
- `verificacion.md` §8.5 agrega `o_pc` y `o_<latch>_latch` a la interfaz. El banco incremental no
  los usa (lee los campos por jerarquía), y el stub no los tiene.
- **Si cambia un campo de `pipeline.md` §8 o su orden**, también cambia el bus del latch. Es la
  misma concatenación que ya usan `latches.py` y `pipeline_tb.v`.
- **I-48** puede comparar cada bus con los campos por jerarquía en su testbench, y así comprobar
  "bit a bit" (`verificacion.md` §3.3) sin un formato intermedio.
- **En M3 el core no tiene flush:** `flush_if_id = redirect | stop_fetch = 0`. `if_stage_tb.v`
  maneja el flush, `redirect` y `stop_fetch` directamente.
