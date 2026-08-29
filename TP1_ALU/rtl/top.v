`timescale 1ns / 1ps

//======================================================================
// Top del TP1: los switches cargan A, B y el opcode en registros mediante
// tres pulsadores; el resultado se registra y se muestra en los LEDs.
//
//   SWITCHES --+--> [reg A ]--+
//              |              +--> ALU --> [reg result] --> LEDS
//              +--> [reg B ]--+
//              |              |
//              +--> [reg OP]--+
//======================================================================

module top
#(
    parameter integer NB_DATA = 8,   // ancho del bus de datos
    parameter integer NB_OP   = 6,   // ancho del codigo de operacion
    parameter integer NB_SW   = 8    // switches usados (>= NB_DATA y >= NB_OP)
)
(
    input  wire               clk,
    input  wire               i_reset,     // btnC
    input  wire [NB_SW-1:0]   i_sw,
    input  wire               i_btn_a,     // btnL -> carga dato A
    input  wire               i_btn_b,     // btnR -> carga dato B
    input  wire               i_btn_op,    // btnU -> carga opcode
    output wire [NB_DATA-1:0] o_led
);

    wire tick_a, tick_b, tick_op;

    reg [NB_DATA-1:0] reg_a;
    reg [NB_DATA-1:0] reg_b;
    reg [NB_OP-1:0]   reg_op;
    reg [NB_DATA-1:0] reg_result;

    wire [NB_DATA-1:0] alu_result;
    wire               alu_zero;

    //------------------------------------------------------------------
    // Antirrebote de los tres pulsadores de carga
    //------------------------------------------------------------------
    debouncer u_deb_a  (.i_clk(clk), .i_reset(i_reset), .i_btn(i_btn_a),  .o_tick(tick_a));
    debouncer u_deb_b  (.i_clk(clk), .i_reset(i_reset), .i_btn(i_btn_b),  .o_tick(tick_b));
    debouncer u_deb_op (.i_clk(clk), .i_reset(i_reset), .i_btn(i_btn_op), .o_tick(tick_op));

    //------------------------------------------------------------------
    // Registros de entrada
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (i_reset) begin
            reg_a  <= {NB_DATA{1'b0}};
            reg_b  <= {NB_DATA{1'b0}};
            reg_op <= {NB_OP{1'b0}};
        end else begin
            if (tick_a)  reg_a  <= i_sw[NB_DATA-1:0];
            if (tick_b)  reg_b  <= i_sw[NB_DATA-1:0];
            if (tick_op) reg_op <= i_sw[NB_OP-1:0];
        end
    end

    //------------------------------------------------------------------
    // ALU
    //------------------------------------------------------------------
    alu #(
        .NB_DATA (NB_DATA),
        .NB_OP   (NB_OP)
    ) u_alu (
        .i_a      (reg_a),
        .i_b      (reg_b),
        .i_op     (reg_op),
        .o_result (alu_result)
    );

    //------------------------------------------------------------------
    // Registro de salida: cierra el camino reg -> logica -> reg, que es
    // lo que el analisis de tiempo de Vivado puede medir.
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (i_reset) reg_result <= {NB_DATA{1'b0}};
        else         reg_result <= alu_result;
    end

    assign o_led = reg_result;

endmodule