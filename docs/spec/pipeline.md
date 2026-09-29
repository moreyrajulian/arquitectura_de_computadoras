# Arquitectura del pipeline y camino de datos

> **Estado:** borrador — issue I-04 (#7). Las secciones marcadas *pendiente* se
> completan en los próximos commits de la rama `docs/7_pipeline`.

Este documento fija **qué hace cada etapa** del procesador y **qué información viaja
entre ellas**, para poder codificar `rtl/pipeline/` sin dudas sobre las interfaces.
Las instrucciones soportadas y su codificación están en [`isa.md`](isa.md).

---

## 1. Visión general

Procesador RV32I (subset de la consigna + HALT) segmentado en 5 etapas. Todo el diseño
corre en **un único dominio de reloj**: el clock nunca se detiene; parar o
avanzar el core se hace con señales de *enable* (ver `docs/diagramas/sistema.png`).

| Etapa | Responsabilidad | Bloques principales |
|---|---|---|
| **IF** | Mantener el PC y leer la instrucción | registro PC, sumador `+4`, mux de próximo PC, memoria de programa (puerto A) |
| **ID** | Decodificar, leer registros, armar el inmediato y las señales de control | banco de registros, generador de inmediatos, unidad de control |
| **EX** | Operar, calcular direcciones y destinos de salto | ALU, control de ALU, muxes de operandos, sumador de destino¹ |
| **MEM** | Leer o escribir la memoria de datos | memoria de datos (puerto A), alineación de datos y máscara de bytes |
| **WB** | Elegir el valor final y escribir el registro destino | extensión de loads, mux de write-back |

¹ La etapa en la que se resuelven los saltos se decide en I-09. Este documento asume EX
como punto de partida.

```
        ┌────┐  IF/ID  ┌────┐  ID/EX  ┌────┐  EX/MEM  ┌─────┐  MEM/WB  ┌────┐
 PC ──► │ IF │ ──██──► │ ID │ ──██──► │ EX │ ──██───► │ MEM │ ──██───► │ WB │
        └────┘         └────┘         └────┘          └─────┘          └────┘
                          ▲                                               │
                          └──────────── escritura de rd ◄─────────────────┘
```

---

## 2. Convenciones

### Anchos
- Datos y direcciones: **32 bits** (`XLEN = 32`).
- Números de registro: 5 bits (`x0`–`x31`).

### Nombres de señales
- Señales internas de una etapa: prefijo de la etapa — `if_`, `id_`, `ex_`, `mem_`, `wb_`.
  Ejemplo: `ex_alu_out`.
- Campos de un registro de segmentación: prefijo del registro — `if_id_`, `id_ex_`,
  `ex_mem_`, `mem_wb_`. Ejemplo: `id_ex_rs1_data` es el valor de `rs1` que ID dejó
  guardado para EX.
- Puertos de módulo: `i_` / `o_`, como en `rtl/common/alu.v`.

### Control de los registros de segmentación
Todo registro de segmentación tiene las mismas tres entradas de control:

| Entrada | Efecto |
|---|---|
| `rst` | Lleva el registro a burbuja (ver abajo). |
| `en` | Si vale 0 el registro **conserva** su contenido (stall o core detenido). |
| `flush` | Si vale 1 el registro se carga con una **burbuja** en lugar de la instrucción entrante. |

Este documento solo fija que esas entradas **existen**. Quién las maneja y con qué
prioridad se define en otras issues:
- `en`: combinación del *enable* de la Debug Unit (I-06) y del *stall* por riesgos (I-05).
- `flush`: saltos tomados (I-09) y riesgos (I-05).

### Bit `valid` y burbujas
Cada registro de segmentación lleva un bit **`valid`** que indica si contiene una
instrucción real.

Una **burbuja** es un registro con `valid = 0` y con **todas las señales de control que
tienen efectos en 0**: escritura de registro, escritura de memoria, salto y halt. Los
campos de datos de una burbuja no importan, porque nada los usa.

El bit `valid` se incluye por tres motivos:
1. El dump de latches (Debug Unit) puede mostrar qué etapas tienen instrucciones reales
   y cuáles tienen burbujas.
2. El requisito de la consigna "el pipeline queda vacío al terminar" se puede verificar
   directamente: todos los `valid` en 0.
3. Sirve para anular la instrucción de IF/ID, cuya salida no se puede resetear (ver §3.4).

---

## 3. Etapa IF — Instruction Fetch

### 3.1 Responsabilidad
Mantener el PC, pedir a la memoria de programa la instrucción que está en esa dirección
y decidir cuál es el próximo PC.

### 3.2 Bloques
- **`pc_reg`** (32 bits): dirección de la instrucción que se está buscando. Valor de
  reset: `0x0000_0000` (a confirmar en I-07, mapa de memoria).
- **Sumador `+4`**: cada instrucción ocupa 4 bytes y la memoria se direcciona por bytes.
- **Mux de próximo PC**.
- **Memoria de programa, puerto A** (solo lectura). El puerto B lo usa la Debug Unit
  para cargar el programa (ver `sistema.png`).

### 3.3 Próximo PC
IF no necesita saber qué tipo de salto hubo: la etapa que resuelve los saltos le entrega
un pedido de redirección con la dirección ya calculada.

```
if_pc_next = redirect ? redirect_pc : pc_reg + 4
pc_reg    <= if_pc_next     (solo si en_pc = 1)
```

| Señal | Ancho | Origen | Significado |
|---|---|---|---|
| `redirect` | 1 | etapa que resuelve saltos (I-09) | Hay que cambiar el flujo: `beq`/`bne` tomado, `jal` o `jalr`. |
| `redirect_pc` | 32 | ídem | Destino: `PC + imm` (branch, `jal`) o `(rs1 + imm) & ~1` (`jalr`). |
| `en_pc` | 1 | I-05 / I-06 | Si vale 0 el PC no avanza (stall o core detenido). |

Los bits `[1:0]` del PC valen siempre `00`, porque las instrucciones están alineadas a 4
bytes. La memoria se direcciona por palabra: `addr = pc_reg[AW+1:2]`.

### 3.4 Memoria de programa de lectura sincrónica
La memoria de programa es una BRAM: **entrega el dato un ciclo después** de recibir la
dirección. Se direcciona con `pc_reg`, y **su registro de salida hace de campo `instr`
del registro IF/ID**.

```
ciclo          t            t+1           t+2
pc_reg         p            p+4           p+8
addr BRAM      p            p+4           p+8
dout BRAM      (anterior)   instr(p)      instr(p+4)
if_id_pc       (anterior)   p             p+4
etapa ID       —            instr(p)      instr(p+4)
```

`if_id_pc` se registra en el mismo flanco en que la BRAM toma la dirección, así que en
ID la instrucción y su PC llegan juntos.

Tres consecuencias:
- **Stall:** para que IF/ID conserve la instrucción, la entrada de *enable* de la BRAM
  (`ena`) va conectada al `en` de IF/ID. Con `ena = 0` la BRAM mantiene su salida.
- **Flush:** la salida de la BRAM no se puede forzar a NOP desde afuera, así que el flush
  pone `if_id_valid = 0`. ID reemplaza la instrucción por un NOP
  (`addi x0, x0, 0` = `0x0000_0013`) cuando `if_id_valid = 0`.
- **Reset y reprogramación:** después de un reset, la salida de la BRAM tiene un valor
  sin sentido. Como el reset pone `if_id_valid = 0`, ese valor se ignora con el mismo
  mecanismo que el flush.

### 3.5 Salidas hacia IF/ID

| Campo | Ancho | Descripción |
|---|---|---|
| `if_id_pc` | 32 | PC de la instrucción buscada. |
| `if_id_instr` | 32 | Instrucción. Es la salida registrada de la BRAM, no un flip-flop aparte. |
| `if_id_valid` | 1 | 1 si la instrucción es real; 0 si es burbuja (flush o reset). |

`PC + 4` no viaja por el pipeline: se vuelve a calcular en EX para `jal` y `jalr`.
Así se ahorran 32 bits por cada registro de segmentación.

---

## 4. Etapa ID — Instruction Decode

*Pendiente.*

## 5. Etapa EX — Execute

*Pendiente.*

## 6. Etapa MEM — Memory Access

*Pendiente.*

## 7. Etapa WB — Write Back

*Pendiente.*

## 8. Registros de segmentación

*Pendiente: tabla completa de IF/ID, ID/EX, EX/MEM y MEM/WB.*

## 9. Señales de control

*Pendiente: lista con la etapa de origen y la de consumo de cada señal.*
