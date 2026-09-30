# 003 - Banco de registros: implementación y conflicto de lectura/escritura entre ID y WB

- **Estado:** propuesta
- **Fecha:** 2026-09-29
- **Autores:** Moreyra, Julián

## Contexto
En el pipeline, el banco de registros se usa desde dos etapas en el mismo ciclo: ID
**lee** los operandos de una instrucción y WB **escribe** el resultado de otra instrucción,
tres más vieja. Si las dos usan el mismo registro, por ejemplo:

```
ciclo 5:   WB → add x3, x1, x2    (escribe x3)
           ID → sub x5, x3, x4    (lee x3)
```

y la escritura recién se hace efectiva en el flanco del final del ciclo, ID lee el valor
**viejo** de `x3` y `sub` calcula mal. Es un **riesgo estructural** sobre el banco de
registros: dos etapas lo usan en el mismo ciclo.

Restricciones:
- El clock no puede intervenirse (consigna).
- La Debug Unit tiene que poder leer los 32 registros para el dump (I-06).
- Al reprogramar puede ser necesario volver los registros a cero (pregunta de la
  consigna: "¿hay que vaciar los registros?").

## Opciones consideradas

### Conflicto ID–WB
1. **A — Escribir en el flanco descendente y leer en el ascendente** (medio ciclo para
   escribir y medio para leer). Es la solución clásica.
   - Ventajas: conceptualmente simple; no agrega lógica al banco.
   - Desventajas: en FPGA, todo el camino que arma el dato a escribir (salida de la BRAM
     de datos → extensión del load → mux de WB → entrada del banco) tiene que resolverse en
     **medio período**. Vivado lo analiza como un camino de medio ciclo, y es un candidato
     directo a camino crítico que limita la frecuencia de todo el procesador. Además,
     mezclar flancos complica el análisis de tiempo que pide la consigna.
2. **B — Bypass interno en el banco de registros.** Todo se escribe en el flanco de subida.
   Cada puerto de lectura compara su dirección con la de escritura: si coinciden y hay
   escritura, entrega directamente el dato que se está escribiendo.
   - Ventajas: un solo flanco; la solución queda encapsulada dentro del banco, sin afectar
     a otros módulos.
   - Desventajas: agrega un comparador de 5 bits y un mux de 32 bits en cada puerto de
     lectura, que suman retardo al camino de ID (poco).
3. **C — Resolverlo en la unidad de forwarding.** Implica guardar el último valor escrito
   (registro y dato) durante un ciclo más y agregarlo como tercera fuente de los muxes de
   forwarding en EX. Cuando la instrucción lectora llega a EX, la escritora ya salió del
   pipeline, así que sin ese registro extra el dato ya no está en ningún lado.
   - Ventajas: un solo flanco.
   - Desventajas: 38 flip-flops más y una entrada más en cada mux de forwarding. Complica
     la unidad de forwarding (I-05), que ya es de los bloques más delicados.

## Decisión
- **Conflicto ID–WB: opción B (bypass interno).** Se descarta la opción A porque
  partir el ciclo le pone al camino de WB un presupuesto de medio
  período, lo que en FPGA limitaría la frecuencia máxima. El bypass resuelve el mismo
  problema con un solo flanco y sin salir del banco de registros.
- **Almacenamiento: flip-flops.** Permiten el tercer puerto de lectura para la Debug Unit
  y el reset a cero al reprogramar. El costo (≈2,5 % de los FF del dispositivo) es
  aceptable.

## Consecuencias
- `pipeline.md` §4.2: los puertos de lectura incluyen el bypass. La escritura en `x0` se
  ignora y la lectura de `x0` devuelve 0 (el bypass nunca actúa sobre `x0`).
- La unidad de forwarding (I-05) solo necesita cubrir los casos EX/MEM → EX y MEM/WB → EX.
  El caso "WB escribe mientras ID lee" queda resuelto dentro del banco.
- La Debug Unit (I-06) dispone de un puerto de lectura propio.
- El reset del banco deja todos los registros en cero; queda disponible si la respuesta a
  "¿hay que vaciar los registros?" resulta ser sí.
- Si el análisis de tiempo mostrara que el camino de ID (lectura + bypass) es el crítico,
  revisar la opción C.
