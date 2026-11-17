`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// debug_dump
//
// Volcado de estado de la Debug Unit (I-48, decisión 039,
// docs/spec/protocolo_debug.md §3.6 y §7, memoria.md §7).
//
// Función:
//   Arma el payload de READ_REGS, READ_LATCHES, READ_DMEM, READ_DMEM_USED
//   y READ_ALL: debug_unit pide cada byte con i_pl_idx, y este módulo lo
//   entrega en o_pl_byte con o_pl_ready = 1. En READ_ALL los bytes 0 a 11
//   (el bloque de estado) son de debug_unit, y desde el 12 se resta
//   DBG_LEN_STATUS. Las fuentes, en el orden del payload:
//     registros  x0 … x31, 4 bytes cada uno, little-endian, por el puerto
//                de lectura del banco (o_dbg_reg_addr, asíncrono).
//     latches    IF/ID, ID/EX, EX/MEM y MEM/WB: cada bus partido en
//                ceil(NB / 32) palabras de 32 bits, la palabra 0 con los
//                bits [31:0], cada una little-endian; el relleno vale 0.
//     READ_DMEM  count palabras desde i_arg_addr (ya validada por
//                debug_unit), por el puerto B de dmem.
//     pares      (addr = 4a, valor = dmem[a]) de cada palabra a marcada
//                en el mapa, en orden creciente. El mapa (debug_used_map)
//                busca la primera con el i_cmd_valid de READ_DMEM_USED o
//                READ_ALL, y la siguiente cuando el índice pasa al par
//                siguiente; mientras busca, o_pl_ready = 0. Si la búsqueda
//                llega al final sin encontrarla (el mapa y el contador no
//                coinciden; con el RTL no pasa), entrega ceros en lugar de
//                dejar a debug_unit esperando.
//   El byte sale de un registro, junto con el índice para el que se
//   calculó: o_pl_ready = 1 cuando ese índice es i_pl_idx y la fuente
//   estaba lista.
//   Mapa de palabras usadas: debug_used_map, con las marcas del core
//   (i_dmem_we, i_dmem_addr) y el borrado de CLEAR (i_used_clr con
//   i_du_dmem_b_addr). o_dmem_used va al bloque de estado.
//   Puerto B de dmem: un multiplexor elige el de debug_unit cuando
//   i_du_dmem_b_en = 1 (CLEAR) y, si no, las lecturas (we = 0000). Solo lee
//   entre el i_cmd_valid de una lectura y el del comando siguiente, con el
//   core detenido (memoria.md §3.5).
//
// Parámetros:
//   DMEM_WORDS  : palabras de dmem (1024)
//   NB_MEM_ADDR : bits del índice de palabra de dmem (10)
//   NB_*_LATCH  : bits de cada bus de latch (pipeline.md §8, decisión 023);
//                 los mismos que en debug_unit
//   NB_BYTE, NB_WORD, NB_LEN : anchos fijos del protocolo (8, 32 y 16)
//   NB_REG_ADDR : bits del número de registro (5)
//
// Puertos:
//   i_clk            : reloj del sistema
//   i_rst            : reset del sistema, síncrono, activo en alto
//   i_cmd_valid      : o_cmd_valid de debug_unit
//   i_cmd            : o_cmd de debug_unit                 [NB_BYTE-1:0]
//   i_arg_addr       : addr de READ_DMEM (o_arg_addr)      [NB_WORD-1:0]
//   i_pl_idx         : o_pl_idx de debug_unit              [NB_LEN-1:0]
//   o_pl_byte        : byte i_pl_idx del payload           [NB_BYTE-1:0]
//   o_pl_ready       : o_pl_byte es el byte de i_pl_idx
//   o_dmem_used      : palabras marcadas, a i_dmem_used    [NB_LEN-1:0]
//   i_du_dmem_b_en,
//   i_du_dmem_b_we,
//   i_du_dmem_b_addr,
//   i_du_dmem_b_din  : puerto B de dmem de debug_unit (CLEAR)
//   i_used_clr       : o_used_clr de debug_unit: borrar i_du_dmem_b_addr
//   o_dmem_b_en      : puerto B de dmem del core: habilita
//   o_dmem_b_we      : escritura por byte                  [3:0]
//   o_dmem_b_addr    : índice de palabra                   [NB_MEM_ADDR-1:0]
//   o_dmem_b_din     : palabra a escribir                  [NB_WORD-1:0]
//   i_dmem_b_dout    : palabra leída, un ciclo después     [NB_WORD-1:0]
//   i_dmem_we        : o_dmem_we del core: un store escribe dmem
//   i_dmem_addr      : o_dmem_addr del core                [NB_MEM_ADDR-1:0]
//   o_dbg_reg_addr   : registro que se lee                 [NB_REG_ADDR-1:0]
//   i_dbg_reg_data   : su valor                            [NB_WORD-1:0]
//   i_if_id_latch,
//   i_id_ex_latch,
//   i_ex_mem_latch,
//   i_mem_wb_latch   : buses de latch del core             [NB_*_LATCH-1:0]
//
// Latencia: o_pl_ready = 1 un ciclo después de que cambia i_pl_idx en los
//           registros y los latches, y dos en READ_DMEM y en el valor de un
//           par (la BRAM). La dirección de un par, cuando el mapa encontró
//           la palabra: hasta DMEM_WORDS + 1 ciclos después del i_cmd_valid
//           o del primer byte del par.
// Reset   : sin lectura en curso, o_pl_ready = 0, o_dmem_used = 0. Los
//           registros de datos no se resetean.
//======================================================================

module debug_dump
#(
    parameter integer DMEM_WORDS      = 1024,
    parameter integer NB_MEM_ADDR     = 10,
    parameter integer NB_IF_ID_LATCH  = 65,
    parameter integer NB_ID_EX_LATCH  = 161,
    parameter integer NB_EX_MEM_LATCH = 109,
    parameter integer NB_MEM_WB_LATCH = 110,
    parameter integer NB_BYTE         = 8,
    parameter integer NB_WORD         = 32,
    parameter integer NB_LEN          = 16,
    parameter integer NB_REG_ADDR     = 5
)
(
    input  wire                       i_clk,
    input  wire                       i_rst,
    // debug_unit
    input  wire                       i_cmd_valid,
    input  wire [NB_BYTE-1:0]         i_cmd,
    input  wire [NB_WORD-1:0]         i_arg_addr,
    input  wire [NB_LEN-1:0]          i_pl_idx,
    output wire [NB_BYTE-1:0]         o_pl_byte,
    output wire                       o_pl_ready,
    output wire [NB_LEN-1:0]          o_dmem_used,
    input  wire                       i_du_dmem_b_en,
    input  wire [3:0]                 i_du_dmem_b_we,
    input  wire [NB_MEM_ADDR-1:0]     i_du_dmem_b_addr,
    input  wire [NB_WORD-1:0]         i_du_dmem_b_din,
    input  wire                       i_used_clr,
    // Puerto B de dmem (core)
    output wire                       o_dmem_b_en,
    output wire [3:0]                 o_dmem_b_we,
    output wire [NB_MEM_ADDR-1:0]     o_dmem_b_addr,
    output wire [NB_WORD-1:0]         o_dmem_b_din,
    input  wire [NB_WORD-1:0]         i_dmem_b_dout,
    // Core: marcas del mapa, banco de registros y latches
    input  wire                       i_dmem_we,
    input  wire [NB_MEM_ADDR-1:0]     i_dmem_addr,
    output wire [NB_REG_ADDR-1:0]     o_dbg_reg_addr,
    input  wire [NB_WORD-1:0]         i_dbg_reg_data,
    input  wire [NB_IF_ID_LATCH-1:0]  i_if_id_latch,
    input  wire [NB_ID_EX_LATCH-1:0]  i_id_ex_latch,
    input  wire [NB_EX_MEM_LATCH-1:0] i_ex_mem_latch,
    input  wire [NB_MEM_WB_LATCH-1:0] i_mem_wb_latch
);

    `include "riscv_defs.vh"

    //------------------------------------------------------------------
    // Constantes
    //------------------------------------------------------------------
    // Latches partidos en palabras de 32 bits (§3.6)
    localparam integer NB_IF_ID_PAD  = 32 * ((NB_IF_ID_LATCH  + 31) / 32);
    localparam integer NB_ID_EX_PAD  = 32 * ((NB_ID_EX_LATCH  + 31) / 32);
    localparam integer NB_EX_MEM_PAD = 32 * ((NB_EX_MEM_LATCH + 31) / 32);
    localparam integer NB_MEM_WB_PAD = 32 * ((NB_MEM_WB_LATCH + 31) / 32);
    localparam integer NB_LAT_ALL    = NB_IF_ID_PAD + NB_ID_EX_PAD + NB_EX_MEM_PAD + NB_MEM_WB_PAD;
    localparam [NB_LEN-1:0] LEN_LATCHES = NB_LAT_ALL / 8;

    // Offsets del payload, sin el bloque de estado de READ_ALL
    localparam [NB_LEN-1:0] OFF_LATCHES = DBG_LEN_REGS;
    localparam [NB_LEN-1:0] OFF_PAIRS   = DBG_LEN_REGS + LEN_LATCHES;

    localparam integer NB_COUNT = $clog2(DMEM_WORDS + 1);
    localparam integer NB_PAIR  = NB_LEN - 3;             // 8 bytes por par

    //------------------------------------------------------------------
    // Registros
    //------------------------------------------------------------------
    reg                   active_reg,  active_next;   // entre una lectura y el comando siguiente
    reg [NB_PAIR-1:0]     pair_reg,    pair_next;     // par que tiene el mapa
    reg                   rd_ok_reg;                  // i_dmem_b_dout es de rd_addr_reg
    reg [NB_MEM_ADDR-1:0] rd_addr_reg;
    reg                   ok_reg;                     // byte_reg vale para tag_reg
    reg [NB_BYTE-1:0]     byte_reg;
    reg [NB_LEN-1:0]      tag_reg;

    //------------------------------------------------------------------
    // Comando y región del payload
    //------------------------------------------------------------------
    wire is_regs  = (i_cmd == DBG_CMD_READ_REGS);
    wire is_lat   = (i_cmd == DBG_CMD_READ_LATCHES);
    wire is_dmem  = (i_cmd == DBG_CMD_READ_DMEM);
    wire is_used  = (i_cmd == DBG_CMD_READ_DMEM_USED);
    wire is_all   = (i_cmd == DBG_CMD_READ_ALL);
    wire is_read  = is_regs | is_lat | is_dmem | is_used | is_all;

    // En READ_ALL, los bytes 0 a 11 son de debug_unit
    wire               all_ext = is_all & (i_pl_idx >= DBG_LEN_STATUS);
    wire [NB_LEN-1:0]  off     = is_all ? (i_pl_idx - DBG_LEN_STATUS) : i_pl_idx;

    wire rgn_regs = is_regs | (all_ext & (off < OFF_LATCHES));
    wire rgn_lat  = is_lat  | (all_ext & (off >= OFF_LATCHES) & (off < OFF_PAIRS));
    wire rgn_dmem = is_dmem;
    wire rgn_used = is_used | (all_ext & (off >= OFF_PAIRS));

    wire [NB_LEN-1:0]  lat_off  = is_lat  ? off : (off - OFF_LATCHES);
    wire [NB_LEN-1:0]  used_off = is_used ? off : (off - OFF_PAIRS);
    wire [NB_PAIR-1:0] pair     = used_off[NB_LEN-1:3];
    wire               pair_val = used_off[2];             // bytes 4 a 7: el valor

    //------------------------------------------------------------------
    // Mapa de palabras usadas
    //------------------------------------------------------------------
    wire                   map_busy;
    wire                   map_found;
    wire [NB_MEM_ADDR-1:0] map_addr;
    wire [NB_COUNT-1:0]    map_count;

    wire find_first = i_cmd_valid & (is_used | is_all) & (map_count != {NB_COUNT{1'b0}});
    wire pair_ok    = ~map_busy & ((pair == pair_reg) | ~map_found);
    wire find_next  = active_reg & rgn_used & ~map_busy & map_found & ~i_cmd_valid &
                      (pair == pair_reg + 1'b1);

    debug_used_map #(
        .DMEM_WORDS  (DMEM_WORDS),
        .NB_MEM_ADDR (NB_MEM_ADDR),
        .NB_COUNT    (NB_COUNT)
    ) u_used_map (
        .i_clk        (i_clk),
        .i_rst        (i_rst),
        .i_mark       (i_dmem_we),
        .i_mark_addr  (i_dmem_addr),
        .i_clr        (i_used_clr),
        .i_clr_addr   (i_du_dmem_b_addr),
        .i_find_first (find_first),
        .i_find_next  (find_next),
        .o_busy       (map_busy),
        .o_found      (map_found),
        .o_addr       (map_addr),
        .o_count      (map_count)
    );

    //------------------------------------------------------------------
    // Puerto B de dmem: CLEAR de debug_unit o las lecturas
    //------------------------------------------------------------------
    wire [NB_MEM_ADDR-1:0] dmem_word = i_arg_addr[NB_MEM_ADDR+1:2] + off[NB_MEM_ADDR+1:2];
    wire [NB_MEM_ADDR-1:0] rd_addr   = rgn_dmem ? dmem_word : map_addr;
    wire                   rd_en     = active_reg & (rgn_dmem | rgn_used) & ~i_du_dmem_b_en;
    wire                   rd_ok     = rd_ok_reg & (rd_addr_reg == rd_addr);

    //------------------------------------------------------------------
    // Byte de cada fuente
    //------------------------------------------------------------------
    // Los buses rellenos con ceros hasta su última palabra (la asignación
    // extiende con ceros)
    wire [NB_IF_ID_PAD-1:0]  if_id_pad  = i_if_id_latch;
    wire [NB_ID_EX_PAD-1:0]  id_ex_pad  = i_id_ex_latch;
    wire [NB_EX_MEM_PAD-1:0] ex_mem_pad = i_ex_mem_latch;
    wire [NB_MEM_WB_PAD-1:0] mem_wb_pad = i_mem_wb_latch;
    wire [NB_LAT_ALL-1:0]    lat_all    = {mem_wb_pad, ex_mem_pad, id_ex_pad, if_id_pad};

    wire [NB_BYTE-1:0] reg_byte  = i_dbg_reg_data[8*off[1:0] +: 8];
    wire [NB_BYTE-1:0] lat_byte  = lat_all[8*lat_off +: 8];
    wire [NB_BYTE-1:0] dmem_byte = i_dmem_b_dout[8*off[1:0] +: 8];
    wire [NB_WORD-1:0] pair_addr = {{(NB_WORD-NB_MEM_ADDR-2){1'b0}}, map_addr, 2'b00};
    wire [NB_BYTE-1:0] addr_byte = pair_addr[8*off[1:0] +: 8];

    reg               src_ok;
    reg [NB_BYTE-1:0] src_byte;

    always @(*) begin
        src_ok   = 1'b0;
        src_byte = {NB_BYTE{1'b0}};
        if (rgn_regs) begin
            src_ok   = 1'b1;
            src_byte = reg_byte;
        end
        else if (rgn_lat) begin
            src_ok   = 1'b1;
            src_byte = lat_byte;
        end
        else if (rgn_dmem) begin
            src_ok   = rd_ok;
            src_byte = dmem_byte;
        end
        else if (rgn_used && pair_ok) begin
            if (!map_found)                       // sin palabra: ceros
                src_ok = 1'b1;
            else if (!pair_val) begin
                src_ok   = 1'b1;
                src_byte = addr_byte;
            end
            else begin
                src_ok   = rd_ok;
                src_byte = dmem_byte;
            end
        end
    end

    //------------------------------------------------------------------
    // Secuencial
    //------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (i_rst) begin
            active_reg <= 1'b0;
            rd_ok_reg  <= 1'b0;
            ok_reg     <= 1'b0;
        end
        else begin
            active_reg <= active_next;
            rd_ok_reg  <= rd_en;
            ok_reg     <= src_ok & active_reg;
        end
        pair_reg    <= pair_next;
        rd_addr_reg <= rd_addr;
        byte_reg    <= src_byte;
        tag_reg     <= i_pl_idx;
    end

    always @(*) begin
        active_next = active_reg;
        pair_next   = pair_reg;
        if (i_cmd_valid) begin
            active_next = is_read;
            pair_next   = {NB_PAIR{1'b0}};
        end
        else if (find_next)
            pair_next = pair_reg + 1'b1;
    end

    //------------------------------------------------------------------
    // Salidas
    //------------------------------------------------------------------
    assign o_pl_byte   = byte_reg;
    assign o_pl_ready  = ok_reg & (tag_reg == i_pl_idx);
    assign o_dmem_used = {{(NB_LEN-NB_COUNT){1'b0}}, map_count};

    assign o_dmem_b_en   = i_du_dmem_b_en | rd_en;
    assign o_dmem_b_we   = i_du_dmem_b_en ? i_du_dmem_b_we   : 4'b0000;
    assign o_dmem_b_addr = i_du_dmem_b_en ? i_du_dmem_b_addr : rd_addr;
    assign o_dmem_b_din  = i_du_dmem_b_din;

    assign o_dbg_reg_addr = off[NB_REG_ADDR+1:2];

endmodule

`default_nettype wire
