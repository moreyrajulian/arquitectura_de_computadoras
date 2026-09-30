# 007 - Debug Unit con dos FSM independientes

- **Estado:** A
- **Fecha:** 2026-09-29
- **Autores:** Costamagna, Matías

## Contexto
En modo continuo el core ejecuta mientras la PC puede mandar `STOP` o `STATUS`, y al llegar al
HALT hay que avisar con un `EVT_HALTED` sin petición. Una única FSM que recibe la trama,
ejecuta y transmite bloquearía la UART mientras el core corre. La consigna además prohíbe
intervenir el clock: parar y avanzar el core solo puede hacerse con `enable`.

## Opciones consideradas
1. **Una sola FSM.** Menos estados, pero no puede escuchar la UART en `RUNNING`, así que `STOP`
   no funciona y el `halt` se perdería si llega durante una respuesta.
2. **Dos FSM independientes:** una de protocolo (recibe, valida, ejecuta y responde) y una de
   ejecución del core (`NO_PROG`, `READY`, `RUNNING`, `PAUSED`, `HALTED`), que genera `enable` y
   `core_rst` y detecta `halt`.
3. **Detener el core gateando el clock.** Descartada: la consigna prohíbe intervenir el clock.

## Decisión
Opción 2. La FSM de ejecución baja `enable` en el mismo ciclo en que llega `halt` y marca
`evt_pending`; la FSM de protocolo manda el `EVT_HALTED` cuando vuelve a `IDLE` sin ninguna
trama en curso. `STEP` es un pulso de `enable` de un ciclo. Cada FSM separa control y camino de
datos, como en la UART del TP2.

## Consecuencias
- `STOP` y `STATUS` funcionan mientras el core ejecuta.
- `STEP` termina un ciclo después del pulso para que `halt` ya sea visible en el estado.
- Hay dos diagramas (`debug_unit_fsm` y `debug_unit_estados_core`) y dos testbenches.
- El único acoplamiento entre las FSM son unas pocas señales (`enable`, `core_rst`, `halt`,
  `evt_pending`, comandos `RUN`/`STOP`/`STEP`); cambiar una no obliga a rehacer la otra.
- El core y las BRAM siguen en un único dominio de reloj, sin cruces de clock.