# fpga/

Un subdirectorio por **diseño sintetizable** para la Basys 3. Cada uno contiene su
módulo superior (`top.v`), los módulos que solo ese diseño necesita y su archivo de
constraints (`basys3.xdc`). Los bloques reutilizables no están acá: viven en `../rtl/`.

| Diseño | Estado | Qué es |
|---|---|---|
| `riscv_basys3/` | **vigente** | Trabajo final: procesador RISC-V segmentado + Debug Unit + Clock Wizard |
| `tp2_uart/` | histórico | TP2: ALU operada a través de UART (`top.v` + `alu_top.v`) |
| `tp1_alu/` | histórico | TP1: ALU con entradas por switches/botones y antirrebote |

Los diseños históricos se conservan como referencia y para poder reproducir lo entregado.
No se modifican salvo para corregir errores.

## Abrir un diseño en Vivado

En Vivado, *Tools > Run Tcl Script...* con `scripts/create_project.tcl` (crea `riscv_basys3`).
Para otro diseño, en la Tcl Console:

```tcl
set DESIGN tp2_uart
source <ruta-al-repo>/scripts/create_project.tcl
```

El proyecto se genera en `build/vivado_<diseño>/` (ignorado por git). El nombre de
`DESIGN` es el de la carpeta de este directorio.

## Convenciones para agregar un diseño

- El módulo superior se llama `top` (el script de proyecto lo asume).
- Un solo `basys3.xdc` por diseño, con los pines usados y las constraints de clock.
- Si un módulo lo van a usar dos diseños, va en `rtl/`, no acá.
