# 028 - Regresión del pipeline por lotes en Vivado

- **Estado:** propuesta
- **Fecha:** 2026-11-01
- **Autores:** Moreyra, Julián

## Contexto
La I-38 pide que `pipeline_tb` con `+FINAL` pase todos los programas de la I-15 y sus
variantes `_nops`: 27 programas con el pipeline sin riesgos. La I-43 va a pedir lo mismo con
todos los programas de `sw/` en modo completo. La decisión
[021](021_banco-incremental.md) dejó anotado que esa regresión sería "un script que llama a
`prep_tb.py` y a xsim por cada uno", pero no existía. Hasta la I-37 cada PR corría los
programas con un script propio, fuera del repo, y el revisor no tenía cómo reproducirlo.

Hay tres restricciones:
- `pipeline_tb` simula los IP `imem_bram` y `dmem_bram`. Por eso corre dentro del proyecto de
  Vivado, con sus scripts de compilación, y no con `xvlog`/`xelab` sueltos.
- El programa se elige por plusarg (`+DIR`), con ruta absoluta, y en Windows los `.bat` de
  xsim parten los argumentos en el `=` (`verificacion.md` §8.6).
- Vivado corre en Windows y el repo puede estar en WSL: las rutas que ve Python no son las
  que ve Vivado.

## Opciones consideradas
1. **`launch_simulation` completo por programa:** compila y elabora el proyecto en cada
   corrida (~45 s cada vez). Es simple, pero 27 programas tardan más de 20 minutos, y 54 con
   `+PAUSAS` más de 40.
2. **Compilar y elaborar una vez, y correr el `xsim` del snapshot a mano** (`exec xsim ...`
   desde Tcl o desde Python): es rápido, pero hay que reproducir lo que hace Vivado con los
   `.bat`, el `=` del plusarg y el directorio de trabajo, distinto en Windows y en Linux.
3. **Compilar y elaborar una vez y seguir con `launch_simulation -step simulate`:** Vivado
   reusa el snapshot y solo vuelve a correr la simulación con el `xsim.simulate.xsim.more_options`
   nuevo. Cada corrida tarda ~5 s y las comillas y el directorio quedan a cargo de Vivado.

## Decisión
Opción 3, en dos pasos:
- **`scripts/regresion.py`** prepara cada programa con `prep_tb.py` y escribe
  `build/regresion/corridas.txt`, una corrida por línea (etiqueta, programa y plusargs además
  de `DIR`). Las listas por modo salen de `sw/programas.py`, las mismas que verifica
  `sw/test_programas.py`. Así no se repiten en otro lado.
- **`scripts/regresion.tcl`** se corre en Vivado, con el proyecto abierto o creándolo. Compila
  y elabora `pipeline_tb` una vez, corre cada línea, guarda un log por corrida y decide por la
  última línea `TEST ...` de cada log. Las rutas absolutas las arma el Tcl desde su propia
  ubicación, así que no importa desde dónde se corrió Python.

Todas las corridas usan `+FINAL`: con eso la misma corrida compara los registros de
segmentación en todos los ciclos y el estado final contra el `.exp`.

## Consecuencias
- **El revisor reproduce el criterio de la issue** con dos comandos (`verificacion.md` §8.7).
  El resumen queda en `build/regresion/resumen.txt` y, si algo falla, Vivado en batch sale con
  código 1.
- **`-step simulate` no recompila.** El primer `launch_simulation` del script siempre es
  completo, así que la regresión toma el RTL del momento. Si se corre `-step simulate` a mano
  después de editar un `.v`, se simula el snapshot viejo.
- **I-43** agrega `--modo completo`, que ya existe y corre todos los programas de `sw/`. Si
  aparecen programas que solo corren en M8, se suman a `sw/programas.py`.
- **Los testbenches unitarios** no entran en este script: cada uno se corre con su `top`.
  Si la I-43 los suma, se agrega otro tipo de línea a `corridas.txt`.
- Si cambia el directorio de simulación de Vivado (`<proyecto>.sim/sim_1/behav/xsim`), hay que
  cambiar de dónde copia el log `regresion.tcl`.
