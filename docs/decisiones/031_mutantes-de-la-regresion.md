# 031 - Mutantes del RTL para la regresión

- **Estado:** Aprobada
- **Fecha:** 2026-11-04
- **Autores:** Moreyra, Julián

## Contexto
`verificacion.md` §6 pide que cada mecanismo de riesgo (forwarding, bypass del banco, stall,
flush, parada por HALT) se desactive a propósito al menos una vez, para comprobar que algún
programa pasa a `TEST FAILED`. La I-40 lo hizo para el forwarding: apagó la unidad y rompió de a
una las reglas de `pipeline.md` §10.2, editando a mano copias del RTL. En la revisión de la PR
se pidió que el experimento quedara en el repo: así como estaba, los números de §8.2 no se
podían volver a obtener, y la I-43 tiene que hacer lo mismo con el resto de los mecanismos.

## Opciones consideradas
1. **Un define por mecanismo en el RTL** (`-d SIN_FORWARDING`, como los `STAGE_*` de
   `pipeline_tb`). Ventaja: se activa con una opción de compilación. Desventajas: mete código
   de prueba en el RTL que se sintetiza, un `ifdef` por cada mutante (son 16 solo para el
   forwarding), y cada mutante nuevo es un cambio de RTL que hay que revisar como tal.
2. **Parches (`.patch`) en `scripts/`**, aplicados a una copia del repo. Ventaja: el RTL no
   cambia. Desventajas: cada copia necesita su propio proyecto de Vivado (crearlo tarda más que
   la regresión), y un parche cuyo contexto cambió puede aplicarse corrido sin avisar.
3. **Una tabla de reemplazos de texto en `scripts/mutantes.py`**, y `regresion.tcl` que simula
   con la copia mutada en lugar del original, en el mismo proyecto. Ventajas: el RTL no cambia,
   un solo proyecto, y cada texto a reemplazar tiene que aparecer exactamente una vez en el
   original: si el RTL cambia, el mutante falla al aplicarse en vez de probar otra cosa.
   Desventaja: `regresion.tcl` modifica el proyecto durante la corrida (deshabilita un archivo y
   agrega otro a `sim_1`) y lo tiene que dejar como estaba.

## Decisión
**Opción 3.** `scripts/mutantes.py` tiene la tabla: nombre, archivo de `rtl/`, regla que rompe
y pares (texto original, texto mutado). `python scripts/regresion.py --mutante NOMBRE` (se puede
repetir, o `todos`) escribe cada copia en `build/mutantes/<nombre>/` y la lista en
`build/regresion/mutantes.txt`; sin `--mutante`, la lista se borra. `regresion.tcl`, si hay
lista, corre todas las corridas una vez por mutante. En cada pasada deshabilita el original en
`sources_1`, agrega la copia a `sim_1` y compila desde cero (`reset_simulation`). Al final, o
si algo falla, saca las copias y vuelve a habilitar los originales. El resumen dice qué corridas
detectan cada mutante, y el script termina con error si alguno no hace fallar ninguna.

## Consecuencias
- El experimento de la I-40 se repite con dos comandos (`verificacion.md` §8.2 y §8.7):
  `sin_forwarding` apaga la unidad, y los otros 15 rompen de a una las reglas de §10.2.
- **La I-43** suma a la tabla los mutantes del bypass del banco, el stall, el flush y el HALT, y
  corre `--mutante todos` con `--modo completo`.
- `python scripts/mutantes.py` lista los mutantes y comprueba que todos se pueden aplicar al RTL
  actual. Si un cambio del RTL rompe uno, se corrige su texto en la tabla.
- Cada pasada con mutante compila de nuevo, y la regresión normal también arranca con
  `reset_simulation`: sin eso, xsim puede reusar lo compilado de la pasada anterior.
- La regresión sin mutantes sigue como la describe la [028](028_regresion-por-lotes.md).
