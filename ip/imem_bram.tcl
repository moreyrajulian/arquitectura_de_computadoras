# ---------------------------------------------------------------------------
# imem_bram: memoria de programa (docs/spec/memoria.md §3.2, decisiones 014 y 022).
#
# Block Memory Generator, True Dual Port, 1024 x 32, una RAMB36E1:
#   puerto A: IF (solo lectura), ena = en_if_id
#   puerto B: Debug Unit (solo escritura, LOAD)
# Sin registros de salida: latencia de lectura de 1 ciclo (decisión 009).
# Sin pines RSTA/RSTB (decisión 022).
# Contenido inicial: HALT (0x0010_0073) en las 1024 palabras, sin archivo .coe
# (memoria.md §3.6, decisión 022).
#
# Lo ejecuta scripts/create_project.tcl con el proyecto ya abierto.
# El rtl/memory/imem.v lo envuelve; el resto del RTL no usa estos nombres.
# ---------------------------------------------------------------------------
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name imem_bram
set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Write_Width_A {32} CONFIG.Read_Width_A {32} CONFIG.Write_Depth_A {1024} \
    CONFIG.Write_Width_B {32} CONFIG.Read_Width_B {32} \
    CONFIG.Enable_A {Use_ENA_Pin} CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.Use_RSTA_Pin {false} CONFIG.Use_RSTB_Pin {false} \
    CONFIG.Load_Init_File {false} \
    CONFIG.Fill_Remaining_Memory_Locations {true} \
    CONFIG.Remaining_Memory_Locations {00100073} \
] [get_ips imem_bram]
