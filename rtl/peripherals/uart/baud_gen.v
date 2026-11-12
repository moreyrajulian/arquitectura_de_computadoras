`timescale 1ns / 1ps

module baud_gen 
#( 
    parameter integer DVSR = 326 
)
(
    input wire clk, 
    input wire reset, 
    output wire tick 
);
    localparam integer N = $clog2(DVSR); //bits p/contar de 0 a DVSR-1

    reg [N-1:0] count_reg;   
    wire [N-1:0] count_next;                       

    always @(posedge clk) begin
        if (reset) 
            count_reg <= 0;
        else       
            count_reg <= count_next;
    end
    
    assign count_next = (count_reg == DVSR-1) ? 0 : count_reg + 1;
    assign tick = (count_reg == DVSR-1);          // pulso de 1 ciclo en el tope

endmodule