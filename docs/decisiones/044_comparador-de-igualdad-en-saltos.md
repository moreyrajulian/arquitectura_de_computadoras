# 044 - Comparador de igualdad para decidir los saltos

- **Estado:** propuesta
- **Fecha:** 2026-11-18
- **Autores:** Moreyra, Julián

## Contexto
La I-56 midió el camino crítico del diseño a 65 MHz, post-implementación
([`docs/timing/`](../timing/README.md), sección I-56). Con el RTL de `master` el WNS es
+0,435 ns, y los 30 peores caminos son la decisión de salto: dato de un load en WB → forwarding →
mux de `alu_b` → ALU → `zero` → `taken` → `redirect` → flush de ID/EX, `ena` de `imem` y enables
del PC y de IF/ID. Es la hipótesis de la decisión [012](012_resolucion-saltos.md), pero el tramo
más largo no es la resta: `zero` se calcula sobre el resultado ya multiplexado de las 10
operaciones, así que el camino pasa por el desplazador (`alu_b[4:0]` es el `shamt`). El mux de
`alu_b`, la ALU y `zero` suman 6,86 de los 14,21 ns.

La 012 dejó tres medidas en orden de costo si este camino limitaba la frecuencia, y la
[042](042_reloj-del-sistema-a-65-mhz.md) le asignó la primera a la I-56. Restricciones:
- Solo hay `beq` y `bne` ([`isa.md`](../spec/isa.md)): alcanza con igualdad.
- La consigna evalúa el camino crítico y la frecuencia, no los ciclos.
- Cambiar los ciclos obliga a cambiar el modelo, los `.exp` y `ciclos` de todos los programas con
  saltos.

## Opciones consideradas
1. **Comparador de igualdad en EX** (medida 1 de la 012): `branch_unit` compara `rs1_val` y
   `rs2_val`, los operandos ya reenviados (salida de los muxes de forwarding, antes del mux de
   `alu_b`), con su propio comparador.
   - Ventajas: saca del camino el mux de `alu_b`, la ALU y `zero`. No cambia ciclos, `.exp` ni el
     modelo (es la misma función: `rs1 − rs2 = 0` si y solo si `rs1 = rs2`). Es poca lógica: un
     comparador de 32 bits, que síntesis arma con LUT y la cadena de acarreo.
   - Desventajas: dos operandos de 32 bits más hasta `branch_unit`; el comparador queda en serie
     con el forwarding, que sigue en el camino.
2. **Registrar `redirect`** y aplicarlo desde MEM (medida 2 de la 012).
   - Ventajas: corta el camino en EX/MEM.
   - Desventajas: 3 ciclos por salto tomado. Cambian `pipeline.md` §10.5, el modelo, los `.exp` y
     el flush (un salto más en vuelo).
3. **Registro de salida de las BRAM** (decisiones [009](009_memorias-sincronicas.md) y
   [014](014_bram-y-escritura-de-programa.md)): saca los 2,45 ns de *clock-to-out* de `dmem_bram`.
   - Desventajas: un ciclo más en cada load y en cada búsqueda (2 stalls por load-use, 3 ciclos
     por salto tomado), con los mismos cambios en el modelo y los `.exp`.
4. **No cambiar nada** y quedarse con los 65 MHz de la 042.
   - Desventajas: la 042 ya dejaba el comparador como primera medida de la I-56; sin él, la I-57
     no tiene margen para subir de 65 MHz.

## Decisión
**Opción 1: `beq` y `bne` deciden con un comparador de igualdad sobre `rs1_val` y `rs2_val`.**

```
eq    = (rs1_val == rs2_val)
taken = branch & (eq ^ funct3[0])
```

- `branch_unit` recibe `i_rs1_val` e `i_rs2_val` en lugar de `i_zero`; `ex_stage` le pasa la
  salida de los muxes de forwarding. `jalr` sigue usando `alu_out` para `redirect_pc`.
- La ALU no cambia: conserva `o_zero`, que queda sin conectar en `ex_stage` (síntesis lo elimina).
  Así el cambio de RTL se limita a `branch_unit` y `ex_stage`.
- La unidad de control sigue mandando `ALU_SUB` en `beq`/`bne` (`pipeline.md` §4.4); el
  resultado no se usa.

**Resultado** (65 MHz, post-implementación, mismo flujo para las dos):

| | Sin comparador | Con comparador |
|---|---|---|
| WNS | +0,435 ns | **+1,418 ns** |
| Datos del peor camino / niveles | 14,212 ns / 12 | 13,151 ns / 11 |
| Frecuencia estimada | ~66,9 MHz | ~71,6 MHz |

El peor camino sigue siendo la familia del salto, pero ya no pasa por la ALU. Las opciones 2 y 3
no se aplican: cambian los ciclos y la consigna no los evalúa.

## Consecuencias
- [`pipeline.md`](../spec/pipeline.md) §5.2 (`zero` sin uso), §5.3 (fórmula de `taken` y puertos de
  `branch_unit`) y el diagrama de §5; [`verificacion.md`](../spec/verificacion.md) §3 (fila de
  `branch_unit`). El camino de datos anterior queda en
  [`datapath_sin_comparador.png`](../diagramas/datapath_sin_comparador.png) para comparar con
  [`datapath.png`](../diagramas/datapath.png).
- `branch_unit_tb` cambia el oráculo: `beq` salta si `rs1 == rs2`, con operandos que difieren en
  un solo bit (bit 0, bit 31 y cada bit del barrido), y `beq`/`bne` no miran `alu_out`.
  `alu_tb` sigue probando `o_zero`.
- `tools/isasim` calcula `taken` con la misma igualdad (§5.3). Los ciclos, las trazas y los `.exp`
  no cambian; la regresión completa da lo mismo.
- La 012 sigue vigente (saltos en EX, sin predicción, 2 ciclos por salto tomado); esta nota aplica
  su primera medida. Lo que queda de su hipótesis (el tramo largo era el desplazador, el destino
  es el flush y el `ena` de `imem` y no `pc_reg`) está en [`docs/timing/`](../timing/README.md).
- **I-57**: elige la frecuencia final con este diseño. La estimación de ~71,6 MHz es una cota: al
  cambiar el reloj cambia el ruteo, que es 64 % del camino.
- Si hiciera falta más margen, lo siguiente es el *clock-to-out* de la BRAM y el WB (29,5 y 20 %
  del camino con el comparador), con el costo en ciclos de las opciones 2 y 3.
