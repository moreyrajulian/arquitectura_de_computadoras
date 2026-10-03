# 004 - LOAD como único mecanismo de carga y reprogramación

- **Estado:** aceptada
- **Fecha:** 2026-09-29
- **Autores:** Costamagna, Matías

## Contexto
La consigna exige programar y reprogramar el procesador por UART, sin resintetizar, y responder
si hace falta vaciar la memoria de datos, los registros, el pipeline y la memoria de programa.
Además pide que el pipeline quede vacío al terminar la ejecución. Hay que decidir qué comandos
existen, qué se limpia y en qué estados se acepta.

## Opciones consideradas
1. **Comandos separados** (`LOAD`, `CLEAR_MEM`, `CLEAR_REGS`, `FLUSH`). Máxima flexibilidad,
   pero la PC puede dejar el sistema en un estado inconsistente si olvida alguno.
2. **`LOAD` único que además limpia todo lo que depende del programa anterior.** Un solo
   comando; el estado posterior siempre es conocido.
3. **`LOAD` sin limpiar nada.** Más rápido, pero el programa nuevo puede leer registros y
   memoria del anterior y ejecutar la cola de un programa más largo.

## Decisión
Opción 2. `LOAD` se acepta en cualquier estado, incluso `RUNNING`: detiene el core
(`enable = 0`, `core_rst = 1`), escribe `imem[0 … N−1]` y, si el `CHK` es correcto, rellena
`imem[N … fin]` con HALT (`0x00100073`), pone en cero la memoria de datos, el mapa de palabras
usadas y `cycles`, y libera el reset (PC = 0, registros = 0, pipeline vacío). `RESET` hace lo
mismo sin tocar la memoria de programa. Si el `LOAD` falla a mitad (`CHK` o timeout), el core
queda en reset en `NO_PROG` y la PC repite el `LOAD` completo.

| Pregunta de la consigna | Respuesta | Motivo |
|---|---|---|
| ¿Vaciar la memoria de datos? | Sí | Cada ejecución arranca igual y "memoria usada" refleja solo el programa nuevo |
| ¿Y los registros? | Sí | Si no, el resultado depende del historial |
| ¿Vaciar el pipeline? | Sí | Las instrucciones en vuelo del programa viejo escribirían registros o memoria |
| ¿Y la memoria de programa? | Se sobrescribe; el resto se llena con HALT | Evita ejecutar la cola de un programa anterior más largo |

## Consecuencias
- **Afecta la nota del HALT:** el core ya no puede salirse del final del programa. Un bucle
  infinito sigue sin terminar y se corta con `STOP`. Actualizar la respuesta a "¿qué pasa si no
  hay HALT?" en esa nota.
- Limpiar las BRAM recorre cada una una vez por el puerto B: unos 10 µs con 1 K palabras,
  despreciable frente a la UART.
- La Debug Unit necesita un estado `CLEAR` y el puerto B de las dos BRAM.
- Si más adelante se quisiera reanudar tras un HALT sin limpiar, habría que agregar un comando
  aparte: hoy desde `HALTED` solo se sale con `RESET` o `LOAD`.