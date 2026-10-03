# 016 - Acceso por byte y media palabra con *byte write enable* de la BRAM

- **Estado:** aceptada
- **Fecha:** 2026-10-02
- **Autores:** Costamagna, Matías

## Contexto
La consigna pide `lb`, `lh`, `lw`, `lbu`, `lhu`, `sb`, `sh` y `sw`. La memoria de datos está
organizada en palabras de 32 bits (una BRAM de 1K × 32, decisión
[013](013_tamano-y-mapa-de-memorias.md)), así que leer o escribir un byte o una media palabra
requiere elegir qué parte de la palabra se toca. `pipeline.md` §6.2 y §7.1 ya describen una forma de
hacerlo; falta registrar la decisión y su porqué.

Restricciones:
- Un acceso por instrucción y por ciclo: el pipeline no tiene etapas multiciclo y un stall extra en
  cada `sb`/`sh` complicaría la unidad de riesgos.
- El dato leído llega en WB, a la salida de la BRAM (decisión 009), y entra en el camino crítico
  candidato (decisión 012).
- La memoria es little-endian, igual que RISC-V y que el protocolo de debug.

## Opciones consideradas
1. **A — *Byte write enable* de la BRAM, dato replicado y selección en WB.** Un store genera
   `we[3:0]` según el tamaño y `addr[1:0]` y pone el dato repetido en todas las posiciones
   (`{4{d[7:0]}}`, `{2{d[15:0]}}`); la BRAM escribe solo los bytes habilitados. Un load lee la
   palabra completa y WB elige el byte o la media palabra con `addr[1:0]` y la extiende.
   - Ventajas: un solo acceso, sin stall; la replicación es solo cableado; el IP lo soporta con una
     opción (*byte size* 8).
   - Desventajas: la selección y extensión del load quedan en WB, en el camino crítico candidato;
     MEM/WB tiene que transportar `funct3` y `addr[1:0]`.
2. **B — Leer, modificar y escribir.** El store lee la palabra, reemplaza los bytes y la vuelve a
   escribir.
   - Ventajas: funciona con una memoria sin escritura por byte.
   - Desventajas: dos accesos por `sb`/`sh` (un stall o un segundo puerto), y un riesgo nuevo si el
     store siguiente toca la misma palabra.
3. **C — Cuatro memorias de 8 bits**, una por byte.
   - Ventajas: escritura por byte natural.
   - Desventajas: cuatro IP en lugar de uno para obtener lo mismo que la opción del IP; complica el
     volcado y la limpieza desde la Debug Unit.
4. **D — Como A, pero desplazando el dato del store en lugar de replicarlo.**
   - Ventajas: el bus de datos de la BRAM muestra solo el byte útil en su lugar.
   - Desventajas: un mux de 4 entradas en MEM que la replicación evita; el resultado en memoria es
     idéntico.

## Decisión
**Opción A.** Es la única que resuelve los ocho accesos en un ciclo con el hardware que la BRAM ya
trae. La extensión en WB es un mux de pocas entradas y es la misma lógica que haría falta en
cualquier otra opción, porque el dato no está disponible antes.

| Instrucción | `funct3` | Escritura (`we[3:0]`, `wdata`) | Lectura (en WB) |
|---|---|---|---|
| `sb` / `lb`, `lbu` | `000` / `000`, `100` | `0001 << addr[1:0]`, `{4{d[7:0]}}` | byte `addr[1:0]`, con signo o con ceros |
| `sh` / `lh`, `lhu` | `001` / `001`, `101` | `0011 << {addr[1], 0}`, `{2{d[15:0]}}` | media palabra `addr[1]`, con signo o con ceros |
| `sw` / `lw` | `010` | `1111`, `d` | palabra completa |

`addr[0]` en una media palabra y `addr[1:0]` en una palabra se ignoran (accesos desalineados, nota
[015](015_accesos-desalineados-y-fuera-de-rango.md)).

## Consecuencias
- `dmem_bram` se genera con *byte write enable* de 8 bits: `wea[3:0]` para el core y `web[3:0]` para
  la Debug Unit (que siempre escribe `1111` al limpiar).
- `pipeline.md` §6.2 (stores) y §7.1 (loads) quedan como la definición de las fórmulas;
  `docs/spec/memoria.md` §5 tiene ejemplos numéricos para los testbenches.
- MEM/WB transporta `mem_wb_funct3` y `mem_wb_offset` (ya en `pipeline.md` §6.5).
- Un `sb`/`sh` marca como usada la palabra completa (decisión 005).
- Si el análisis de timing mostrara que el camino que pasa por la extensión del load limita la
  frecuencia, las medidas son las de la decisión 012 (comparador de igualdad, registrar `redirect`):
  la selección del byte no puede adelantarse, porque el dato recién existe a la salida de la BRAM.
