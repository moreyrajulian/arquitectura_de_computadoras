# 045 - Pantalla sin historial y con un latch por columna

- **Estado:** propuesta
- **Fecha:** 2026-11-26
- **Autores:** Costamagna, Matías

## Contexto
La pantalla de la decisión [043](043_vista-del-pipeline.md) tiene más de lo que se usa al
seguir un programa paso a paso:

- El panel **Historial de pasos** ocupa diez renglones de abajo. Le saca altura a Programa,
  Pipeline y Latches, y los latches se tienen que desplazar para ver ID/EX entero.
- Debajo de los riesgos, el panel Pipeline repite siempre la misma nota: «Riesgos inferidos
  por la PC a partir de los latches (la FPGA no los informa)».
- Los cuatro latches se ven de a dos (IF/ID y ID/EX a la izquierda, EX/MEM y MEM/WB a la
  derecha), así que no quedan debajo de la etapa que alimentan.
- Registros tiene 40 columnas y le sobran unas cuantas.

Un latch por columna necesita, con los nombres de [`pipeline.md`](../spec/pipeline.md) §8 y
los valores en el formato de siempre (`0x00000014`, `x4 (tp)`, `0000 add`), 16 + 19 + 21 + 20
columnas más los espacios: 82, y 86 con el borde. Programa ya está al límite con 50
(Memoria ocupa ~54 en el peor caso) y Registros no baja de 36 sin desplazar la tabla con
`-2147483648`. La pantalla mínima de [`interfaz_pc.md`](../spec/interfaz_pc.md) §2, de
160 × 45, no alcanza.

## Opciones consideradas
1. **Misma distribución; con menos de 172 columnas el panel de latches se desplaza a lo
   ancho.** El mínimo sigue en 160 × 45, pero a 160 quedan unas 12 columnas de MEM/WB fuera
   de la vista.
2. **Misma distribución y mínimo de 172 × 45.** Todo entra sin desplazar. Pide una terminal
   un poco más ancha (en una pantalla de 1366 px puede no alcanzar).
3. **Latches abajo, a todo lo ancho** (donde estaba el Historial). Entra a 160, pero arriba
   quedan ~19 renglones para Programa y Pipeline, y Memoria tiene que pasar a una pestaña de
   Programa. Cambia más el boceto.

## Decisión
**Opción 2.**

- **Historial:** se saca el panel y el modo de ver un volcado viejo en solo lectura. Esc
  solo cancela «correr hasta cursor». `Session.history` queda igual, porque lo usan el
  resaltado, las inconsistencias de `interfaz_pc.md` §4.3 y la columna «Escrito».
- **Nota de riesgos inferidos:** se saca. Todo lo que el panel Pipeline dice de riesgos es
  inferido, y así lo dice `interfaz_pc.md` §4.3.
- **Latches:** uno por columna, en el orden del pipeline. El ancho de cada columna sale del
  renglón más largo que puede tener (el nombre, un espacio y el valor más ancho de ese campo,
  o el título con «— burbuja»), no de los valores actuales, así no cambia entre un paso y
  otro. Con la tecla `c` (palabras crudas), las columnas se mantienen. El panel toma la
  altura de ID/EX (20 campos) y Pipeline se queda con el resto. Con menos de 172 columnas, el
  panel se desplaza a lo ancho en vez de partir los renglones.
- **Registros:** de 40 a 36 columnas, sin el relleno del panel.
- **Tamaño mínimo:** 172 × 45, en `interfaz_pc.md` §2 y §6 y en `test_tui.py`.

## Consecuencias
- Cambian `rvdebug/tui/` (`app.py`, `widgets.py`, `debugger.tcss`), `test_tui.py`,
  `interfaz_pc.md` §2 a §4, §6 y §8, y el README del debugger.
- De la decisión 043 queda sin efecto solo el panel de historial (los 500 renglones, Enter y
  Esc). El resto, incluido `Session.history`, sigue igual.
- **Puntos abiertos:** el boceto (`docs/diagramas/interfaz.drawio` y `interfaz.png`)
  todavía muestra el historial y los latches de a dos. Hay que actualizarlo.
