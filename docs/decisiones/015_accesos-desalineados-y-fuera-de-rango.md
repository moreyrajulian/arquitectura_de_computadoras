# 015 - Accesos desalineados y fuera de rango: se truncan y dejan un aviso

- **Estado:** aceptada
- **Fecha:** 2026-10-02
- **Autores:** Costamagna, Matías

## Contexto
Un load o un store puede calcular una dirección que no está alineada a su tamaño (`lw` en
`0x103`) o que cae fuera de los 4 KiB de la memoria de datos (`0x1004`). Lo mismo puede pasarle al
PC después de un `jalr` o de un salto mal calculado. La especificación RISC-V pide resolver esos
accesos o generar una excepción, pero el ISA de la consigna no tiene excepciones ni CSR.
`pipeline.md` §6.4 ya adelantaba que el hardware ignora los bits bajos y dejaba la política para
esta issue.

Restricciones:
- No hay mecanismo de excepciones; agregar uno implica una nueva fuente de flush.
- La dirección de la memoria de datos sale de `ex_mem_result` y el dato leído entra en WB al camino
  crítico candidato (decisión 012): nada debería agregarse en esos caminos.
- El modelo de referencia (I-16) tiene que reproducir el comportamiento bit a bit para comparar.
- Si un programa hace algo raro, la persona que lo depura tiene que poder enterarse.

## Opciones consideradas
1. **A — Truncar en silencio.** El hardware ignora los bits que no corresponden: los bits bajos según
   el tamaño (`lw`/`sw` ignoran `addr[1:0]`, `lh`/`lhu`/`sh` ignoran `addr[0]`) y los bits altos
   `[31:12]` (el acceso cae en `addr mod 4096`).
   - Ventajas: cero lógica; la BRAM recibe `addr[11:2]` y nada más.
   - Desventajas: un error del programa pasa inadvertido y puede pisar datos válidos por alias.
2. **B — Truncar y dejar avisos persistentes.** Igual que A, más tres flip-flops (`imem_fault`,
   `dmem_oob`, `dmem_misaligned`) que se ponen en 1 cuando ocurre cada caso y se ven en el bloque de
   estado.
   - Ventajas: el comportamiento sigue siendo el de A, pero visible; se calculan desde campos que ya
     están en EX/MEM y MEM/WB y nadie en el camino de datos los lee, así que no alargan ningún camino.
   - Desventajas: tres bits más en el bloque de estado y un poco de lógica de comparación.
3. **C — Anular el acceso fuera de rango.** Un store fuera de rango no escribe (`we = 0`) y un load
   devuelve 0.
   - Ventajas: un store fuera de rango no pisa datos.
   - Desventajas: el "devuelve 0" agrega un mux en WB, en el camino crítico candidato. Si solo se
     anulan los stores, loads y stores se comportan distinto ante la misma dirección.
4. **D — Detener el core en la instrucción que falla** (como un HALT con causa de error).
   - Ventajas: lo más parecido a una excepción; la Debug Unit podría informar el PC exacto.
   - Desventajas: la falla se detecta en MEM, con tres instrucciones más nuevas detrás: hay que
     agregar un flush de IF/ID, ID/EX y EX/MEM desde MEM y una segunda causa de parada. Es lógica
     de control nueva, justo en las señales de flush que ya están en el camino crítico.
5. **E — Resolver los desalineados en hardware** (partir el acceso en dos).
   - Ventajas: conforme a la especificación sin excepciones.
   - Desventajas: dos accesos a la BRAM, stall de un ciclo y un desplazador de 64 bits; ningún
     programa de prueba lo necesita.

## Decisión
**Opción B: el core trunca la dirección y cada caso deja un aviso persistente.**

| Caso | Qué hace el hardware | Aviso |
|---|---|---|
| `lh`/`lhu`/`sh` con `addr[0] = 1`; `lw`/`sw` con `addr[1:0] ≠ 0` | Accede a la media palabra o palabra alineada que lo contiene | `dmem_misaligned` |
| Load o store con `addr[31:12] ≠ 0` | Accede a `addr mod 4096` | `dmem_oob` |
| Instrucción que llega a WB con `pc[31:12] ≠ 0` o `pc[1:0] ≠ 0` | Se buscó `imem[pc[11:2]]` | `imem_fault` |

- Los avisos de la memoria de datos se calculan en MEM, donde la instrucción ya no puede ser
  anulada (los saltos se resuelven en EX y solo hacen flush de IF/ID e ID/EX).
- `imem_fault` se calcula en WB con `mem_wb_pc`, porque la búsqueda es especulativa: una búsqueda
  fuera de rango en el camino equivocado de un salto no levanta el aviso.
- Se borran con `core_rst` (`LOAD` y `RESET`). Viajan en los bits 2, 3 y 4 de `flags` del bloque de
  estado; los bits estaban reservados en 0, así que no cambia la versión del protocolo.
- La Debug Unit, en cambio, **valida** las direcciones que recibe de la PC (`READ_DMEM`) y responde
  `ERR_ADDR`: ahí sí hay a quién avisar en el momento.

Es la opción que no agrega nada al camino de datos ni al control del pipeline y que, a la vez, evita
que un error del programa pase inadvertido. El costo de C y D cae en los caminos que más preocupan
(WB y flush), y E resuelve un caso que los programas de prueba no tienen.

## Consecuencias
- `docs/spec/memoria.md` §6 tiene la tabla completa, ejemplos y el Verilog de referencia de los
  avisos; `pipeline.md` §6.4 la resume.
- `protocolo_debug.md` §3.1: `flags` bit 2 `imem_fault`, bit 3 `dmem_oob`, bit 4 `dmem_misaligned`.
- La interfaz de PC muestra una advertencia en el encabezado cuando alguno está en 1.
- **Modelo de referencia (I-16):** tiene que truncar igual (bits bajos según el tamaño y alias módulo
  4096) y calcular los mismos avisos, o la comparación con el hardware falla en esos casos.
- **Programas de prueba (I-15):** conviene uno que haga a propósito un acceso desalineado y otro fuera
  de rango, y verifique el valor obtenido y el aviso.
- **Respuesta a "¿qué pasa si no hay instrucción de parada?":** con el relleno de HALT de `LOAD`
  (decisión 004) el PC no puede salirse del programa; solo un programa de exactamente 1024 palabras
  sin HALT llegaría a `0x1000`, volvería a `imem[0]` por el alias y levantaría `imem_fault`.
- El comportamiento no es conforme a RISC-V. Si en el futuro se agregan excepciones, la opción D es
  el punto de partida y los avisos indican dónde engancharla.
