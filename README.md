# Arquitectura de Computadoras

Repositorio de los trabajos prácticos de la materia **Arquitectura de
Computadoras** (FCEFyN, UNC).

A lo largo de la cursada se desarrollan, en Verilog, los distintos bloques que
componen un procesador, implementados y verificados sobre una **Basys 3**
(Artix-7 `xc7a35tcpg236-1`) con **Vivado**. Cada trabajo práctico construye una
pieza reutilizable que converge en el trabajo final: la implementación de un
procesador **RISC-V**.

## Integrantes

- Costamagna, Matías
- Moreyra, Julián

## Ramas y evolución del proyecto

- `tp1_signed_implementation`: implementación inicial de la ALU, con carga de
  operandos y opcode mediante switches y pulsadores de la placa.
- `tp2_uart`: reemplaza la interfaz manual de la placa por una comunicación
  serie UART. La operación completa se recibe y devuelve por el puerto serie,
  manteniendo la ALU como núcleo combinacional reutilizable.

Respecto de `tp1_signed_implementation`, esta rama:

- incorpora soporte explícito para operandos y resultados con signo;
- conserva las operaciones `ADD`, `SUB`, `AND`, `OR`, `XOR`, `NOR`, `SRA` y
  `SRL`, con `SRA` aritmético y `SRL` lógico mediante conversión a unsigned;
- elimina del `top` la carga por switches, los pulsadores, el antirrebote y la
  salida por LEDs;
- agrega un generador de baud rate, un receptor UART, un transmisor UART y una
  interfaz de buffers de un elemento para conectar la comunicación con la ALU;
- incorpora una FSM que recibe un opcode y dos operandos, ejecuta la operación
  y transmite un byte con el resultado;
- reemplaza los constraints de switches, LEDs y pulsadores por los pines `rx`
  y `tx` del puente USB-UART integrado de la Basys 3.

## TP2 — ALU con interfaz UART

La carpeta `TP2_UART/` contiene todos los archivos correspondientes a esta
rama:

    TP2_UART/
    ├── constraints/
    │   └── basys3.xdc       Constraints de reloj, reset y UART
    ├── rtl/
    │   ├── alu.v            Núcleo combinacional de operaciones
    │   ├── alu_top.v        FSM de recepción, cálculo y transmisión
    │   ├── baud_generator.v Generador del tick de baud rate
    │   ├── flag_buff.v      Buffer de un dato con flag de disponibilidad
    │   ├── intf_circ.v      Interfaz entre UART y controlador de la ALU
    │   ├── top.v             Integración completa del sistema
    │   ├── uart_rx.v         Receptor UART 8N1 con sobremuestreo 16x
    │   └── uart_tx.v         Transmisor UART 8N1
    ├── serial_comm.py        Ejemplo de comunicación desde una PC
    └── tb/
        └── uart_tb.v         Testbench de extremo a extremo

### Protocolo de comunicación

Cada operación se envía como una secuencia de tres bytes:

    [opcode] [operando A] [operando B]

Luego de recibir la secuencia, la FPGA calcula el resultado y devuelve un
único byte por UART. Los opcodes utilizados por la ALU son:

| Operación | Opcode |
|---|---|
| `ADD` | `0x20` |
| `SUB` | `0x22` |
| `AND` | `0x24` |
| `OR`  | `0x25` |
| `XOR` | `0x26` |
| `SRA` | `0x03` |
| `SRL` | `0x02` |
| `NOR` | `0x27` |

Los operandos y el resultado tienen un ancho predeterminado de 8 bits. La
interfaz UART utiliza una trama de 8 bits de datos, sin paridad y un bit de
stop (8N1). El divisor predeterminado (`DVSR = 326`) está configurado para un
reloj de 50 MHz, sobremuestreo 16x y una velocidad de 9600 baudios; debe
ajustarse si cambian el reloj o la velocidad de comunicación.

## Verificación

`TP2_UART/tb/uart_tb.v` verifica el camino completo:

    PC -> UART RX -> interfaz -> ALU -> interfaz -> UART TX -> PC

El testbench envía una operación por la línea serie, recibe el resultado y lo
compara con un modelo de referencia independiente. Incluye pruebas para todas
las operaciones, desplazamientos aritméticos y lógicos, overflow y underflow,
opcodes inválidos y operaciones consecutivas. La simulación finaliza con un
veredicto `TEST PASSED` o `TEST FAILED`.

Para realizar una prueba desde una PC se puede utilizar `serial_comm.py`,
configurando previamente el puerto serie y la velocidad de comunicación según
la placa y el `DVSR` utilizado.
