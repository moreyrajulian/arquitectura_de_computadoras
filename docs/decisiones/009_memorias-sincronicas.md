# 009 - Integración de las memorias de lectura sincrónica (BRAM) en el pipeline

- **Estado:** propuesta
- **Fecha:** 2026-09-29
- **Autores:** Moreyra, Julián

## Contexto
Las memorias de programa y de datos se implementan con BRAM mediante el IP *Block Memory
Generator* (ver `docs/diagramas/sistema.png`). Una BRAM tiene **lectura sincrónica**: el
dato aparece a la salida un ciclo de reloj **después** de presentar la dirección.

El camino de datos clásico de 5 etapas supone memorias de lectura asíncrona: la
instrucción está disponible en el mismo ciclo que el PC. Si se ignora esta diferencia,
la instrucción llega a ID con un ciclo de atraso y el pipeline queda desalineado. Hay que
definir cómo encaja la latencia en IF (memoria de programa) y en MEM (memoria de datos).

Restricciones:
- El clock no puede intervenirse (consigna): las esperas se resuelven con *enable*.
- La Debug Unit escribe la memoria de programa y lee la de datos por el puerto B.
- El diseño será evaluado por su camino crítico (análisis de tiempo de la consigna).

## Opciones consideradas

### Memoria de programa
1. **A — Direccionar con `pc_reg` y usar el registro de salida de la BRAM como
   `if_id_instr`.** La latencia de la BRAM coincide exactamente con el registro IF/ID, así
   que no se agrega ningún ciclo.
   - Ventajas: la dirección sale de un registro, así que el camino hacia la BRAM es
     corto. No agrega latencia.
   - Desventajas: el stall exige conectar el `ena` de la BRAM al `en` de IF/ID. El flush
     no puede limpiar la salida de la BRAM y se resuelve con el bit `valid`: si vale 0,
     la unidad de control de ID emite todas sus señales en 0. Después del reset la salida
     no tiene sentido (se cubre con el mismo `valid`).
2. **B — Direccionar con `pc_next` y conservar un registro IF/ID de flip-flops.** La
   instrucción aparece en IF junto con el PC, como con memoria asíncrona.
   - Ventajas: IF/ID es un registro común, así que stall, flush y dump son triviales.
   - Desventajas: toda la lógica que calcula `pc_next` (incluido el mux de redirección,
     que viene de la etapa que resuelve saltos) termina en el *setup* de la BRAM. Es
     candidato fuerte a camino crítico.
3. **C — Memoria distribuida (LUTRAM) con lectura asíncrona.** Reproduce el camino de
   datos clásico sin cambios.
   - Ventajas: la estructura más simple de razonar.
   - Desventajas: consume LUTs en proporción al tamaño de la memoria, se aparta del
     diagrama de sistema acordado y de la sugerencia de la consigna de usar IP cores
     para las memorias.

### Memoria de datos
La dirección sale de `ex_mem_result`, que es un registro, así que la BRAM la toma al final
del ciclo de MEM y entrega el dato durante el ciclo de WB. El registro de salida de la BRAM
**hace de campo `mem_wb_read_data`**, sin agregar ciclos. La latencia de un *load* no
cambia respecto del esquema clásico: el riesgo load-use sigue costando un solo stall. La única
diferencia es que la extensión de `lb`/`lh`/`lbu`/`lhu` (selección del byte o media palabra
y extensión) se mueve a WB, que tiene que recibir `funct3` y `addr[1:0]` a través de MEM/WB.

## Decisión
**Opción A para la memoria de programa**, y registro de salida de la BRAM como
`mem_wb_read_data` para la memoria de datos.

Motivo: es la opción que no agrega latencia y a la vez mantiene corto el camino hacia la
BRAM. El costo (anular el control con `valid`, `ena` atado al `en` de IF/ID) es chico, y el bit
`valid` se necesita igual para el dump y para detectar el pipeline vacío.

*Alternativa a evaluar al generar el IP:* el Block Memory Generator permite un pin de
reset del latch de salida con un valor configurable. Si se configura en `0x0000_0013`
(NOP), el flush podría forzar la salida a NOP. Queda como optimización y
no cambia la interfaz.

## Consecuencias
- `pipeline.md`, §3.2 y §3.3: IF/ID no tiene flip-flops para `instr`. El `ena` de la memoria de
  programa sale del `en` de IF/ID.
- Cuando `if_id_valid = 0`, la unidad de control de ID emite todas sus señales en 0
  (la instrucción se trata como burbuja).
- MEM/WB no tiene flip-flops para el dato leído. MEM/WB transporta `funct3` y `addr[1:0]`
  para extender el load en WB.
- El `ena` de la memoria de datos se conecta al `en` de MEM/WB, para que con el core
  detenido el dato leído no cambie.
- Si en la etapa de integración el camino crítico pasara por la BRAM, revisar esta
  decisión frente a la opción B o C.
