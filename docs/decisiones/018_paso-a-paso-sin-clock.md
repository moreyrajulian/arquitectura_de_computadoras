# 018 - Ejecución paso a paso sin intervenir el clock

- **Estado:** propuesta
- **Fecha:** 2026-10-03
- **Autores:** Moreyra, Julián

## Contexto
La consigna exige un modo paso a paso ("un comando = un ciclo") y prohíbe intervenir el
clock. Habilitar o inhibir el clock con lógica (*clock gating*) genera *skew* entre redes de
reloj y rompe el análisis de timing en una FPGA, así que el avance del core tiene que
controlarse de otra forma.

Restricciones:
- La Debug Unit, la UART y el core comparten un único dominio de reloj (decisión 006).
- Con el core detenido, la Debug Unit lee registros, latches y memoria de datos (puerto B):
  lo que lee tiene que ser **el estado que corresponde al ciclo en que se detuvo**, sin
  cambiar mientras tanto.
- El `STEP` ejecuta un único ciclo, también cuando hay un stall en curso (`pipeline.md` §10.4).
- `LOAD` y `RESET` tienen que poder limpiar el core con el core detenido.

## Opciones consideradas
1. **A — Enable global (`enable`).** La Debug Unit genera una señal `enable`; todo elemento
   con estado del core solo se actualiza en los flancos donde `enable = 1`. El clock llega
   siempre a todos los flip-flops y nunca se toca.
   - Ventajas: un solo reloj y un solo árbol de clock, así que el análisis de timing es el
     normal. En 7-series cada flip-flop tiene una entrada *clock enable* (CE) propia, así que
     `if (enable)` no agrega un multiplexor a la entrada de datos: usa el CE del flip-flop.
     Cumple la consigna de forma directa. `STEP` es un pulso de `enable` de un ciclo.
   - Desventajas: `enable` es una señal de fanout alto (del orden de 1.400 flip-flops entre
     PC, registros de segmentación, banco de registros y avisos). Su camino hasta los CE entra
     en el análisis de timing y, en los registros que también frena un stall, se combina con
     la detección de load-use. Hay que acordarse de conectarla en cada elemento con estado
     nuevo; si falta uno, ese elemento sigue avanzando con el core detenido.
2. **B — `BUFGCE` de Xilinx.** Un buffer de reloj con entrada de habilitación que corta el
   clock de todo el core.
   - Ventajas: no hay `enable` en cada flip-flop, y baja el consumo dinámico con el core
     detenido.
   - Desventajas: **sigue siendo intervenir el clock**, que es lo que la consigna prohíbe: el
     core queda en una red de reloj gateada y la Debug Unit, la UART y el puerto B de las
     BRAM en otra. Las señales entre ambas (`enable`, `halt`, `dbg_*`) cruzan dos redes con
     distinta latencia de clock (*skew*) y cada BRAM tendría sus dos puertos en redes
     distintas. El único ahorro real, el de lógica, no existe en 7-series, porque el CE de
     cada flip-flop ya es gratuito. Se descarta.
3. **C — Reloj derivado (divisor con contador o MMCM) con `STEP` como un único pulso de ese
   reloj.**
   - Ventajas: el core no necesita ninguna señal de enable.
   - Desventajas: también es intervenir el clock y crea un dominio de reloj nuevo, con cruces
     hacia la UART y la Debug Unit que hay que sincronizar. Un reloj generado en la lógica
     queda mal para el análisis de timing, y un MMCM no se puede detener y arrancar un ciclo
     a la vez. Se descarta.

## Decisión
**Opción A: enable global.** La señal se llama `enable` (la usan `pipeline.md`,
`protocolo_debug.md` y `memoria.md`; es la que la issue llama `cpu_en`) y la genera la FSM de
ejecución de la Debug Unit (decisión 006): vale 1 en `RUNNING`, un ciclo en `STEP` y 0 en
`NO_PROG`, `READY`, `PAUSED` y `HALTED`.

### Elementos con estado que respetan `enable`
Todo flip-flop del core con estado se actualiza solo con `enable = 1`:

| Elemento | Dónde | Cómo respeta `enable` |
|---|---|---|
| `pc_reg` | IF | `en_pc = enable & ~stall` |
| IF/ID y salida de la memoria de programa | IF/ID | `en_if_id = enable & ~stall`; es también el `ena` del puerto A de `imem` |
| ID/EX | ID/EX | `en_id_ex = enable` |
| EX/MEM | EX/MEM | `en_ex_mem = enable` |
| MEM/WB y salida de la memoria de datos | MEM/WB | `en_mem_wb = enable`; es también el `ena` del puerto A de `dmem` |
| **Escritura de la memoria de datos** | MEM | `wea` solo tiene efecto con `ena = 1`, así que un store se escribe una sola vez, en el ciclo habilitado |
| **Escritura del banco de registros** | WB | `we = wb_reg_write & enable` |
| `halted` | WB | `halted <= 1` solo con `enable = 1` |
| `imem_fault`, `dmem_oob`, `dmem_misaligned` | MEM y WB | solo se actualizan con `enable = 1` (`memoria.md` §6.2) |
| `cycles` y mapa de palabras usadas | Debug Unit | cuentan solo los ciclos con `enable = 1` (`protocolo_debug.md` §3.1 y `memoria.md` §7) |

Quedan **fuera**, y no usan `enable`: la lógica combinacional, las dos FSM de la Debug Unit y
la UART, y el puerto B de las BRAM. El `core_rst` (reset síncrono) tiene prioridad sobre
`enable`: así `LOAD` y `RESET` limpian el core aunque `enable` valga 0. En los flip-flops de
7-series el reset síncrono ya tiene prioridad sobre el CE.

**Por qué importa cada fila.** Cada elemento que siguiera avanzando con el core detenido
mostraría a la PC un estado que no es el del ciclo que se pidió. Ejemplo con el banco de
registros: en un `STEP`, una instrucción `add x3, ...` entra a MEM/WB al final del ciclo y
queda retenida ahí. Si el banco escribiera sin mirar `enable`, escribiría `x3` en el primer
ciclo detenido, y el dump mostraría `x3` ya escrito con la instrucción todavía en MEM/WB: los
registros irían un paso adelante del pipeline. Con `we = wb_reg_write & enable`, `x3` se
escribe en el `STEP` siguiente, que es cuando la instrucción pasa por WB.

### Cómo se combina `enable` con el stall
`enable` y el stall de la unidad de riesgos se combinan con un AND, solo donde el stall retiene
algo, y con la prioridad `rst` > `en` > `flush` (`pipeline.md` §2):

```
stall       = load_use & ~redirect
en_pc       = enable & ~stall
en_if_id    = enable & ~stall
en_id_ex    = en_ex_mem = en_mem_wb = enable
flush_id_ex = redirect | stall
```

- **`enable` gana a todo lo demás.** Con `enable = 0` nada cambia, tampoco por un `flush`
  (`en` gana sobre `flush`): si ID/EX recibiera la burbuja del stall con el core detenido, el
  pipeline cambiaría sin un `STEP`.
- **El stall se retoma donde quedó.** Con `enable = 0` los registros no cambian, así que
  `load_use`, `stall`, `redirect` y los `en_*` valen lo mismo todos los ciclos detenidos. El
  `STEP` siguiente ejecuta exactamente el ciclo que habría ejecutado `RUN`: el paso a paso
  reproduce el modo continuo sin perder ni repetir instrucciones.
- **`stall` no baja `enable`.** Son señales independientes: `enable` viene de la Debug Unit y
  `stall` de la detección de riesgos, y cada una frena un conjunto distinto de registros.

## Consecuencias
- **Un solo reloj.** No hay `BUFGCE`, divisores ni dominios nuevos, y el análisis de camino
  crítico y *skew* que pide la consigna se hace sobre una única red de clock.
- **Regla para el RTL.** Todo elemento con estado que se agregue al core tiene que conectar
  `enable` (o un `en_*` derivado). Se revisa en cada PR de RTL del core.
- **Timing de `enable`.** Es una señal de fanout alto. Si `halt` la baja en el mismo ciclo
  (decisión 006), el camino `halt` → `enable` → CE de todo el core entra en el análisis. Se
  revisa en la integración (I-56); si limita la frecuencia, se registra la salida de la FSM y
  se acepta un ciclo más de HALT, que no cambia el estado final porque detrás del HALT solo
  hay burbujas (decisión 001).
- **Verificación.** `verificacion.md` §6 (nivel 4) ya pide el mismo estado final con `RUN` que
  con `STEP` repetido. Conviene sumar al testbench del core una corrida con un patrón de
  `enable` intermitente (aleatorio, con semilla fija) y comparar el estado final y la cuenta de
  ciclos con la corrida de `enable = 1` constante: detecta cualquier elemento que no respete
  `enable` sin depender de la Debug Unit.
- **Documentos actualizados en el mismo PR:** `pipeline.md` (§4.2, §7.3, §10.4 y §11) y
  `protocolo_debug.md` (§7).
