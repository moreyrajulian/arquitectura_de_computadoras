# 009 - Convenciones de código RTL

- **Estado:** propuesta
- **Fecha:** 2026-10-02
- **Autores:** Costamagna, Matías

## Contexto
Dos personas van a escribir Verilog en paralelo durante meses. Sin convenciones comunes, la
integración y la revisión de PRs se vuelven lentas: hay que adivinar si una señal es entrada o
registro, si el reset es activo en alto o en bajo, o qué latencia tiene un módulo.

El código de TP1 y TP2 ya marca un estilo, aunque no del todo uniforme: `alu.v` usa prefijos
`i_`/`o_` y `NB_DATA`; `baud_gen` usa reset síncrono y el par `count_reg`/`count_next`; la UART
instancia con `u_`. Las convenciones parten de ahí para no reescribir lo que ya funciona.

## Opciones consideradas
1. **Idioma de identificadores.** Español: coincide con los comentarios, pero mezcla con las
   mnemónicas de la ISA (`add`, `funct3`, `rd`) y con los módulos existentes (`alu`, `uart_rx`).
   Inglés: coincide con la ISA, la especificación de RISC-V y el código existente.
2. **Dirección de puertos.** Sufijos `_i`/`_o` (estilo lowRISC) o prefijos `i_`/`o_` (estilo
   de la cátedra, ya usado en `alu.v`). Son equivalentes; el prefijo agrupa los puertos al
   ordenarlos y no obliga a cambiar `alu.v`.
3. **Registros.** `_q`/`_d` (estilo lowRISC) o `_reg`/`_next` (Chu, usado en TP2). Se queda
   `_reg`/`_next` por lo mismo.
4. **Reset.** Asíncrono o síncrono, activo en alto o en bajo. Xilinx recomienda síncrono y
   activo en alto en 7-series: los flip-flops tienen set/reset síncrono nativo y un reset
   asíncrono complica el timing y la inferencia de BRAM y DSP.

## Decisión

### Nombres
| Elemento | Convención | Ejemplo |
|---|---|---|
| Idioma | Identificadores en **inglés**; comentarios en español | `hazard_unit`, `// detecta load-use` |
| Estilo | `snake_case` para módulos, señales e instancias | `id_ex_reg`, `alu_result` |
| Puertos | Prefijo `i_` entrada, `o_` salida, `io_` bidireccional | `i_rs1_data`, `o_stall` |
| Reloj y reset | `i_clk`, `i_rst` | |
| Registros | `<nombre>_reg` (salida del FF) y `<nombre>_next` (entrada) | `pc_reg`, `pc_next` |
| Activo en bajo | Sufijo `_n` | `o_tx_busy_n` |
| Parámetros | `MAYUSCULAS`; anchos con prefijo `NB_` | `NB_DATA`, `NB_ADDR` |
| Codificaciones | `localparam` en mayúsculas con prefijo del grupo | `OP_ADD`, `ST_IDLE`, `FUNCT3_LW` |
| Instancias | Prefijo `u_` | `u_alu`, `u_regfile` |
| Registros de pipeline | `<etapa>_<etapa>_` en el nombre | `if_id_instr`, `ex_mem_alu_result` |

### Reglas
- **Reset síncrono y activo en alto**, siempre llamado `i_rst`. Solo se resetea lo que lo
  necesita (control, valid, PC); los caminos de datos y las memorias no.
- **Nada de números mágicos.** Anchos como `parameter`, codificaciones (opcodes, funct3, estados)
  como `localparam`. Las codificaciones compartidas por varios módulos van en un único
  `include` en `rtl/common/` cuando aparezca el primer caso, en lugar de copiarlas.
- **Un módulo por archivo**, con el mismo nombre que el módulo (`hazard_unit` en `hazard_unit.v`).
- **Cabecera obligatoria** en cada módulo: función, parámetros, puertos, latencia y valor tras el
  reset. Ver `rtl/common/_plantilla.v`.
- Cada archivo empieza con `` `timescale 1ns / 1ps `` y `` `default_nettype none `` y termina con
  `` `default_nettype wire ``. Así una señal mal escrita es un error de compilación y no un cable
  implícito de 1 bit.
- **Secuencial:** `always @(posedge i_clk)` solo con `<=`. **Combinacional:** `always @(*)` solo
  con `=`, con asignación por defecto al principio o `default` en el `case` para no inferir latches.
- Las FSM separan registro de estado y lógica de próximo estado, y control de camino de datos
  (como la UART de TP2 y la decisión 006).
- Un único dominio de reloj; no se gatea el clock (la consigna lo prohíbe, ver 006).
- Puertos en instancias siempre por nombre (`.i_clk(clk)`), nunca por posición.

### Testbenches
- Uno por módulo en `tb/unit/<modulo>_tb.v`, con módulo `<modulo>_tb`. Plantilla:
  `tb/unit/_plantilla_tb.v`.
- **Autoverificantes:** comparan contra un valor esperado o un modelo de referencia, y cada fallo
  imprime `ERROR` con el caso, lo obtenido y lo esperado. No se acepta un testbench que requiera
  mirar formas de onda para saber si pasó.
- Al final imprimen exactamente `TEST PASSED` o `TEST FAILED` con `$display` y terminan con
  `$finish`. Esa línea es la que se busca en el log de xsim al revisar un PR.
- Tienen un watchdog que termina con `TEST FAILED` si la simulación no avanza.
- Estímulos aleatorios con semilla fija, para que un fallo sea reproducible.

### Plantillas
Los archivos que empiezan con `_` (`_plantilla.v`, `_plantilla_tb.v`) son plantillas:
`scripts/create_project.tcl` no los agrega al proyecto de Vivado.

## Consecuencias
- Los módulos nuevos del procesador (pipeline, control, memoria, debug) siguen estas reglas
  desde el primer commit; la revisión de PR las verifica.
- El código de TP1 y TP2 **no se reescribe ahora**. Se adapta cuando se reutilice dentro del
  procesador: la ALU se rehace de todos modos para 32 bits y RV32I; la UART pasa a `i_clk`/`i_rst`
  y prefijos de puertos cuando se integre en la Debug Unit, y `baud_generator.v` se renombra para
  coincidir con su módulo `baud_gen`.
- Los puertos de `fpga/*/top.v` llevan los nombres que usa su `.xdc` (`clk`, `reset`, `rx`,
  `tx`, ...) y quedan exentos de los prefijos `i_`/`o_`; todo lo que está debajo del top sí los usa.
- Si en algún momento un bloque necesita reset asíncrono (por ejemplo, un sincronizador de
  entrada), se documenta como excepción en una nota nueva.
