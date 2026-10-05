# 019 - Programas de prueba: estado inicial, variantes con nop y convenciones de sw/

- **Estado:** propuesta
- **Fecha:** 2026-10-03
- **Autores:** Costamagna, Matías

## Contexto
[`verificacion.md`](../spec/verificacion.md) §4 fija los 22 programas de `sw/` y su estado
esperado (`.exp`), pero todos suponen el pipeline completo con forwarding, stall y flush. El
plan construye el pipeline etapa por etapa ([`planificacion.md`](../planificacion.md)) y la
issue I-15 pide programas que sirvan antes:

- **De IF a MEM (M3 a M6) no existe WB.** Ninguna instrucción puede escribir un registro, así
  que un programa normal ni siquiera puede armar sus operandos con `addi`.
- **En M7 (I-38) el pipeline está completo pero sin riesgos resueltos**: no hay forwarding,
  detección de carga-uso ni flush. Los programas de riesgos y de saltos dan otro resultado.
- El testbench (I-17) y el modelo de referencia (I-16) tienen que leer el mismo estado
  inicial, y el testbench es Verilog (`.v`, decisión [010](010_convenciones-rtl.md)): no
  puede depender de un parser propio.

Además, `verificacion.md` decía `sw/<nombre>.asm`, mientras que el ensamblador
([017](017_ensamblador.md)), su README y la interfaz de la PC usan `.s`.

## Opciones consideradas

**Etapas sin WB**
1. **Inicializar registros y memoria desde el testbench y usar instrucciones independientes**
   (ninguna lee un registro que escribe otra). El resultado se observa en el registro de
   segmentación de cada etapa y no depende de WB ni del forwarding.
   - Ventajas: prueba cada etapa sola; el mismo programa corre después en el core completo.
   - Desventajas: hace falta un archivo de estado inicial y una convención para saber qué
     programas lo usan.
2. **Esperar a WB para probar con programas.** Las etapas anteriores se prueban solo con
   estímulos a mano.
   - Desventajas: contradice el plan de verificación (nivel 2) y deja los errores de IF a MEM
     para cuando hay cinco etapas juntas.

**Formato del estado inicial**
1. **El formato de `$readmemh` con direcciones (`@<índice> <valor>`) y comentarios `//`.**
   - Ventajas: el testbench lo carga con una línea, sin parser; el modelo lo lee con pocas
     líneas de Python; es disperso (solo lo que no es cero) y legible con comentarios.
   - Desventajas: dos archivos (uno por arreglo); en `dmem` el índice es de palabra, no la
     dirección en bytes (se aclara en un comentario por línea); hay que poner todo en cero
     antes de leerlo, porque `$readmemh` no toca lo que no nombra.
2. **El mismo formato del `.exp`** (`regs:` / `dmem:`).
   - Ventajas: un solo formato para leer.
   - Desventajas: Verilog no lo puede leer; haría falta un script que lo convierta y un
     archivo generado más.
3. **Un prólogo de instrucciones que carga los valores.** No sirve: sin WB no se escribe nada.

**Programas para M7**
1. **Una variante `_nops` de cada programa de riesgos o de saltos**, con `nop` hasta que toda
   dependencia quede a distancia 3 (la resuelve el bypass del banco, que existe desde M4) y dos
   `nop` detrás de cada salto.
   - Ventajas: el mismo programa, con el mismo resultado, corre en M7; y como un `nop` anulado
     por el flush cuesta lo mismo que uno ejecutado, el `.exp` (ciclos incluidos) vale igual en
     M7 y en M8.
   - Desventajas: duplica 10 programas, que hay que mantener junto con el original.
2. **Correr en M7 solo los programas sin riesgos.**
   - Desventajas: los saltos (`branch_cond`, `jump`) quedarían sin probar hasta M8, mezclados
     con el flush.
3. **Escribir todos los programas con `nop`.**
   - Desventajas: dejarían de probar el forwarding, el stall y el flush, que es para lo que
     existen.

## Decisión
- **Programas independientes `indep_<grupo>`** (R, I, cargas, stores, saltos, `lui`) que parten
  de `sw/estado_inicial/regs.hex` y `dmem.hex`: leen solo `x1`–`x9` y escriben solo
  `x11`–`x31`, y cada salto va seguido de dos `nop`. El prefijo `indep_` es lo que dice que el
  programa usa el estado inicial; todos los demás parten de todo en cero, como después de
  `LOAD` (decisión [004](004_carga-y-reprogramacion.md)).
- **Estado inicial en formato `$readmemh`** con `@<índice>` y comentarios. Lo que no aparece
  vale 0.
- **Variantes `<nombre>_nops`** solo para los programas que no corren sin forwarding, stall o
  flush. Un programa sin riesgos no la necesita. `halt_stall` y `halt_camino_equivocado` no la
  tienen porque prueban justamente la interacción del HALT con el stall y el flush.
- **Extensión `.s`**, como el ensamblador; se corrige `verificacion.md`.
- **`sw/test_programas.py`** comprueba lo que no requiere ejecutar: que cada programa ensamble y
  tenga su `.exp` con el formato de `verificacion.md` §5, que estén todos los del plan, que
  entre todos aparezca cada instrucción del ISA y que los `indep_*` sean independientes. Los
  valores del `.exp` los verifica el modelo de referencia (I-16), como fija
  `verificacion.md` §2.

Las convenciones completas están en [`sw/README.md`](../../sw/README.md).

## Consecuencias
- **Banco de pruebas incremental (I-17):** antes de liberar el reset, para los `indep_*` pone en
  cero el banco y `dmem` y carga `sw/estado_inicial/*.hex` con `$readmemh` sobre los arreglos
  del modelo de simulación. Si `dmem` es la BRAM del Block Memory Generator, hay que ver cómo
  inicializarla en simulación (por ejemplo, escribiendo por el puerto B, como la Debug Unit).
- **Modelo de referencia (I-16):** lee los mismos dos archivos para los `indep_*` y tiene que
  coincidir con el `.exp` de los 38 programas, incluidas las variantes.
- **Validación sin riesgos (I-38):** corre los programas sin riesgos y las variantes `_nops`;
  M8 (I-40, I-43) corre todos.
- **Si cambia el estado inicial**, cambian los `.exp` de los seis `indep_*`.
- **Si cambia el costo de un salto o del stall** (decisión [012](012_resolucion-saltos.md)), hay
  que recalcular los ciclos de los `.exp`; las variantes `_nops` dejan de dar los mismos ciclos
  en M7 y en M8 si el salto tomado deja de costar 2.
- Los destinos de `jalr` en `jump`, `salto_depende`, `indep_saltos` y sus variantes son
  direcciones fijas (el ensamblador no acepta etiquetas en el desplazamiento de `jalr`): el
  comentario de cabecera de cada uno dice qué instrucción corregir si se mueve el código.
