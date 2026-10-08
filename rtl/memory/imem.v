`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// imem
//
// Memoria de programa: 1024 palabras de 32 bits (docs/spec/memoria.md).
// Envuelve el IP imem_bram (ip/imem_bram.tcl) con los nombres de
// memoria.md §3.3, para que el pipeline no dependa de los nombres que
// genera el Block Memory Generator.
//
// Función:
//   Puerto A (core, IF): solo lectura. Recibe el PC completo y usa
//     pc[IMEM_AW+1:2] como índice de palabra; los bits [31:12] y [1:0]
//     se ignoran, así que un PC fuera de rango lee su alias
//     imem[pc mod 4096] (memoria.md §6.1). wea y dina quedan en 0.
//   Puerto B (Debug Unit, LOAD): solo escritura de una palabra por ciclo
//     con i_b_en = i_b_we = 1 (memoria.md §4). doutb queda sin conectar.
//   El core y la Debug Unit nunca usan los dos puertos a la vez
//   (memoria.md §3.5).
//
// Latencia y cómo la absorbe IF (decisión 009, pipeline.md §3.2-§3.3):
//   1 ciclo, sin registro de salida extra. La dirección sale de pc_reg
//   (un registro) y el registro de salida de la BRAM es if_id_instr:
//   la instrucción llega a ID junto con if_id_pc sin agregar ciclos.
//     - Stall / core detenido: i_a_en = en_if_id; con 0 la salida no cambia.
//     - Flush y reset: la salida no se borra; if_id_valid = 0 la anula
//       (decisión 022: sin pin de reset de la BRAM).
//
// Contenido inicial: HALT (0x0010_0073) en las 1024 palabras, desde la
// configuración del IP (memoria.md §3.6, decisión 022).
//
// Puertos:
//   i_clk    : reloj del sistema (clka = clkb)
//   i_a_en   : habilita el puerto A (en_if_id)
//   i_a_addr : dirección de byte, pc_reg                   [31:0]
//   o_a_dout : palabra leída, if_id_instr                  [31:0]
//   i_b_en   : habilita el puerto B
//   i_b_we   : escritura por el puerto B
//   i_b_addr : índice de palabra del puerto B              [9:0]
//   i_b_din  : palabra a escribir                          [31:0]
//
// Sin parámetros: el tamaño lo fija el IP (IMEM_AW = 10, memoria.md §8).
//
// Latencia: 1 ciclo (i_a_addr -> o_a_dout; i_b_* -> palabra escrita).
// Reset   : no tiene. La BRAM no se resetea; ver "Flush y reset".
//======================================================================

module imem
(
    input  wire        i_clk,
    input  wire        i_a_en,
    input  wire [31:0] i_a_addr,
    output wire [31:0] o_a_dout,
    input  wire        i_b_en,
    input  wire        i_b_we,
    input  wire [9:0]  i_b_addr,
    input  wire [31:0] i_b_din
);

    localparam integer IMEM_AW = 10;   // 1024 palabras (memoria.md §1)
    localparam integer NB_DATA = 32;

    wire [IMEM_AW-1:0] a_word = i_a_addr[IMEM_AW+1:2];

    imem_bram u_imem_bram (
        .clka  (i_clk),
        .ena   (i_a_en),
        .wea   (1'b0),
        .addra (a_word),
        .dina  ({NB_DATA{1'b0}}),
        .douta (o_a_dout),
        .clkb  (i_clk),
        .enb   (i_b_en),
        .web   (i_b_we),
        .addrb (i_b_addr),
        .dinb  (i_b_din),
        .doutb ()
    );

endmodule

`default_nettype wire
