`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// regfile
//
// Banco de registros x0..x31 de la etapa ID (docs/spec/pipeline.md §4.2,
// decisión 007).
//
// Función:
//   32 registros de NB_DATA bits en flip-flops, con dos puertos de
//   lectura asíncronos para ID (rs1, rs2), un puerto de escritura en el
//   flanco de subida manejado por WB y un tercer puerto de lectura para
//   el dump de la Debug Unit (protocolo_debug.md §7).
//   - x0 vale siempre 0: los tres puertos lo leen como 0 y una escritura
//     con rd = 0 se ignora.
//   - Escritura: we = i_we & i_en (decisión 018). Con el core detenido
//     los registros no se adelantan al pipeline.
//   - Bypass WB -> ID (decisión 007): si WB escribe el registro que lee
//     un puerto de ID, ese puerto entrega i_rd_data en el mismo ciclo.
//     La condición usa i_we (wb_reg_write) sin i_en, como la fórmula de
//     §4.2: con i_en = 0 ID/EX no carga, así que no hay diferencia
//     visible, y el enable (fanout alto) queda fuera del mux de lectura.
//   - El puerto de debug lee el valor guardado, sin bypass: con el core
//     detenido, una instrucción retenida en MEM/WB todavía no escribió,
//     y el dump tiene que mostrarlo así (decisión 018).
//   - Reset a cero de los 32 registros, con prioridad sobre i_en: es lo
//     que usan LOAD y RESET para vaciar el banco (decisiones 004 y 007).
//     Es la excepción a "no resetear caminos de datos" de la decisión
//     010; en 7-series usa la entrada R nativa del flip-flop.
//   El arreglo se llama regs: el banco de pruebas incremental lo carga y
//   lo lee por jerarquía (`REGFILE, decisión 021), después de soltar el
//   reset. No hay $readmemh: el reset borraría ese contenido.
//
// Parámetros:
//   NB_DATA : ancho de cada registro
//   NB_ADDR : ancho del número de registro (2**NB_ADDR registros)
//
// Puertos:
//   i_clk          : reloj del sistema
//   i_rst          : reset síncrono, activo en alto (core_rst); gana sobre i_en
//   i_en           : enable global del core (decisión 018); en 0 no escribe
//   i_rs1_addr     : rs1, número del primer registro fuente   [NB_ADDR-1:0]
//   i_rs2_addr     : rs2, número del segundo registro fuente  [NB_ADDR-1:0]
//   o_rs1_data     : valor de rs1, con bypass (id_rs1_data)   [NB_DATA-1:0]
//   o_rs2_data     : valor de rs2, con bypass (id_rs2_data)   [NB_DATA-1:0]
//   i_we           : wb_reg_write, WB escribe rd
//   i_rd_addr      : wb_rd, registro destino                  [NB_ADDR-1:0]
//   i_rd_data      : wb_data, valor a escribir                [NB_DATA-1:0]
//   i_dbg_reg_addr : registro que lee la Debug Unit           [NB_ADDR-1:0]
//   o_dbg_reg_data : valor guardado, sin bypass               [NB_DATA-1:0]
//
// Latencia: lecturas combinacionales (0 ciclos); la escritura se ve en
//           los puertos de lectura en el mismo ciclo por el bypass y en
//           el puerto de debug desde el ciclo siguiente.
// Reset   : los 32 registros en 0.
//======================================================================

module regfile
#(
    parameter integer NB_DATA = 32,
    parameter integer NB_ADDR = 5
)
(
    input  wire               i_clk,
    input  wire               i_rst,
    input  wire               i_en,
    input  wire [NB_ADDR-1:0] i_rs1_addr,
    input  wire [NB_ADDR-1:0] i_rs2_addr,
    output wire [NB_DATA-1:0] o_rs1_data,
    output wire [NB_DATA-1:0] o_rs2_data,
    input  wire               i_we,
    input  wire [NB_ADDR-1:0] i_rd_addr,
    input  wire [NB_DATA-1:0] i_rd_data,
    input  wire [NB_ADDR-1:0] i_dbg_reg_addr,
    output wire [NB_DATA-1:0] o_dbg_reg_data
);

    localparam integer       N_REGS    = 1 << NB_ADDR;
    localparam [NB_ADDR-1:0] REG_ZERO  = {NB_ADDR{1'b0}};   // x0
    localparam [NB_DATA-1:0] DATA_ZERO = {NB_DATA{1'b0}};

    // Flip-flops y no LUTRAM: tercer puerto de lectura y reset en un
    // ciclo (decisión 007)
    (* ram_style = "registers" *)
    reg [NB_DATA-1:0] regs [0:N_REGS-1];

    integer k;

    // Escritura: reset > enable (decisión 018); rd = 0 no escribe
    always @(posedge i_clk) begin
        if (i_rst) begin
            for (k = 0; k < N_REGS; k = k + 1)
                regs[k] <= DATA_ZERO;
        end
        else if (i_en && i_we && (i_rd_addr != REG_ZERO))
            regs[i_rd_addr] <= i_rd_data;
    end

    // Lectura de ID con bypass (pipeline.md §4.2); el bypass nunca actúa
    // sobre x0 porque la primera condición ya lo devuelve en 0
    assign o_rs1_data = (i_rs1_addr == REG_ZERO)              ? DATA_ZERO :
                        (i_we && (i_rd_addr == i_rs1_addr))   ? i_rd_data :
                                                                regs[i_rs1_addr];

    assign o_rs2_data = (i_rs2_addr == REG_ZERO)              ? DATA_ZERO :
                        (i_we && (i_rd_addr == i_rs2_addr))   ? i_rd_data :
                                                                regs[i_rs2_addr];

    // Lectura de la Debug Unit: valor guardado, sin bypass
    assign o_dbg_reg_data = (i_dbg_reg_addr == REG_ZERO) ? DATA_ZERO :
                                                           regs[i_dbg_reg_addr];

endmodule

`default_nettype wire
