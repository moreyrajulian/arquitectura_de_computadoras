`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// hazard_unit
//
// Unidad de detección de riesgos (docs/spec/pipeline.md §10.3 y §10.4).
// Tiene el detector de carga-uso (I-41) y, desde I-42, calcula el stall
// y las entradas en / flush de cada registro de segmentación.
//
// Función:
//   1. Carga-uso (§10.3). Detecta una instrucción en ID que lee el
//      registro que carga el load que está en EX. El dato del load recién
//      sale de la BRAM en WB (decisión 009), así que esa instrucción
//      tiene que esperar un ciclo:
//        load_use = id_ex_mem_read && id_ex_rd != 0 && if_id_valid &&
//                   (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
//      - Conservadora (decisión 011): compara los campos rs1 = instr[19:15]
//        y rs2 = instr[24:20] sin mirar si la instrucción los usa. Puede
//        frenar de más (lui, jal, el inmediato de una I-type o el HALT,
//        con rs2 = 1), nunca de menos. Son los mismos campos que compara
//        forwarding_unit (§10.2), y por eso nunca se reenvía la dirección
//        de un load desde EX/MEM.
//      - Un sw que guarda el dato recién cargado también frena: no hay
//        forwarding hacia MEM (decisión 011).
//      - x0 nunca frena: un load a x0 no deja ningún valor.
//      - Una burbuja en IF/ID (if_id_valid = 0) no lee registros.
//      - No mira valid de ID/EX: una burbuja tiene mem_read = 0 (§2).
//      Después del stall, el load está en WB y la instrucción frenada en
//      EX recibe el dato por forwarding desde MEM/WB (fwd = 01).
//
//   2. Enables y flush (§10.4), con el salto tomado de EX (§5.3, §10.5),
//      la parada por HALT (§3.4) y el enable de la Debug Unit (decisión
//      018):
//        stall        = load_use & ~redirect
//        en_pc        = en_if_id = enable & ~stall
//        en_id_ex     = en_ex_mem = en_mem_wb = enable
//        flush_if_id  = redirect | stop_fetch
//        flush_id_ex  = redirect | stall
//        flush_ex_mem = flush_mem_wb = 0
//      - Salto tomado: las dos instrucciones que entraron detrás (en ID y
//        en IF) siguieron PC + 4 y se convierten en burbuja en el mismo
//        flanco en que el PC toma redirect_pc (§10.5, decisión 012).
//      - Stall y salto a la vez: gana el salto (§3.3). Con los saltos en
//        EX no puede pasar (la instrucción en EX es un load o un salto);
//        el término queda como protección.
//      - Los registros dan prioridad a en sobre flush (§2): con un stall y
//        un HALT en ID, flush_if_id = 1 por stop_fetch pero en_if_id = 0,
//        e IF/ID conserva el HALT (§3.4). Con enable = 0 ningún registro
//        cambia, aunque algún flush valga 1.
//   Todo es combinacional sobre los latches, así que con enable = 0 el
//   stall queda congelado y sigue donde estaba al volver a 1 (§10.4).
//
// Parámetros:
//   NB_ADDR : ancho del número de registro
//
// Puertos:
//   i_enable         : enable global del core (decisión 018)
//   i_redirect       : salto tomado en EX (§5.3)
//   i_stop_fetch     : hay un HALT en el pipeline o halted = 1 (§3.4)
//   i_if_id_valid    : IF/ID tiene una instrucción real
//   i_if_id_rs1      : campo rs1 de la instrucción en ID   [NB_ADDR-1:0]
//   i_if_id_rs2      : campo rs2 de la instrucción en ID   [NB_ADDR-1:0]
//   i_id_ex_mem_read : la instrucción en EX es un load
//   i_id_ex_rd       : destino de la instrucción en EX     [NB_ADDR-1:0]
//   o_load_use       : la instrucción en ID usa el dato del load en EX
//   o_stall          : retener PC e IF/ID un ciclo (load_use sin salto)
//   o_en_pc          : en de pc_reg
//   o_en_if_id       : en de IF/ID (y ena de la memoria de programa)
//   o_en_id_ex       : en de ID/EX
//   o_en_ex_mem      : en de EX/MEM
//   o_en_mem_wb      : en de MEM/WB (y ena de la memoria de datos)
//   o_flush_if_id    : IF/ID carga burbuja
//   o_flush_id_ex    : ID/EX carga burbuja
//   o_flush_ex_mem   : EX/MEM carga burbuja (siempre 0)
//   o_flush_mem_wb   : MEM/WB carga burbuja (siempre 0)
//
// Latencia: 0 ciclos (combinacional).
// Reset   : no tiene.
//======================================================================

module hazard_unit
#(
    parameter integer NB_ADDR = 5
)
(
    input  wire               i_enable,
    input  wire               i_redirect,
    input  wire               i_stop_fetch,
    input  wire               i_if_id_valid,
    input  wire [NB_ADDR-1:0] i_if_id_rs1,
    input  wire [NB_ADDR-1:0] i_if_id_rs2,
    input  wire               i_id_ex_mem_read,
    input  wire [NB_ADDR-1:0] i_id_ex_rd,
    output wire               o_load_use,
    output wire               o_stall,
    output wire               o_en_pc,
    output wire               o_en_if_id,
    output wire               o_en_id_ex,
    output wire               o_en_ex_mem,
    output wire               o_en_mem_wb,
    output wire               o_flush_if_id,
    output wire               o_flush_id_ex,
    output wire               o_flush_ex_mem,
    output wire               o_flush_mem_wb
);

    localparam [NB_ADDR-1:0] REG_X0 = {NB_ADDR{1'b0}};

    //------------------------------------------------------------------
    // Carga-uso (§10.3)
    //------------------------------------------------------------------
    // El load en EX deja un valor en un registro distinto de x0
    wire load_writes = i_id_ex_mem_read & (i_id_ex_rd != REG_X0);

    // La instrucción en ID nombra ese registro en alguno de sus campos
    wire rs1_match = (i_id_ex_rd == i_if_id_rs1);
    wire rs2_match = (i_id_ex_rd == i_if_id_rs2);

    assign o_load_use = load_writes & i_if_id_valid & (rs1_match | rs2_match);

    //------------------------------------------------------------------
    // Enables y flush (§10.4). Si hay salto tomado gana el salto (§3.3)
    //------------------------------------------------------------------
    assign o_stall        = o_load_use & ~i_redirect;

    assign o_en_pc        = i_enable & ~o_stall;
    assign o_en_if_id     = i_enable & ~o_stall;
    assign o_en_id_ex     = i_enable;
    assign o_en_ex_mem    = i_enable;
    assign o_en_mem_wb    = i_enable;

    assign o_flush_if_id  = i_redirect | i_stop_fetch;
    assign o_flush_id_ex  = i_redirect | o_stall;
    assign o_flush_ex_mem = 1'b0;
    assign o_flush_mem_wb = 1'b0;

endmodule

`default_nettype wire
