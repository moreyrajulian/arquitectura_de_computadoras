# 012 - Resolución de saltos en EX, sin predicción

- **Estado:** aceptada
- **Fecha:** 2026-10-02
- **Autores:** Costamagna, Matías

## Contexto
Los saltos (`beq`, `bne`, `jal`, `jalr`) cambian el PC, pero el pipeline busca una
instrucción por ciclo sin saber todavía si la anterior era un salto ni hacia dónde va. Las
instrucciones buscadas mientras el salto no se resolvió pueden estar en el camino
equivocado (riesgo de control). Cuanto más tarde se resuelve, más instrucciones hay que
descartar; cuanto más temprano, más lógica hay que poner en las primeras etapas, que ya
están cargadas.

Restricciones y datos del diseño:
- Solo hay saltos por igualdad (`beq`, `bne`), además de `jal` y `jalr`
  (`docs/spec/isa.md`).
- Las memorias son BRAM sincrónicas: la instrucción llega a ID a la salida de la BRAM y el
  dato de un load recién está disponible en WB (decisión 009).
- El forwarding solo llega a EX (`pipeline.md` §10.2); el banco de registros resuelve el
  caso WB → ID con su bypass (decisión 007).
- La consigna evalúa el camino crítico y la frecuencia de funcionamiento, no los ciclos
  por instrucción. Los programas de prueba son cortos.

## Opciones consideradas

Los ciclos perdidos se midieron con un modelo ciclo a ciclo de las tres políticas, validado
contra una ejecución secuencial con 3000 programas aleatorios que incluyen lazos (saltos
hacia atrás), saltos hacia adelante, `jal` y `jalr`.

1. **A — Resolver en EX y hacer flush de IF/ID e ID/EX.** Es lo que ya describe
   `pipeline.md` §5.3 y §10.5. Equivale a predecir siempre "no tomado".
   - Ventajas: no agrega lógica. Los operandos de la comparación salen de ID/EX y del
     forwarding que ya existe, así que un salto que depende de la instrucción anterior no
     pierde ciclos. Hay una sola fuente de redirección.
   - Desventajas: un salto tomado pierde 2 ciclos. El camino que decide el salto (forwarding
     → ALU → `zero` → `redirect` → mux del PC) es el candidato a camino crítico.
2. **B — Adelantar la decisión a ID**, con comparador de igualdad, sumador `PC + imm` y
   `rs1 + imm` propios en ID.
   - Ventajas: un salto tomado pierde 1 ciclo.
   - Desventajas: los operandos se necesitan en ID, un ciclo antes. Hace falta forwarding
     EX/MEM → ID y una nueva regla de stall: el salto espera en ID si la instrucción anterior
     escribe uno de sus registros (+1 ciclo) o si depende de un load (+2 ciclos, o +1 si el
     load está a distancia 2). Además, el camino de ID se alarga: salida de la BRAM de
     programa → lectura del banco → bypass → forwarding → comparador → mux del PC.
3. **C — Predicción estática** (hacia atrás = tomado, hacia adelante = no tomado), con `jal`
   redirigido en ID y verificación en EX.
   - Ventajas: en un lazo, el salto hacia atrás pierde 1 ciclo en vez de 2.
   - Desventajas: un sumador `PC + imm` en ID, un bit de predicción que viaja en ID/EX, dos
     fuentes de redirección con prioridad, y un camino de recuperación (volver a `PC + 4` si
     el salto predicho tomado no se toma, perdiendo 2 ciclos). Ese mux de recuperación
     depende de `taken`, así que se agrega en el mismo camino crítico de la opción A. Una
     predicción dinámica (tabla de historia) suma estado que la Debug Unit no muestra y no
     tiene sentido para programas tan cortos.

### Ciclos perdidos por caso

| Caso | A: EX | B: ID | C: estática |
|---|:---:|:---:|:---:|
| `beq`/`bne` no tomado | **0** | 0 | 0 adelante · 2 atrás |
| `beq`/`bne` tomado | **2** | 1 | 1 atrás · 2 adelante |
| `jal` | **2** | 1 | 1 |
| `jalr` | **2** | 1 | 2 |
| Salto que usa el resultado de la instrucción anterior (aritmética) | **+0** | +1 | +0 |
| Salto que usa el dato de un load inmediatamente anterior | **+1** | +2 | +1 |
| Salto que usa el dato de un load a distancia 2 | **+0** | +1 | +0 |

### Ciclos por iteración en lazos de ejemplo

| Programa | A: EX | B: ID | C: estática |
|---|:---:|:---:|:---:|
| Suma de un arreglo: `lw`, `add`, `addi` puntero, `addi` contador, `bne` (5 instr.) | 8 | 8 | 7 |
| El mismo lazo con el decremento separado del `bne` (5 instr.) | 7 | 6 | 6 |
| `if/else` que alterna los dos caminos: `beq` sobre un dato cargado y `jal` (8,5 instr. en promedio) | 13,5 | 13,5 | 12 |

La opción B no gana nada cuando el salto depende de la instrucción anterior, que es el caso
más común (decrementar el contador y saltar, o saltar según un dato cargado): el ciclo
ahorrado en el salto se pierde en el stall. La opción C gana un ciclo por cada salto hacia atrás
tomado y por cada `jal`.

## Decisión
**Opción A: los saltos se resuelven en EX, sin predicción (se sigue buscando `PC + 4`).**

- Es la única opción que no agrega lógica ni casos nuevos de riesgos. Las opciones B y C
  agregan una segunda fuente de redirección, reglas nuevas en la unidad de riesgos y caminos
  nuevos que arrancan en la salida de la BRAM de programa.
- La ganancia de B es nula en los patrones típicos, y la de C es de un ciclo por iteración de
  lazo. En programas de prueba de decenas de instrucciones son unos pocos ciclos por
  ejecución, y lo que se evalúa es la frecuencia.
- C empeora justo el camino que más preocupa (agrega un mux después de `taken`).

**Penalización:** salto tomado (`beq`/`bne` tomado, `jal`, `jalr`) = **2 ciclos**; salto no
tomado = **0 ciclos**. Si el salto usa el dato de un load inmediatamente anterior, se suma el
stall de load-use (+1, `pipeline.md` §10.3).

## Consecuencias
- `pipeline.md` §5.3 y §10.5 dejan de estar "a confirmar"; `redirect` y `redirect_pc` salen
  de EX y el término `~redirect` de `stall` (§10.4) queda como protección, porque con esta
  decisión un stall y un salto nunca coinciden.
- **Implementación del flush:** solo hace falta poner en 0 `valid` y los campos de control de
  IF/ID e ID/EX (§2: los datos de una burbuja no importan). Eso reduce el fanout de
  `redirect`, que está en el camino crítico candidato.
- **Hipótesis de camino crítico, a verificar en la integración** con el reporte de timing de
  Vivado: el peor camino es el de la decisión de salto, que termina en `pc_reg`:

  ```
  BRAM de datos (dato de un load en WB) → extensión del load → mux de WB (wb_data)
    → mux de forwarding (01) → ALU (resta) → zero → taken → redirect
    → mux de próximo PC → pc_reg            (y redirect → flush de IF/ID e ID/EX)
  ```

  Es el camino de forwarding WB → EX que tiene cualquier instrucción, más la comparación y el
  mux del PC. Si el reporte confirma que limita la frecuencia, las medidas en orden de costo
  son:
  1. Comparar con un **comparador de igualdad** dedicado en EX (`rs1_val == rs2_val`) en
     lugar de la resta de la ALU y `zero`. Alcanza porque solo hay `beq` y `bne`, y saca la
     cadena de acarreo del camino.
  2. **Registrar `redirect`** y aplicarlo un ciclo después (desde MEM). Corta el camino en
     EX/MEM a cambio de un ciclo más de penalización (3).
  3. Bajar la frecuencia con el Clock Wizard, como prevé la consigna.
- Si en la integración el camino crítico resultara ser otro y sobrara margen en este, la
  opción C es la mejora natural para los lazos. Esta nota tiene los datos para comparar.
