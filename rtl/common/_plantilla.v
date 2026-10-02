`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// _plantilla
//
// Plantilla de módulo según docs/decisiones/009_convenciones-rtl.md.
// Copiar a <carpeta>/<nombre_modulo>.v, renombrar el módulo igual que
// el archivo y reemplazar el ejemplo (un registro con enable).
// Los archivos que empiezan con "_" no se agregan al proyecto de Vivado.
//
// Función:
//   Registra i_data cuando i_valid está en alto y lo mantiene en o_data.
//   o_valid indica que o_data cambió en el ciclo anterior.
//
// Parámetros:
//   NB_DATA : ancho del dato
//
// Puertos:
//   i_clk   : reloj del sistema
//   i_rst   : reset síncrono, activo en alto
//   i_valid : i_data es válido en este ciclo
//   i_data  : dato de entrada            [NB_DATA-1:0]
//   o_valid : pulso de un ciclo, o_data se actualizó
//   o_data  : dato registrado            [NB_DATA-1:0]
//
// Latencia: 1 ciclo (i_data -> o_data).
// Reset   : o_data = 0, o_valid = 0.
//======================================================================

module _plantilla
#(
    parameter integer NB_DATA = 32
)
(
    input  wire               i_clk,
    input  wire               i_rst,
    input  wire               i_valid,
    input  wire [NB_DATA-1:0] i_data,
    output wire               o_valid,
    output wire [NB_DATA-1:0] o_data
);

    localparam [NB_DATA-1:0] DATA_RST = {NB_DATA{1'b0}};

    reg  [NB_DATA-1:0] data_reg;
    reg  [NB_DATA-1:0] data_next;
    reg                valid_reg;

    // Secuencial: solo asignaciones no bloqueantes, reset síncrono
    always @(posedge i_clk) begin
        if (i_rst) begin
            data_reg  <= DATA_RST;
            valid_reg <= 1'b0;
        end
        else begin
            data_reg  <= data_next;
            valid_reg <= i_valid;
        end
    end

    // Combinacional: asignación por defecto al principio para no inferir latches
    always @(*) begin
        data_next = data_reg;
        if (i_valid)
            data_next = i_data;
    end

    assign o_data  = data_reg;
    assign o_valid = valid_reg;

endmodule

`default_nettype wire
