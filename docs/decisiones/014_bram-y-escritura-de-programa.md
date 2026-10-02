# 014 - Implementación de las memorias con BRAM y escritura de la memoria de programa por el puerto B

- **Estado:** propuesta
- **Fecha:** 2026-10-02
- **Autores:** Costamagna, Matías

## Contexto
La decisión 009 fijó que las memorias son BRAM de lectura sincrónica y cómo encaja su latencia en
el pipeline, y el diagrama de sistema reparte los puertos: A para el core, B para la Debug Unit.
Falta decidir cómo se genera cada BRAM (tipo de memoria y opciones del IP) y, sobre todo, **cómo
escribe la Debug Unit la memoria de programa** con lo que llega por la UART.

Restricciones:
- La carga y la reprogramación son por UART y sin resintetizar (consigna).
- El clock no se interviene: el core se detiene con `enable` y se limpia con `core_rst`.
- La consigna sugiere usar IP cores de Vivado para las memorias.
- El camino `pc_reg` → dirección de la BRAM no debe alargarse (decisión 009).
- La Debug Unit también tiene que leer y limpiar la memoria de datos (decisiones 004 y 005).

## Opciones consideradas

### Implementación
1. **A — Block Memory Generator, *True Dual Port* en las dos memorias.**
   - Ventajas: puertos A y B iguales y con los nombres que ya usan el diagrama de sistema,
     `pipeline.md` y `protocolo_debug.md`. Un IP por memoria, generado por script (`ip/*.tcl`).
     Para 1K × 32 ocupa un RAMB36, igual que cualquier otra configuración de dos puertos de 32 bits.
   - Desventajas: hay que generar el IP antes de simular; la profundidad no es un parámetro de
     Verilog.
2. **B — *Simple Dual Port* para la memoria de programa** (un puerto que solo escribe y otro que
   solo lee).
   - Ventajas: alcanza para la memoria de programa (el core solo lee y la Debug Unit solo escribe).
   - Desventajas: en el IP el puerto de escritura es el A y el de lectura el B, al revés del resto
     de la documentación; no ahorra BRAM con 1K × 32; impide leer la memoria de programa desde la
     Debug Unit si más adelante se quisiera verificar la carga.
3. **C — BRAM inferida desde Verilog** (`reg [31:0] mem [0:1023]` con lectura registrada).
   - Ventajas: profundidad parametrizable y simulación sin IP.
   - Desventajas: la síntesis puede no inferir la BRAM esperada (*byte write enable*, modos de
     lectura) y hay que revisarlo en cada cambio; se aparta de la sugerencia de la consigna y del
     diagrama acordado.
4. **D — RAM distribuida (LUTRAM).** Descartada en la decisión 009.

En todas las opciones de BRAM, el registro de salida opcional del IP (*Primitives Output Register*)
queda **desactivado**: con él la latencia pasa a 2 ciclos y deja de coincidir con IF/ID y MEM/WB.

### Escritura de la memoria de programa
1. **A — Puerto B dedicado a la Debug Unit, con el core en reset.** La Debug Unit arma cada palabra
   con 4 bytes de la UART y la escribe en `imem[wptr]` por el puerto B mientras mantiene
   `enable = 0` y `core_rst = 1`.
   - Ventajas: el core no se entera de cómo se carga la memoria; no hay ningún mux en el camino de
     IF; como el puerto A está deshabilitado (`ena = enable & ~stall = 0`), no puede haber
     colisiones; al liberar el reset el pipeline arranca vacío desde PC = 0.
   - Desventajas: no se puede modificar el programa mientras corre (no hace falta).
2. **B — Un solo puerto con un mux de dirección** entre `pc_reg` y la dirección de la Debug Unit.
   - Ventajas: libera el puerto B.
   - Desventajas: agrega un mux en el camino `pc_reg` → BRAM, que la decisión 009 quería corto, y
     acopla la Debug Unit con IF. El puerto B está libre de todas formas.
3. **C — Escribir con el core ejecutando** (parches en caliente).
   - Ventajas: reprogramación "sin parar".
   - Desventajas: instrucciones viejas ya buscadas siguen en el pipeline; habría que vaciarlo igual
     y el resultado depende del momento exacto de la escritura. Contradice la decisión 004.
4. **D — *Bootloader*:** un programa fijo en la memoria de programa que lee la UART y copia las
   instrucciones.
   - Ventajas: es como lo hacen los microcontroladores.
   - Desventajas: necesita UART mapeada en memoria, un camino de stores hacia la memoria de
     programa y un programa en ROM; mucho más hardware y software que la opción A, y la Debug Unit
     igual tiene que existir.
5. **E — Reescribir el contenido inicial del bitstream** (`updatemem`) y reprogramar la FPGA.
   - Ventajas: no requiere lógica de carga.
   - Desventajas: no es por UART, necesita Vivado y JTAG; no cumple la consigna.

## Decisión
**Block Memory Generator en *True Dual Port* para las dos memorias, sin registro de salida, y
escritura de la memoria de programa por el puerto B con el core detenido y en reset (opciones A y
A).**

- **Memoria de programa (`imem_bram`):** 1K × 32, puerto A de solo lectura para IF, puerto B de
  solo escritura para la Debug Unit, contenido inicial HALT en todas las palabras.
- **Memoria de datos (`dmem_bram`):** 1K × 32 con *byte write enable* de 8 bits, puerto A
  `READ_FIRST` para MEM, puerto B para que la Debug Unit lea (volcados) y escriba ceros (limpieza).
- **Carga:** `LOAD` → `LOAD_PREP` (`enable = 0`, `core_rst = 1`) → una escritura por cada 4 bytes
  recibidos → `CLEAR` rellena el resto con HALT y limpia la memoria de datos → se libera
  `core_rst`. Detalle de señales y tiempos en `docs/spec/memoria.md` §4.

La opción A de escritura es la única que no toca el camino de IF y que deja el core siempre en un
estado conocido al terminar la carga; usa un puerto que la BRAM ya tiene y que no costaría nada
extra. True Dual Port en la memoria de programa cuesta lo mismo que Simple Dual Port con este
tamaño y mantiene la misma convención de puertos en toda la documentación.

## Consecuencias
- `docs/spec/memoria.md` §3 tiene la tabla de opciones del IP, la conexión de cada puerto y la
  tabla de concurrencia; §4 la secuencia de carga.
- **I-20 e I-32:** escriben `ip/imem_bram.tcl` y `ip/dmem_bram.tcl` (los toma
  `scripts/create_project.tcl`) y los módulos envolventes en `rtl/memory/`.
- **I-46 (carga de programa):** registro de desplazamiento de 32 bits, contador de bytes de 2 bits y
  puntero `wptr` de 10 bits; la escritura es un pulso de un ciclo por palabra.
- **I-22 en adelante:** antes de que exista la Debug Unit, los testbenches pueden cargar programas
  en la BRAM con un `.coe` generado por el ensamblador.
- La salida `doutb` de la memoria de programa queda sin conectar; un futuro `READ_IMEM` (verificar
  la carga) no requiere regenerar el IP.
- Si el análisis de timing (I-56) mostrara que el *clock-to-out* de la BRAM limita la frecuencia,
  activar el registro de salida implica 1 ciclo más en cada búsqueda y en cada load; revisar junto
  con la decisión 009.
