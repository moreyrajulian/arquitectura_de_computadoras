# 008 - Interfaz de PC: TUI con Textual

- **Estado:** propuesta
- **Fecha:** 2026-10-02
- **Autores:** Costamagna, Matías

## Contexto
La PC tiene que cargar un programa, ejecutarlo en modo continuo o paso a paso, reprogramar el
procesador y mostrar en cada paso los 32 registros, los cuatro latches intermedios, la memoria
de datos usada y el estado del pipeline. La consigna pide **creatividad** en la visualización.
El protocolo ya está fijado ([`protocolo_debug.md`](../spec/protocolo_debug.md)) y el cliente
existente (`tools/debugger/serial_comm.py`) es Python con pyserial. Hay que elegir el tipo de
interfaz (CLI, TUI o GUI) y la tecnología antes de programarla (I-52).

Restricciones: tiene que correr en Windows (las PC de los integrantes) y en Linux (laboratorio),
y la interfaz se programa en la etapa de fin de año, con **poco margen de tiempo**
([`planificacion.md`](../planificacion.md), M10).

## Opciones consideradas
1. **CLI tipo REPL** (estilo gdb: `load`, `step`, `regs`). Lo más rápido de hacer y fácil de
   usar desde scripts. Pero el estado completo de un paso (registros + latches + memoria) no
   entra en una pantalla que se desplaza, no se ve qué cambió entre pasos y no aporta a la
   creatividad que pide la consigna.
2. **TUI con Textual** (sobre Rich). Pantalla fija con paneles, colores, tablas, atajos de
   teclado y ratón, en la terminal. Python puro, `pip install textual`, corre igual en
   Windows Terminal y en Linux. Trae `App.run_test()` / `Pilot` para testear la vista sin
   pantalla. Límite: el pipeline y las flechas de forwarding se dibujan con caracteres.
3. **GUI de escritorio con PySide6 (Qt).** Diagrama del pipeline dibujado de verdad, pero
   bastante más código (layouts, `QThread`, modelos de tablas), una dependencia de ~100 MB y
   tests de vista con `pytest-qt`.
4. **GUI web local** (FastAPI + websocket + HTML/JS). Máxima libertad visual, pero dos
   lenguajes, dos procesos y más superficie para mantener.

## Decisión
Opción 2: **TUI con Textual**, Python ≥ 3.11 y pyserial para el puerto.

Es la opción con mejor relación entre lo que se ve y el tiempo que lleva: con widgets ya
hechos (`DataTable`, `Static`, `Footer`, `TabbedContent`) se arma la pantalla completa
(pipeline, latches, registros, memoria, historial) y se resalta lo que cambió en cada paso,
sin pelear con layouts gráficos ni hilos de Qt. Todo queda en Python, igual que el ensamblador
y el modelo de referencia. Se descartó la GUI de Qt (elegida en un primer momento) porque el
costo extra de desarrollo no entra en el cronograma.

Para que la lógica no dependa de la vista, el software se separa en capas (detalle en
[`interfaz_pc.md`](../spec/interfaz_pc.md)):

- `protocol` / `client`: tramas, checksum, timeouts y reintentos. **Python puro, sin Textual.**
- `model`: volcado de un paso (`Snapshot`), diferencias entre pasos e inferencia de
  stalls/forwarding a partir de los latches. Python puro.
- `tui`: solo vista y atajos. El puerto serie se lee en un *worker* de Textual
  (`@work(thread=True)`) que publica mensajes a la app.

## Consecuencias
- `tools/debugger/` pasa a tener `requirements.txt` con `textual` y `pyserial`
  (y `pytest`, `pytest-asyncio` para tests).
- El cliente y el modelo se testean sin terminal con las tramas de ejemplo de
  `protocolo_debug.md` §4. El modelo de referencia (I-16) y los tests de integración pueden
  usar el cliente sin levantar la TUI.
- El `EVT_HALTED` llega sin petición: el worker del puerto tiene que estar siempre leyendo y
  despachar por `CMD`, sin bloquear el bucle de eventos de la app.
- La terminal tiene que medir al menos **160 × 45** caracteres para ver todos los paneles;
  con menos, los paneles secundarios (historial, tramas) pasan a pestañas.
- En Windows hay que usar **Windows Terminal** (la consola clásica `conhost` no muestra bien
  los colores ni los caracteres de caja).
- Si más adelante sobra tiempo, la capa `model` permite agregar otra vista (por ejemplo, una
  GUI) sin tocar el cliente.
