# 001 - Codificación y comportamiento de la instrucción HALT

- **Estado:** propuesta
- **Fecha:** 2026-09-28
- **Autores:** Moreyra, Julián - Costamagna, Matias

La consigna exige una instrucción de parada, pero HALT no existe en RV32I.
Hay que elegir una codificación que no choque con las instrucciones
implementadas y que el ensamblador pueda generar, y definir qué hace el
hardware al llegar a ella.

Restricciones:
- No colisionar con ninguna instrucción de la tabla de `isa.md`.
- Decodificación barata en ID (ruta crítica; recursos limitados de la Basys 3).
- HALT no usa registros ni inmediato: no debe escribir registros ni memoria,
  ni generar riesgos de datos.
- Debe poder escribirse en los programas de prueba con un mnemónico, sin
  post-procesar el binario.
- Interacción con la Debug Unit: debe poder saber cuándo el procesador se
  detuvo.
- Interacción con saltos: en un pipeline, un HALT puede estar en una ruta
  especulada que un branch anterior todavía va a descartar.

## Opciones consideradas
1. **Opción A: reutilizar `ebreak` (`0x00100073`).**
   - Ventajas: ya definida en RISC-V; el ensamblador estándar la genera
     (`ebreak`); no choca con ninguna instrucción implementada (SYSTEM,
     `0x73`, no se usa en este ISA).
   - Desventajas: se le da a `ebreak` una semántica de parada que la
     especificación no define; si en el futuro se quisiera implementar
     `ebreak`/`ecall` reales habría conflicto. Hay que decodificar el word
     completo (o opcode + `imm[11:0]`) para no confundirla con `ecall`
     (`0x00000073`).
2. **Opción B: opcode propio en el espacio custom (`custom-0`, `0001011`).**
   - Ventajas: no colisiona nunca con el estándar; deja `funct3`/`funct7`
     libres para futuras instrucciones propias.
   - Desventajas: el ensamblador no la conoce; hay que emitirla con
     `.word 0x0000000B` o mantener una macro/parche propio. Agrega un
     comparador de opcode al decodificador.
3. **Opción C: salto a sí mismo (`jal x0, 0`, `0x0000006F`).**
   - Ventajas: sin cambios de hardware, 100 % RV32I.
   - Desventajas: no detiene nada (el pipeline sigue ciclando y buscando);
     es indistinguible de un bucle escrito a propósito; no hay forma de
     avisar a la Debug Unit sin detectar el patrón; no cumple la consigna.
4. **Opción D: usar una palabra ilegal (`0x00000000` / `0xFFFFFFFF`).**
   - Ventajas: decodificación trivial; memoria sin inicializar frenaría sola.
   - Desventajas: se pierde la detección de instrucciones inválidas; una
     carga defectuosa del programa pararía el procesador en silencio;
     imposible de escribir con un mnemónico.

## Decisión
Opción A: `HALT` se codifica como `ebreak` (`0x00100073`). Es la única opción
que cumple las tres condiciones de la consigna a la vez: no choca con lo
implementado, tiene un mnemónico que el ensamblador genera y no exige
herramientas propias. ECALL y el resto de SYSTEM quedan como no implementadas.

### Comportamiento del hardware (versión inicial)
1. **Decodificación (ID):** se compara la palabra completa contra
   `0x00100073` y se genera la señal `is_halt`. HALT viaja por el pipeline
   como una instrucción sin efectos: `RegWrite=0`, `MemWrite=0`, `MemRead=0`,
   sin salto.
2. **Detener la búsqueda:** mientras `is_halt` esté activa en ID, el PC se
   congela y IF inserta burbujas (NOP) en IF/ID. La instrucción que ya se
   había buscado detrás del HALT se descarta.
3. **Drenar el pipeline:** las instrucciones anteriores al HALT siguen
   avanzando y completan sus etapas (incluidos saltos, loads y stores) con
   normalidad.
4. **Cancelación por salto anterior:** el congelamiento del PC es
   combinacional (depende de `is_halt` en ID) y no se latchea todavía. Si un
   branch/jalr más viejo se resuelve como tomado, el flush habitual descarta
   ese HALT y la búsqueda se reanuda en el destino.
5. **Aviso a la Debug Unit:** cuando HALT llega a WB (ya no puede ser
   descartado por nadie anterior) se latchea `halted = 1`, que se expone a la
   Debug Unit. Desde ese momento el pipeline queda vacío y estable, así que
   la Debug Unit puede leer registros y memoria de forma consistente.
6. **Salida del estado halted:** por ahora solo con reset (o la orden que
   defina la Debug Unit). Queda pendiente definir si se puede reanudar.

### ¿Qué sucede si en la memoria no hay una instrucción de parada?
El procesador nunca se detiene por sí mismo: el PC sigue incrementando y
buscando palabras después del final del programa. Lo que ocurre entonces
depende de la memoria de instrucciones:
- Si las posiciones no usadas están en cero (`0x00000000`, palabra ilegal en
  RISC-V), el procesador ejecuta esa palabra según lo que haga el decodificador
  con opcodes no reconocidos (típicamente actúa como NOP), y recorre toda la
  memoria.
- Si el PC se trunca al tamaño de la memoria, al llegar al final da la vuelta
  y **reejecuta el programa desde el inicio**, en bucle.
- Si hay datos en posiciones altas y comparten memoria, se ejecutan como
  instrucciones con resultados impredecibles.
En todos los casos `halted` no se activa y solo la Debug Unit (o el reset)
puede detener la ejecución. Mitigación: los programas de prueba deben terminar
siempre con `ebreak`; opcionalmente se puede agregar una regla de que la
palabra `0x00000000` también active la parada (fuera del alcance de esta
decisión).

## Consecuencias
- **Decodificador (ID):** un comparador de 32 bits adicional y la señal
  `is_halt`.
- **Control de riesgos/hazard unit:** nueva causa de congelamiento del PC y de
  inserción de burbujas, con la salvedad del flush por salto anterior.
- **Etapa WB / Debug Unit:** nueva señal `halted`, a documentar en la
  interfaz de la Debug Unit.
- **Toolchain:** no requiere cambios; los programas se escriben con `ebreak`.
- **Más simple:** los tests pueden terminar con un mnemónico estándar.
- **Más difícil:** si más adelante se quiere `ebreak`/`ecall` como excepciones
  reales, habrá que recodificar HALT (por ejemplo a `custom-0`) y regenerar
  los programas de prueba.
- **A revisar si cambia algún supuesto:** el punto donde se resuelven los
  branches (EX vs MEM) afecta cuándo es seguro latchear la parada; si se
  agrega reanudación, `halted` debe tener una señal de limpieza