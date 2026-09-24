# Arquitectura de Computadoras

Trabajos prácticos de **Arquitectura de Computadoras** (FCEFyN, UNC).

Se desarrollan en Verilog los bloques de un procesador, implementados y verificados
sobre una **Basys 3** (Artix-7 `xc7a35tcpg236-1`) con **Vivado**. Todo converge en el
trabajo final: un **procesador RISC-V segmentado de 5 etapas** (IF, ID, EX, MEM, WB)
con una **Debug Unit** por UART y una interfaz en la PC para programarlo y observarlo.

## Integrantes

- Costamagna, Matías
- Moreyra, Julián

## Estructura

```
rtl/                     Diseño sintetizable
├── common/              alu, debouncer, y bloques reutilizables
├── peripherals/uart/    UART: baud generator, tx, rx, FSM, buffers
├── debug/               Debug Unit (comandos por UART, lectura de regs/latches/memoria)
├── pipeline/            Etapas y registros de segmentación (IF/ID/EX/MEM/WB)
├── control/             Unidad de control, forwarding, detección de riesgos
└── memory/              Memoria de programa (escribible por UART) y de datos
ip/                      Scripts Tcl que generan los IP cores (Clock Wizard, BRAM)
fpga/                    Un directorio por diseño: top.v + basys3.xdc
├── tp1_alu/
├── tp2_uart/
└── riscv_basys3/        Diseño del trabajo final
tb/
├── unit/                Un testbench por módulo
└── integration/         Core completo ejecutando programas de sw/
sw/                      Programas en ensamblador (con HALT) y su resultado esperado
tools/
├── assembler/           Traductor asm -> código máquina
└── debugger/            Cliente UART e interfaz (CLI/TUI/GUI)
scripts/                 create_project.tcl
docs/
├── spec/                ISA soportada, protocolo de debug, diseño del pipeline
├── decisiones/          Una nota por decisión de diseño y su porqué
├── timing/              Camino crítico, skew, frecuencia elegida, reportes de Vivado
├── diagramas/
└── tps/                 Informes de TP1, TP2, ...
```

## Abrir el proyecto en Vivado

El proyecto de Vivado (`.xpr`) **no se versiona**: se regenera desde las fuentes.

1. En Vivado: **Tools > Run Tcl Script...** y elegir `scripts/create_project.tcl`
   (por defecto crea `riscv_basys3`).
2. Para otro diseño, en la Tcl Console:
   ```tcl
   set DESIGN tp2_uart
   source <ruta-al-repo>/scripts/create_project.tcl
   ```
3. El proyecto queda en `build/vivado_<diseño>/`, carpeta ignorada por git.

Al agregar o mover archivos `.v` en `rtl/`, volvé a correr el script (o usá
*Add Sources* apuntando a la carpeta). El código siempre se edita en el repo, no
dentro de la carpeta `build/`.

## Flujo de trabajo

- `master` siempre debe sintetizar y simular sin errores.
- El trabajo va en ramas `feature/<tema>` o `fix/<tema>` y entra por pull request
  revisado por el otro integrante.
- Prefijos de commit: `rtl:`, `tb:`, `sw:`, `tools:`, `docs:`, `chore:`.
- Cada hito se marca con un tag (`tp1`, `tp2`, `pipeline-v1`, ...).
- Antes de escribir un módulo se documenta su interfaz en `docs/spec/`; toda decisión
  de diseño va en `docs/decisiones/`.

## Hoja de ruta

1. [x] TP1: ALU
2. [x] TP2: UART
3. [ ] Especificación: ISA, protocolo de debug, diagrama del pipeline (`docs/spec/`)
4. [ ] Ensamblador (`tools/assembler/`)
5. [ ] Etapas del pipeline + registros de segmentación
6. [ ] Forwarding y detección de riesgos
7. [ ] Memoria de programa por UART + Debug Unit
8. [ ] Interfaz de debug en la PC
9. [ ] Integración, análisis de camino crítico y Clock Wizard
