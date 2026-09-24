`timescale 1ns / 1ps

module alu
#(
    parameter NB_DATA = 8 //ancho de los datos 
)
(
    input wire signed [NB_DATA-1:0] i_a,
    input wire signed [NB_DATA-1:0] i_b,
    input wire [NB_OP-1:0] i_op,
    output wire signed [NB_DATA-1:0] o_result
);

    localparam NB_OP = 6;   //ancho del codigo para identificar la operacion que se quiere realizar
    //parametros locales para identificar los codigos de operacion
    localparam [NB_OP-1:0] OP_ADD = 6'b100000;
    localparam [NB_OP-1:0] OP_SUB = 6'b100010;
    localparam [NB_OP-1:0] OP_AND = 6'b100100;
    localparam [NB_OP-1:0] OP_OR  = 6'b100101;
    localparam [NB_OP-1:0] OP_XOR = 6'b100110;
    localparam [NB_OP-1:0] OP_SRA = 6'b000011;
    localparam [NB_OP-1:0] OP_SRL = 6'b000010;
    localparam [NB_OP-1:0] OP_NOR = 6'b100111;
    
    //bits de B usados como shift amount
    localparam NB_SHAMT = $clog2(NB_DATA);
    wire [NB_SHAMT-1:0] shamt = i_b[NB_SHAMT-1:0];
    
    reg signed [NB_DATA-1:0] result;
    
    always @(*) begin
        case (i_op)
            OP_ADD : result = i_a + i_b;
            OP_SUB : result = i_a - i_b;
            OP_AND : result = i_a & i_b;
            OP_OR  : result = i_a | i_b;
            OP_XOR : result = i_a ^ i_b;
            OP_NOR : result = ~(i_a | i_b);
            OP_SRA : result = i_a >>> shamt;
            OP_SRL : result = $unsigned(i_a) >>  shamt;
            default: result = {NB_DATA{1'b0}}; //para no inferir un latch
        endcase
    end
    
    assign o_result = result;

endmodule
