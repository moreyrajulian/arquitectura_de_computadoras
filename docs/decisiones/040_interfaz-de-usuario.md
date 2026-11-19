# 040 - Interfaz de usuario: capas `model` y `session`, hilos y corte con la I-53

- **Estado:** propuesta
- **Fecha:** 2026-11-17
- **Autores:** Moreyra, Julián

## Contexto
La I-52 programa la interfaz de la PC sobre el cliente del protocolo (`tools/debugger/rvdebug`,
I-50). Hay varias cosas ya fijadas:
- La decisión [008](008_interfaz-pc.md) elige una TUI con Textual, separada en las capas
  `client` / `model` / `session` / `tui`.
- [`interfaz_pc.md`](../spec/interfaz_pc.md) tiene el boceto, los controles con sus estados
  (§3), el paso a paso (§4) y el modo continuo (§5).
- El cliente es seguro entre hilos: un lock serializa el puerto, y `wait_halted` lo suelta
  mientras espera para que otro hilo pueda mandar `STOP` (`tools/debugger/README.md` §3).

Falta decidir:
- **Qué hace la I-52 y qué deja a la I-53** (vista del pipeline, de la otra persona), porque el
  boceto los mezcla en una sola pantalla. La I-52 pide conectar, cargar un `.s`, ejecutar, paso,
  reprogramar, y mostrar registros (hex, decimal y nombres ABI) y memoria. La I-53 pide la
  instrucción de cada etapa, el resaltado de lo que cambió y los stalls, burbujas y flushes.
- **Qué hay en `model` y en `session`**, y qué devuelve cada acción.
- **Cómo se usa el puerto sin congelar la pantalla**, sobre todo durante `RUN`.
- **Cómo se arranca el programa.**

## Opciones consideradas

**Corte entre I-52 e I-53**
1. **La I-52 hace solo lo de su criterio**, sin el resto de la pantalla.
   - Desventajas: la I-53 tendría que armar la distribución de la pantalla y la máquina de
     estados de los controles, y la pantalla del boceto quedaría sin probar hasta el final.
2. **La I-52 hace la app completa con lugares vacíos para la I-53.**
   - Todas las capas, la distribución del boceto, todos los controles de la I-52 y los paneles
     Programa, Registros, Memoria, Tramas y la barra de estado.
   - Pipeline, Latches e Historial quedan como paneles vacíos con su título. Las etiquetas de
     etapa, el resaltado y los riesgos inferidos los agrega la I-53 en `model` y en esos paneles.
   - Ventajas: la I-53 solo agrega vistas y reglas. El esqueleto queda probado con Pilot desde
     ya.
3. **La I-52 hace todo el boceto.**
   - Desventajas: le saca el trabajo a la I-53.

**Hilos**
1. **Un worker de Textual por acción, en un hilo** (`run_worker(thread=True)`), con el
   resultado devuelto con `call_from_thread`.
   - `RUN` es un worker aparte, que espera el final de a 0,5 s y entre espera y espera manda
     `STATUS`.
   - `STOP`, `RESET` y `LOAD` corren en otro worker mientras tanto: el lock del cliente
     serializa el puerto, y el `RUN` termina solo cuando llega un estado que no es `RUNNING`.
2. **Un hilo lector permanente** que despacha todo lo que llega.
   - Desventajas: duplica lo que ya hace el cliente (el `EVT_HALTED` en medio de otra
     respuesta, los reintentos).

## Decisión
- **Corte (opción 2).**
  - La I-52 entrega `model`, `session` y `tui` completos, con los paneles Programa (dirección,
    palabra, `disassemble` y la pestaña «Fuente .s»), Registros (`x1/ra`, hex y decimal; `d` con
    o sin signo, `0` oculta los ceros), Memoria («Usada» y «Rango»), Tramas (`t`), el encabezado
    con el estado y los avisos, y la barra de estado.
  - Controles: F1, F2, F3, F5, F6, F8, F9, F10, Shift+F10 (Paso×N) y `q`. F4 («hasta cursor»)
    necesita el PC de WB, que sale de los latches: llega con la I-53. `e` (exportar en el
    formato del modelo de referencia) iba a llegar con la I-54, que finalmente hizo la
    comparación como un script aparte (ver *Consecuencias*).
  - Pipeline, Latches e Historial quedan como paneles vacíos, que llena la I-53.
- **`model`** (`rvdebug/model.py`, sin Textual): los nombres ABI, el formato hex y decimal de
  una palabra y `Snapshot`. `Snapshot` es el volcado de `READ_ALL` y, si se pidió, el último
  `READ_DMEM`; es inmutable. La I-53 agrega acá `diff`, la decodificación de los latches y la
  inferencia de riesgos.
- **`session`** (`rvdebug/session.py`, sin Textual): `Session(client)`, con un método por control
  que devuelve el `Snapshot` nuevo.
  - Cada acción termina en `READ_ALL`, salvo `RUN`, que termina en `wait_halted`.
  - `step_n` corta en `HALTED` y hace un solo `READ_ALL`.
  - `enabled(acción)` es la tabla de §3 y `needs_confirm` dice cuándo Cargar o Reprogramar
    piden confirmación en `RUNNING`.
  - Lee un `.s` con `rvasm.assemble`, y un `.hex` o un `.bin` con un lector propio. Las palabras
    las filtra `classify` dentro de `client.load` (decisión
    [025](025_filtro-de-palabras-en-el-toolchain.md)).
  - Como la confirmación de `RUN` no trae bloque de estado, `Session` recuerda que hay un `RUN`
    en curso hasta que `wait_halted` devuelve.
- **Hilos (opción 1).** El watchdog de §5 (5 s por defecto) abre un modal desde el worker de
  `RUN` y espera la respuesta: [Detener] manda `STOP`; [Seguir esperando] vuelve a contar.
- **Arranque:** `python tools/debugger/debugger.py [--port COM10] [--prog sw/x.s]`, con el mismo
  patrón que `asm.py` y `sim.py`. Sin `--port`, F1 lista los puertos y propone el de VID/PID de
  FTDI (§6). El conector del puerto se le pasa a la app, así los tests usan el puerto simulado
  de `tests/fake_debug_unit.py`.

## Consecuencias
- `rvdebug/__init__.py` exporta `Session` y `Snapshot`, pero no la TUI: el cliente, `model` y
  `session` se siguen usando y probando sin Textual. `tests/test_tui.py` se saltea si no está.
- `requirements.txt` suma `textual>=8`; `requirements-dev.txt`, también `textual`. Los tests de
  la TUI corren con `asyncio.run` dentro de tests comunes, sin `pytest-asyncio` (la decisión 008
  lo nombraba como posibilidad).
- **I-53**: llena los paneles Pipeline, Latches e Historial, agrega `diff` y la decodificación
  de latches en `model`, las etiquetas de etapa en Programa y el resaltado, y F4. `Session`
  guarda `before_run`, el volcado anterior a `RUN`, para que el resaltado después de `RUN`
  compare contra él (§5).
- **I-54**: la comparación con `tools/isasim` y el README. El plan era agregar `e` (exportar
  el volcado en JSON para compararlo después con el modelo). La I-54 lo cambió por un script
  aparte, `tools/debugger/comparar.py` (README §8): carga el programa, lo lleva a un ciclo con
  `RUN` o `STEP` y compara el volcado con la foto del modelo en ese ciclo; con `--sin-cargar`
  compara el estado en que quedó la placa después de usar el debugger. Tiene el volcado y el
  modelo en memoria, así que no hace falta un formato de intercambio que mantener igual en
  `rvdebug` y en `isasim`, y la comparación no depende de Textual. A cambio, no se compara
  desde la TUI: hay que cerrarla, porque el puerto lo usa uno solo. La TUI no tiene `e`.
- **Pendiente de la I-49**: el criterio «funciona contra la placa». Hasta entonces la interfaz se
  prueba contra la Debug Unit simulada.
