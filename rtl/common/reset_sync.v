`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// reset_sync
//
// Reset del sistema en la placa (I-49, decisiones 041 y 042): sincroniza
// el pedido de reset y genera el reset de encendido.
//
// Función:
//   - i_rst_req es el pedido de reset: el botón (btnC de la Basys 3), que
//     rebota, o el Clock Wizard sin enganchar (~locked, decisión 042). Es
//     asíncrono al reloj: pasa por un sincronizador de dos flip-flops.
//   - Un contador de POR_CYCLES ciclos mantiene o_rst = 1 al configurar la
//     FPGA (reset de encendido) y después de que baja i_rst_req. Mientras
//     i_rst_req = 1 el contador vuelve a 0, así que un rebote solo alarga
//     el reset: no hay pulsos más cortos que POR_CYCLES.
//   - o_rst sale de un registro: síncrono, activo en alto y sin glitches,
//     como lo espera todo el RTL (decisión 010).
//   No tiene reset propio: los registros arrancan del valor inicial de la
//   declaración, que Vivado carga como INIT al configurar la FPGA
//   (decisión 041). Por eso tampoco necesita reset asíncrono.
//
// Parámetros:
//   POR_CYCLES : ciclos que dura el reset después del encendido y después
//                de que baja i_rst_req (≥ 1)
//   NB_POR     : bits del contador; tiene que alcanzar POR_CYCLES
//
// Puertos:
//   i_clk     : reloj del sistema
//   i_rst_req : pedido de reset, asíncrono, activo en alto (botón o reloj
//               sin enganchar)
//   o_rst     : reset del sistema, síncrono, activo en alto
//
// Latencia: o_rst sube 3 ciclos después de i_rst_req (2 del sincronizador
//           y el registro de salida) y baja POR_CYCLES + 3 ciclos después
//           de que i_rst_req baja.
// Reset   : sin reset. Al configurar la FPGA: o_rst = 1 y el contador en
//           0, así que el reset de encendido dura POR_CYCLES + 1 ciclos.
//======================================================================

module reset_sync
#(
    parameter integer POR_CYCLES = 16,
    parameter integer NB_POR     = 5
)
(
    input  wire i_clk,
    input  wire i_rst_req,
    output wire o_rst
);

    localparam [NB_POR-1:0] POR_LAST = POR_CYCLES;

    //------------------------------------------------------------------
    // Sincronizador del pedido de reset (entrada asíncrona)
    //------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg req_meta_reg = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg req_sync_reg = 1'b0;

    always @(posedge i_clk) begin
        req_meta_reg <= i_rst_req;
        req_sync_reg <= req_meta_reg;
    end

    //------------------------------------------------------------------
    // Contador del reset y registro de salida
    //------------------------------------------------------------------
    reg  [NB_POR-1:0] por_cnt_reg = {NB_POR{1'b0}};
    reg  [NB_POR-1:0] por_cnt_next;
    reg               rst_reg = 1'b1;
    wire              por_done = (por_cnt_reg == POR_LAST);

    always @(posedge i_clk) begin
        por_cnt_reg <= por_cnt_next;
        rst_reg     <= req_sync_reg | ~por_done;
    end

    always @(*) begin
        por_cnt_next = por_cnt_reg;
        if (req_sync_reg)
            por_cnt_next = {NB_POR{1'b0}};
        else if (!por_done)
            por_cnt_next = por_cnt_reg + 1'b1;
    end

    assign o_rst = rst_reg;

endmodule

`default_nettype wire
