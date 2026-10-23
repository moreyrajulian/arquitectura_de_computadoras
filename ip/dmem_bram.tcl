# ---------------------------------------------------------------------------
# dmem_bram: memoria de datos (docs/spec/memoria.md §3.2, decisiones 014, 016 y 027).
#
# Block Memory Generator, True Dual Port, 1024 x 32, una RAMB36E1:
#   puerto A: MEM (lectura y escritura por byte), ena = en_mem_wb
#   puerto B: Debug Unit (lectura para el volcado, escritura de ceros al limpiar)
# Byte write enable de 8 bits: wea[3:0] y web[3:0] (sb y sh, decisión 016).
# Puerto A en READ_FIRST: en el ciclo de un store douta trae la palabra que
# había antes, como el modelo de referencia. El modo del puerto B queda por
# defecto: la Debug Unit nunca lee y escribe la misma dirección en un ciclo.
# Sin registros de salida: latencia de lectura de 1 ciclo (decisión 009).
# Sin pines RSTA/RSTB: la BRAM no se resetea.
# Contenido inicial: ceros, sin archivo .coe (memoria.md §3.6, decisión 021).
# Los testbenches cargan la memoria por el puerto B.
#
# Lo ejecuta scripts/create_project.tcl con el proyecto ya abierto.
# El rtl/memory/dmem.v lo envuelve; el resto del RTL no usa estos nombres.
# ---------------------------------------------------------------------------
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name dmem_bram
set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Write_Width_A {32} CONFIG.Read_Width_A {32} CONFIG.Write_Depth_A {1024} \
    CONFIG.Write_Width_B {32} CONFIG.Read_Width_B {32} \
    CONFIG.Enable_A {Use_ENA_Pin} CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Use_Byte_Write_Enable {true} CONFIG.Byte_Size {8} \
    CONFIG.Operating_Mode_A {READ_FIRST} \
    CONFIG.Use_RSTA_Pin {false} CONFIG.Use_RSTB_Pin {false} \
    CONFIG.Load_Init_File {false} \
    CONFIG.Fill_Remaining_Memory_Locations {false} \
] [get_ips dmem_bram]
