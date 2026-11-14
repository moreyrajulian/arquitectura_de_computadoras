`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// debug_exec
//
// FSM de ejecución de la Debug Unit (I-47, decisiones 006, 018 y 037,
// docs/spec/protocolo_debug.md §3.3 a §3.5, §3.7 y §7, diagrama
// debug_unit_estados_core).
//
// Función:
//   Lleva el estado de ejecución del core (DBG_ST_*: NO_PROG, READY,
//   RUNNING, PAUSED, HALTED) y genera enable y core_rst. El reloj nunca se
//   detiene: parar y avanzar el core es siempre con enable (decisión 018).
//   Reacciona a los comandos que acepta debug_unit (i_cmd_valid, i_cmd) y
//   al halt del core. Un ciclo puede tener varios eventos; gana el
//   primero de esta lista (decisión 037):
//     i_rst          NO_PROG, sin programa, cycles = 0, sin evento.
//     i_load_start   (I-46) se aceptó el encabezado de un LOAD: NO_PROG y
//                    sin programa. Si el LOAD falla, ya queda así.
//     LOAD           el LOAD terminó bien: READY, prog_valid = 1,
//                    cycles = 0 y un pulso de core_rst.
//     RESET          READY si hay programa (si no, NO_PROG), cycles = 0
//                    y un pulso de core_rst.
//     i_halted       en RUNNING o PAUSED: HALTED. Solo desde RUNNING
//                    marca o_evt_pending (el EVT_HALTED); en PAUSED el
//                    HALT llegó con un STEP, y lo dice su respuesta.
//     RUN            desde READY o PAUSED: RUNNING.
//     STEP           desde READY o PAUSED: PAUSED, y enable = 1 durante
//                    el ciclo siguiente (un ciclo del core).
//     STOP           en RUNNING: PAUSED. En otro estado no hace nada.
//   LOAD y RESET también descartan un EVT_HALTED pendiente: la ejecución
//   terminó con ellos. i_evt_done baja o_evt_pending.
//   debug_unit ya rechaza RUN y STEP fuera de READY y PAUSED (ERR_STATE,
//   §3.7); este módulo igual los ignora ahí.
//
//   enable = (RUNNING | step) & ~i_halted, combinacional: baja en el
//   mismo ciclo en que llega halt (decisión 006), así el ciclo con el HALT
//   en WB es el último con enable = 1. cycles cuenta los ciclos con
//   enable = 1 (protocolo_debug.md §3.1, verificacion.md §5).
//   core_rst = i_rst | NO_PROG | pulso de LOAD y RESET | i_mem_busy.
//
// Parámetros:
//   NB_BYTE  : ancho de un byte del protocolo (CMD)
//   NB_WORD  : ancho de cycles
//   NB_STATE : ancho del estado de ejecución (DBG_ST_*)
//
// Puertos:
//   i_clk          : reloj del sistema
//   i_rst          : reset del sistema, síncrono, activo en alto
//   i_cmd_valid    : pulso: debug_unit aceptó i_cmd sin errores
//   i_cmd          : CMD aceptado                          [NB_BYTE-1:0]
//   i_load_start   : pulso: debug_unit aceptó el encabezado de un LOAD
//                    (I-46; 0 mientras no exista)
//   i_mem_busy     : debug_unit escribe imem o limpia dmem (LOAD_PREP a
//                    CLEAR, I-46): mantiene core_rst (0 mientras no exista)
//   i_halted       : halted del core (HALT llegó a WB)
//   i_evt_done     : pulso: debug_unit envió el último byte del EVT_HALTED
//   o_state        : estado de ejecución, DBG_ST_*         [NB_STATE-1:0]
//   o_prog_valid   : hay un programa cargado
//   o_cycles       : ciclos con enable = 1 desde el último LOAD o RESET
//                                                          [NB_WORD-1:0]
//   o_evt_pending  : hay un EVT_HALTED por enviar
//   o_enable       : enable global del core (decisión 018)
//   o_core_rst     : reset síncrono del core
//
// Latencia: el estado cambia en el flanco del ciclo de i_cmd_valid. Con
//           RUN, enable = 1 desde el ciclo siguiente; con STEP, enable = 1
//           solo en el ciclo siguiente; con STOP, enable = 0 desde el
//           ciclo siguiente. halted llega un ciclo después del ciclo con el
//           HALT en WB: enable baja en ese mismo ciclo y el estado pasa a
//           HALTED en el flanco. El pulso de core_rst de LOAD y RESET está
//           en el ciclo siguiente a i_cmd_valid.
// Reset   : NO_PROG, o_prog_valid = 0, o_cycles = 0, o_evt_pending = 0,
//           o_enable = 0, o_core_rst = 1.
//======================================================================

module debug_exec
#(
    parameter integer NB_BYTE  = 8,
    parameter integer NB_WORD  = 32,
    parameter integer NB_STATE = 3
)
(
    input  wire                i_clk,
    input  wire                i_rst,
    // debug_unit
    input  wire                i_cmd_valid,
    input  wire [NB_BYTE-1:0]  i_cmd,
    input  wire                i_load_start,
    input  wire                i_mem_busy,
    input  wire                i_evt_done,
    output wire [NB_STATE-1:0] o_state,
    output wire                o_prog_valid,
    output wire [NB_WORD-1:0]  o_cycles,
    output wire                o_evt_pending,
    // core
    input  wire                i_halted,
    output wire                o_enable,
    output wire                o_core_rst
);

    `include "riscv_defs.vh"

    //------------------------------------------------------------------
    // Registros
    //------------------------------------------------------------------
    reg [NB_STATE-1:0] state_reg,  state_next;
    reg                prog_reg,   prog_next;    // prog_valid
    reg [NB_WORD-1:0]  cycles_reg, cycles_next;
    reg                evt_reg,    evt_next;     // evt_pending
    reg                step_reg,   step_next;    // el ciclo del STEP
    reg                clr_reg,    clr_next;     // pulso de core_rst de LOAD y RESET

    //------------------------------------------------------------------
    // Comandos y estados
    //------------------------------------------------------------------
    wire cmd_load  = i_cmd_valid & (i_cmd == DBG_CMD_LOAD);
    wire cmd_reset = i_cmd_valid & (i_cmd == DBG_CMD_RESET);
    wire cmd_run   = i_cmd_valid & (i_cmd == DBG_CMD_RUN);
    wire cmd_step  = i_cmd_valid & (i_cmd == DBG_CMD_STEP);
    wire cmd_stop  = i_cmd_valid & (i_cmd == DBG_CMD_STOP);

    wire st_running = (state_reg == DBG_ST_RUNNING);
    wire st_paused  = (state_reg == DBG_ST_PAUSED);
    wire can_go     = (state_reg == DBG_ST_READY) | st_paused;   // RUN y STEP (§3.7)

    // enable baja en el mismo ciclo en que llega halt (decisión 006)
    wire enable = (st_running | step_reg) & ~i_halted;

    //------------------------------------------------------------------
    // Secuencial
    //------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (i_rst) begin
            state_reg  <= DBG_ST_NO_PROG;
            prog_reg   <= 1'b0;
            cycles_reg <= {NB_WORD{1'b0}};
            evt_reg    <= 1'b0;
            step_reg   <= 1'b0;
            clr_reg    <= 1'b0;
        end
        else begin
            state_reg  <= state_next;
            prog_reg   <= prog_next;
            cycles_reg <= cycles_next;
            evt_reg    <= evt_next;
            step_reg   <= step_next;
            clr_reg    <= clr_next;
        end
    end

    //------------------------------------------------------------------
    // Siguiente estado, en el orden de prioridad de la cabecera
    //------------------------------------------------------------------
    always @(*) begin
        state_next  = state_reg;
        prog_next   = prog_reg;
        cycles_next = enable ? cycles_reg + 1'b1 : cycles_reg;
        evt_next    = evt_reg & ~i_evt_done;
        step_next   = 1'b0;
        clr_next    = 1'b0;

        if (i_load_start) begin
            state_next = DBG_ST_NO_PROG;
            prog_next  = 1'b0;
            evt_next   = 1'b0;
        end
        else if (cmd_load) begin
            state_next  = DBG_ST_READY;
            prog_next   = 1'b1;
            cycles_next = {NB_WORD{1'b0}};
            evt_next    = 1'b0;
            clr_next    = 1'b1;
        end
        else if (cmd_reset) begin
            state_next  = prog_reg ? DBG_ST_READY : DBG_ST_NO_PROG;
            cycles_next = {NB_WORD{1'b0}};
            evt_next    = 1'b0;
            clr_next    = 1'b1;
        end
        else if (i_halted && (st_running || st_paused)) begin
            state_next = DBG_ST_HALTED;
            if (st_running)
                evt_next = 1'b1;
        end
        else if (cmd_run && can_go)
            state_next = DBG_ST_RUNNING;
        else if (cmd_step && can_go) begin
            state_next = DBG_ST_PAUSED;
            step_next  = 1'b1;
        end
        else if (cmd_stop && st_running)
            state_next = DBG_ST_PAUSED;
    end

    //------------------------------------------------------------------
    // Salidas
    //------------------------------------------------------------------
    assign o_state       = state_reg;
    assign o_prog_valid  = prog_reg;
    assign o_cycles      = cycles_reg;
    assign o_evt_pending = evt_reg;
    assign o_enable      = enable;
    assign o_core_rst    = i_rst | (state_reg == DBG_ST_NO_PROG) | clr_reg | i_mem_busy;

endmodule

`default_nettype wire
