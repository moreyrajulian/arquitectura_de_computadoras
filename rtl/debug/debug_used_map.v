`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// debug_used_map
//
// Mapa de palabras usadas de la memoria de datos (I-48, decisiones 005 y
// 039, docs/spec/memoria.md §7). Lo instancia debug_dump.
//
// Función:
//   Un bit por palabra de dmem en RAM distribuida (LUTRAM, inferida), con
//   lectura asíncrona y una sola dirección, que elige un multiplexor según
//   quién la usa:
//     i_clr   (CLEAR de LOAD y RESET) used[i_clr_addr] <- 0, count <- 0.
//     i_mark  (un store del core)     used[i_mark_addr] <- 1; si valía 0,
//                                     count + 1.
//     búsqueda                        lee used[ptr].
//   Nunca coinciden: el core marca con enable = 1, y CLEAR y la búsqueda
//   se hacen con el core detenido. Si igual coinciden, gana i_clr, y la
//   búsqueda espera ese ciclo.
//   La búsqueda encuentra la primera palabra marcada desde un punto de
//   partida, un bit por ciclo: i_find_first empieza desde 0, e
//   i_find_next desde la palabra siguiente a o_addr. Mientras busca,
//   o_busy = 1. Al terminar, o_found = 1 y o_addr es la palabra, o
//   o_found = 0 si llegó a la última sin encontrar ninguna.
//
// Parámetros:
//   DMEM_WORDS  : palabras de dmem (1024)
//   NB_MEM_ADDR : bits del índice de palabra (10)
//   NB_COUNT    : bits de o_count, $clog2(DMEM_WORDS + 1) (11)
//
// Puertos:
//   i_clk        : reloj del sistema
//   i_rst        : reset del sistema, síncrono, activo en alto
//   i_mark       : un store escribe la palabra i_mark_addr
//   i_mark_addr  : palabra que escribe el store         [NB_MEM_ADDR-1:0]
//   i_clr        : borrar la palabra i_clr_addr y el contador
//   i_clr_addr   : palabra que se borra                  [NB_MEM_ADDR-1:0]
//   i_find_first : pulso: buscar desde la palabra 0
//   i_find_next  : pulso: buscar desde o_addr + 1
//   o_busy       : la búsqueda está en curso
//   o_found      : la última búsqueda encontró una palabra (con o_busy = 0)
//   o_addr       : la palabra encontrada                 [NB_MEM_ADDR-1:0]
//   o_count      : palabras marcadas (dmem_used)         [NB_COUNT-1:0]
//
// Latencia: la marca y el borrado se ven en el ciclo siguiente, también en
//           o_count. Una búsqueda que empieza en la palabra p y termina en
//           la q tarda q - p + 1 ciclos con o_busy = 1, desde el ciclo
//           siguiente al pulso (hasta DMEM_WORDS + 1 si no encuentra).
// Reset   : o_count = 0, sin búsqueda en curso, o_found = 0. La LUTRAM no
//           se resetea (decisión 010): después de i_rst el core no escribe
//           hasta un LOAD o un RESET, que la borran en CLEAR, y mientras
//           tanto o_count = 0 (decisión 039).
//======================================================================

module debug_used_map
#(
    parameter integer DMEM_WORDS  = 1024,
    parameter integer NB_MEM_ADDR = 10,
    parameter integer NB_COUNT    = 11
)
(
    input  wire                   i_clk,
    input  wire                   i_rst,
    input  wire                   i_mark,
    input  wire [NB_MEM_ADDR-1:0] i_mark_addr,
    input  wire                   i_clr,
    input  wire [NB_MEM_ADDR-1:0] i_clr_addr,
    input  wire                   i_find_first,
    input  wire                   i_find_next,
    output wire                   o_busy,
    output wire                   o_found,
    output wire [NB_MEM_ADDR-1:0] o_addr,
    output wire [NB_COUNT-1:0]    o_count
);

    //------------------------------------------------------------------
    // Constantes
    //------------------------------------------------------------------
    localparam [NB_MEM_ADDR:0] PTR_END   = DMEM_WORDS;     // pasó la última palabra
    localparam [NB_MEM_ADDR:0] PTR_FIRST = {(NB_MEM_ADDR+1){1'b0}};

    //------------------------------------------------------------------
    // RAM distribuida de DMEM_WORDS × 1, con una sola dirección
    //------------------------------------------------------------------
    reg used_mem [0:DMEM_WORDS-1];

    reg [NB_MEM_ADDR:0]   ptr_reg,   ptr_next;     // palabra que mira la búsqueda
    reg                   busy_reg,  busy_next;
    reg                   found_reg, found_next;
    reg [NB_MEM_ADDR-1:0] addr_reg,  addr_next;
    reg [NB_COUNT-1:0]    count_reg, count_next;

    wire                   mem_we   = i_clr | i_mark;
    wire [NB_MEM_ADDR-1:0] mem_addr = i_clr  ? i_clr_addr  :
                                      i_mark ? i_mark_addr : ptr_reg[NB_MEM_ADDR-1:0];
    wire                   mem_bit  = used_mem[mem_addr];

    always @(posedge i_clk)
        if (mem_we)
            used_mem[mem_addr] <= ~i_clr;

    //------------------------------------------------------------------
    // Secuencial
    //------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (i_rst) begin
            busy_reg  <= 1'b0;
            found_reg <= 1'b0;
            count_reg <= {NB_COUNT{1'b0}};
        end
        else begin
            busy_reg  <= busy_next;
            found_reg <= found_next;
            count_reg <= count_next;
        end
        ptr_reg  <= ptr_next;
        addr_reg <= addr_next;
    end

    //------------------------------------------------------------------
    // Contador y búsqueda
    //------------------------------------------------------------------
    always @(*) begin
        count_next = count_reg;
        if (i_clr)
            count_next = {NB_COUNT{1'b0}};
        else if (i_mark && !mem_bit)
            count_next = count_reg + 1'b1;
    end

    always @(*) begin
        ptr_next   = ptr_reg;
        busy_next  = busy_reg;
        found_next = found_reg;
        addr_next  = addr_reg;
        if (i_find_first) begin
            ptr_next   = PTR_FIRST;
            busy_next  = 1'b1;
            found_next = 1'b0;
        end
        else if (i_find_next) begin
            ptr_next   = {1'b0, addr_reg} + 1'b1;
            busy_next  = 1'b1;
            found_next = 1'b0;
        end
        else if (busy_reg && !mem_we) begin
            if (ptr_reg == PTR_END)
                busy_next = 1'b0;                    // sin palabra marcada
            else if (mem_bit) begin
                busy_next  = 1'b0;
                found_next = 1'b1;
                addr_next  = ptr_reg[NB_MEM_ADDR-1:0];
            end
            else
                ptr_next = ptr_reg + 1'b1;
        end
    end

    //------------------------------------------------------------------
    // Salidas
    //------------------------------------------------------------------
    assign o_busy  = busy_reg;
    assign o_found = found_reg;
    assign o_addr  = addr_reg;
    assign o_count = count_reg;

endmodule

`default_nettype wire
