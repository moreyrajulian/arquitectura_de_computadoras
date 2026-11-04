# 030 - Corridas sin `+FINAL` en la regresión por lotes

- **Estado:** propuesta
- **Fecha:** 2026-11-04
- **Autores:** Moreyra, Julián

## Contexto
La decisión [028](028_regresion-por-lotes.md) dice que todas las corridas de la regresión
usan `+FINAL`: la traza ciclo a ciclo y el estado final contra el `.exp`. La
[029](029_modo-del-modelo-en-m8.md) define el modo `forwarding` y su lista `FORWARDING`, con
los programas cuyo `.exp` coincide con forwarding y sin stall ni flush.

En la revisión de la I-40 apareció un hueco. Ninguno de los 31 programas de `FORWARDING`
tiene un `beq`, `bne` o `jalr` que lea un registro escrito por una de las dos instrucciones
anteriores, así que el forwarding hacia los saltos (`pipeline.md` §10.7) no lo prueba nadie.
Lo prueba `salto_depende`, pero toma saltos: sin flush ejecuta las dos instrucciones del camino
equivocado y su estado final no coincide con el `.exp` hasta la I-42.

La traza sí sirve. En `--modo forwarding` el modelo tampoco tiene flush y ejecuta las mismas
instrucciones que el RTL, así que `pipeline_tb` sin `+FINAL` compara los cuatro registros de
segmentación en todos los ciclos (`verificacion.md` §8.2). Es lo mismo que se hizo con
`branch_cond` desde `STAGE_REDIRECT`.

## Opciones consideradas
1. **Correrlo a mano** y dejar escrito en `verificacion.md` cómo hacerlo. Ventaja: no cambia
   ningún script. Desventaja: la regresión, que es lo que se corre después de cada cambio, no
   lo incluye, y el forwarding hacia los saltos se puede romper sin que nada falle.
2. **Una lista de programas que en un modo se comparan solo contra la traza**, en
   `sw/programas.py`, que `regresion.py` suma a las corridas del modo sin `FINAL`. Ventaja: la
   regresión cubre el caso con el mismo comando de siempre, y la lista queda escrita y probada,
   como pide la 029. Desventaja: no todas las corridas comprueban el estado final.
3. **Esperar a la I-42** para sumar `salto_depende` con `+FINAL`. Desventaja: hasta entonces
   la I-40 no cierra el forwarding, y la I-41 se integraría sin ese caso en la regresión.

## Decisión
**Opción 2.** `sw/programas.py` tiene `SOLO_TRAZA_FORWARDING = ["salto_depende"]`, y
`regresion.py` en modo `forwarding` suma esos programas a las corridas sin `FINAL` (también la
corrida con `+PAUSAS`, si se pide). Una línea de `corridas.txt` sin `FINAL` ya la aceptaba
`regresion.tcl`. Un programa entra en la lista solo si el modelo lo ejecuta en ese modo sin
error y su `.exp` difiere solo por un mecanismo que el RTL todavía no tiene. Este caso lo
comprueba un test de `tools/isasim` (`salto_depende` difiere del `.exp` solo en los registros
del camino equivocado).

Es una excepción a la regla de la 028 de que todas las corridas usan `+FINAL`, solo para los
programas de esa lista.

## Consecuencias
- Con la lista, la regresión `forwarding` tiene 32 corridas, y 64 con `--pausas`
  (`verificacion.md` §8.7). La I-40 cierra el forwarding con esa regresión.
- **La I-42** (flush) saca `salto_depende` de la lista y lo pasa a correr con `+FINAL`, en el
  modo que agregue (029). Si la lista queda vacía, se puede dejar el mecanismo para otro
  estado intermedio o sacarlo.
- `regresion.py` imprime qué programas corren sin `+FINAL`, para que se vea en cada corrida.
- `prep_tb.py` sigue avisando que el modelo difiere del `.exp` para estos programas. Es
  esperado: el aviso dice qué registros cambian.
