`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// dmem
//
// Memoria de datos: 1024 palabras de 32 bits (docs/spec/memoria.md).
// Envuelve el IP dmem_bram (ip/dmem_bram.tcl) con los nombres de
// memoria.md §3.3 y suma la lógica de MEM que depende solo de la
// dirección y del tamaño del acceso: la máscara de bytes de los stores
// y los avisos de acceso (decisión 027).
//
// Función:
//   Puerto A (core, MEM):
//     - Índice de palabra = i_a_addr[DMEM_AW+1:2]. Los bits [31:12] y el
//       offset no llegan a la BRAM: un acceso fuera de rango cae en
//       addr mod 4096 y uno desalineado en la media palabra o palabra
//       alineada que lo contiene (memoria.md §6.1, decisión 015).
//     - Store (i_a_store = 1): máscara de bytes y dato replicado de
//       pipeline.md §6.2 (decisión 016):
//         sb: we = 0001 << offset,         wdata = {4{d[7:0]}}
//         sh: we = 0011 << {offset[1], 0}, wdata = {2{d[15:0]}}
//         sw: we = 1111,                   wdata = d
//       Un funct3 que no es sb ni sh escribe como sw, igual que
//       store_bytes del modelo de referencia (tools/isasim). No llega
//       nunca: control_unit convierte esos stores en NOP (decisión 024).
//     - Lectura: con i_a_en = 1 la BRAM lee la palabra en todos los
//       ciclos, haya load o no, como el modelo. En READ_FIRST, en el
//       ciclo de un store o_a_dout trae la palabra de antes.
//       o_a_dout es la palabra completa: la selección del byte o de la
//       media palabra y su extensión se hacen en WB (pipeline.md §7.1).
//     - Avisos persistentes (memoria.md §6.2): con i_a_en = 1 y un load
//       o un store, o_oob se pone en 1 si addr[31:12] != 0 y
//       o_misaligned si un lh/lhu/sh tiene addr[0] = 1 o un lw/sw tiene
//       addr[1:0] != 00. Quedan en 1 hasta i_rst (core_rst). Una burbuja
//       (i_a_store = i_a_load = 0) no los levanta.
//   Puerto B (Debug Unit): lectura para el volcado (i_b_we = 0000) y
//     escritura para la limpieza de LOAD y RESET (i_b_we = 1111, i_b_din
//     = 0, memoria.md §3.3). El banco de pruebas lo usa para cargar el
//     estado inicial. El core y la Debug Unit nunca usan los dos puertos
//     a la vez (memoria.md §3.5).
//
// Latencia y cómo la absorbe MEM (decisión 009, pipeline.md §6.3):
//   1 ciclo en los dos puertos, sin registro de salida extra. La
//   dirección sale de ex_mem_result (un registro) y el registro de
//   salida de la BRAM es mem_wb_read_data: el dato llega a WB junto con
//   los demás campos de MEM/WB sin agregar ciclos.
//     - Core detenido: i_a_en = en_mem_wb = enable (pipeline.md §10.4).
//       Con 0 la salida no cambia, no se escribe y los avisos no cambian.
//
// Contenido inicial: ceros, desde la configuración del IP (memoria.md
// §3.6).
//
// Puertos:
//   i_clk          : reloj del sistema (clka = clkb)
//   i_rst          : core_rst, síncrono, activo en alto. Borra los
//                    avisos y gana sobre i_a_en; no toca la memoria
//   i_a_en         : habilita el puerto A y los avisos (en_mem_wb)
//   i_a_addr       : dirección de byte, ex_mem_result         [31:0]
//   i_a_funct3     : tamaño del acceso, ex_mem_funct3         [2:0]
//   i_a_store      : store, ex_mem_mem_write
//   i_a_load       : load, ex_mem_mem_to_reg (solo para los avisos)
//   i_a_store_data : dato del store sin replicar,
//                    ex_mem_store_data                        [31:0]
//   o_a_dout       : palabra leída, mem_wb_read_data          [31:0]
//   o_oob          : aviso dmem_oob
//   o_misaligned   : aviso dmem_misaligned
//   i_b_en         : habilita el puerto B
//   i_b_we         : escritura por byte del puerto B          [3:0]
//   i_b_addr       : índice de palabra del puerto B           [9:0]
//   i_b_din        : palabra a escribir                       [31:0]
//   o_b_dout       : palabra leída por el puerto B            [31:0]
//
// Sin parámetros: el tamaño lo fija el IP (DMEM_AW = 10, memoria.md §8).
//
// Latencia: 1 ciclo (i_a_addr -> o_a_dout, i_b_addr -> o_b_dout,
//           i_a_* / i_b_* -> palabra escrita, i_a_* -> avisos).
// Reset   : o_oob = 0, o_misaligned = 0. La BRAM no se resetea.
//======================================================================

module dmem
(
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_a_en,
    input  wire [31:0] i_a_addr,
    input  wire [2:0]  i_a_funct3,
    input  wire        i_a_store,
    input  wire        i_a_load,
    input  wire [31:0] i_a_store_data,
    output wire [31:0] o_a_dout,
    output wire        o_oob,
    output wire        o_misaligned,
    input  wire        i_b_en,
    input  wire [3:0]  i_b_we,
    input  wire [9:0]  i_b_addr,
    input  wire [31:0] i_b_din,
    output wire [31:0] o_b_dout
);

    `include "riscv_defs.vh"

    localparam integer DMEM_AW = 10;   // 1024 palabras (memoria.md §1)
    localparam integer NB_DATA = 32;
    localparam integer NB_WE   = 4;    // un bit por byte
    localparam integer NB_BYTE = 8;
    localparam integer NB_HALF = 16;

    // Máscaras de escritura antes de desplazarlas al offset (§6.2)
    localparam [NB_WE-1:0] WE_NONE = 4'b0000;
    localparam [NB_WE-1:0] WE_BYTE = 4'b0001;
    localparam [NB_WE-1:0] WE_HALF = 4'b0011;
    localparam [NB_WE-1:0] WE_WORD = 4'b1111;

    // funct3[1:0] es el tamaño en loads y stores (isa.md); los avisos lo
    // miran así, como memoria.md §6.2 y el modelo
    localparam [1:0] SIZE_HALF = 2'b01;
    localparam [1:0] SIZE_WORD = 2'b10;

    wire [DMEM_AW-1:0] a_word   = i_a_addr[DMEM_AW+1:2];
    wire [1:0]         a_offset = i_a_addr[1:0];

    //------------------------------------------------------------------
    // Store: máscara de bytes y dato replicado (pipeline.md §6.2)
    //------------------------------------------------------------------
    reg  [NB_WE-1:0]   a_we_size;
    reg  [NB_DATA-1:0] a_din;
    wire [NB_WE-1:0]   a_we = i_a_store ? a_we_size : WE_NONE;

    always @(*) begin
        case (i_a_funct3)
            FUNCT3_SB: begin
                a_we_size = WE_BYTE << a_offset;
                a_din     = {(NB_DATA/NB_BYTE){i_a_store_data[NB_BYTE-1:0]}};
            end
            FUNCT3_SH: begin
                a_we_size = WE_HALF << {a_offset[1], 1'b0};
                a_din     = {(NB_DATA/NB_HALF){i_a_store_data[NB_HALF-1:0]}};
            end
            default: begin      // FUNCT3_SW
                a_we_size = WE_WORD;
                a_din     = i_a_store_data;
            end
        endcase
    end

    //------------------------------------------------------------------
    // Avisos de acceso (memoria.md §6.2). En MEM la instrucción ya no
    // puede ser anulada: los saltos solo hacen flush de IF/ID e ID/EX
    //------------------------------------------------------------------
    wire a_access = i_a_store | i_a_load;               // burbuja: 0
    wire a_oob    = |i_a_addr[31:DMEM_AW+2];
    wire a_mis    = ((i_a_funct3[1:0] == SIZE_HALF) &  a_offset[0])
                  | ((i_a_funct3[1:0] == SIZE_WORD) & |a_offset);

    reg  oob_reg;
    reg  misaligned_reg;
    wire oob_next        = oob_reg        | (i_a_en & a_access & a_oob);
    wire misaligned_next = misaligned_reg | (i_a_en & a_access & a_mis);

    always @(posedge i_clk) begin
        if (i_rst) begin
            oob_reg        <= 1'b0;
            misaligned_reg <= 1'b0;
        end
        else begin
            oob_reg        <= oob_next;
            misaligned_reg <= misaligned_next;
        end
    end

    assign o_oob        = oob_reg;
    assign o_misaligned = misaligned_reg;

    //------------------------------------------------------------------
    // BRAM
    //------------------------------------------------------------------
    dmem_bram u_dmem_bram (
        .clka  (i_clk),
        .ena   (i_a_en),
        .wea   (a_we),
        .addra (a_word),
        .dina  (a_din),
        .douta (o_a_dout),
        .clkb  (i_clk),
        .enb   (i_b_en),
        .web   (i_b_we),
        .addrb (i_b_addr),
        .dinb  (i_b_din),
        .doutb (o_b_dout)
    );

endmodule

`default_nettype wire
