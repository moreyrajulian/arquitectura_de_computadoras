# 029 - Modo del modelo de referencia durante las integraciones de M8

- **Estado:** propuesta
- **Fecha:** 2026-11-03
- **Autores:** Moreyra, Julián

## Contexto
El plan de verificación tenía dos modos del modelo: `sin_riesgos` para M3 a M7 y `completo`
para M8, con la regresión completa en I-43 (`verificacion.md` §4.3). Pero M8 integra los
tres mecanismos de a uno: forwarding (I-39), stall de carga-uso (I-41) y flush por saltos
(I-42). Entre esas PRs, `master` tiene que seguir simulando.

Al conectar la unidad de forwarding (I-39), `pipeline_tb` con las trazas de `sin_riesgos`
falla en 10 de los 27 programas de M7 (`alu_r`, `shifts`, `mem_palabra`, `halt_basico`,
`fwd_x0`, `bypass_banco` y cuatro variantes `_nops`). No es un error del RTL: el estado final
es el mismo. La unidad compara `rs1` y `rs2` aunque la instrucción no los use
(`pipeline.md` §10.2). Entonces el campo `rs2` de un `addi` o del HALT (`rs2 = 1`) recibe un
valor reenviado, que termina en `ex_mem_store_data` o en el `result` del HALT. La máscara del
modelo compara esos campos en toda instrucción válida (`tools/isasim` §3). Con `completo`
tampoco sirve: el RTL todavía no tiene stall ni flush, y los programas con carga-uso o saltos
tomados se apartan.

El modelo ya tenía los mecanismos por separado (`Mode(forwarding, stall, flush)` y las
opciones `--sin-*` de `sim.py`), pero `prep_tb.py` y `regresion.py` solo aceptaban
`sin_riesgos` y `completo`.

## Opciones consideradas
1. **Un modo con nombre por cada estado intermedio**, en `isasim`, `prep_tb.py` y
   `regresion.py`, con su lista en `sw/programas.py`. Desde I-39, `forwarding`. Ventajas:
   la regresión de `master` es un comando sin opciones, y la lista de programas de cada modo
   está escrita y se prueba. Desventaja: cada integración de M8 agrega un modo.
2. **Pasar las opciones `--sin-stall` y `--sin-flush` a `prep_tb.py` y `regresion.py`**, como en
   `sim.py`. Ventaja: sirve para cualquier orden de merge de I-41 e I-42. Desventaja: la lista
   de programas de cada combinación no queda escrita en ningún lado, o se arma filtrando por
   lo que el modelo acepta, y así un programa que deja de pasar puede salir de la regresión
   sin que nadie lo note.
3. **Filtrar los campos según el formato** en la unidad de forwarding, o enmascarar
   `store_data` cuando la instrucción no es un store. Con eso la traza `sin_riesgos` coincidiría
   en más programas, pero cambia §10.2 (y obliga a filtrar igual en la detección de carga-uso,
   §10.3) o el contrato de la máscara solo para tapar un problema de la herramienta. Tampoco
   alcanza: los `fwd_*` sin `nop` siguen sin poder probarse.
4. **Dejarlo para I-40.** I-39 entra solo con el RTL y el testbench unitario. Desventaja: entre
   las dos PRs la regresión de `master` falla.

## Decisión
**Opción 1.** Cada integración de M8 compara el RTL contra el modelo con los mecanismos que
ya tiene. Desde I-39 es `--modo forwarding` (`isasim.FORWARDING = Mode(True, False, False)`),
y su lista `FORWARDING` en `sw/programas.py` son los 27 programas de M7 más los originales
que solo necesitan forwarding (`SOLO_FORWARDING`: `fwd_exmem`, `fwd_memwb`, `fwd_prioridad` y
`load_sin_dep`, sin carga-uso ni saltos tomados). El modo por defecto de `prep_tb.py` y de
`regresion.py` es el del RTL de `master`.

## Consecuencias
- `tools/isasim` (`pipeline.py`, `cli.py`), `scripts/prep_tb.py`, `scripts/regresion.py` y
  `sw/programas.py` tienen el modo `forwarding`. Los tests de `tools/isasim` comprueban que esos
  31 programas dan su `.exp` en `forwarding` y que los otros 8 originales con riesgos no.
- `sin_riesgos` sigue disponible (`--modo sin_riesgos`) para el pipeline de M7, pero ya no es
  la regresión de `master`.
- La I-41 o la I-42, la que entre primero, agrega su modo (forwarding con stall o forwarding
  con flush) y su lista, y cambia el valor por defecto. Con las dos adentro, el modo es
  `completo` y la I-43 corre todos los programas.
- `pipeline_tb` no cambia: el modo solo cambia la traza que prepara `prep_tb.py`.
