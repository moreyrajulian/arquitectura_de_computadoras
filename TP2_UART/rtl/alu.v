`timescale 1ns / 1ps
module alu
#(
    parameter NB_DATA = 8
)
(
    input  wire clk, reset,
    // interfaz Rx (lectura)
    input  wire [NB_DATA-1:0] r_data,
    input  wire rx_empty,
    output reg  rd,
    // interfaz Tx (escritura)
    input  wire tx_full,
    output reg  wr,
    output reg  [NB_DATA-1:0] w_data
);
    localparam NB_OP = 6;
    localparam [NB_OP-1:0] OP_ADD = 6'b100000;
    localparam [NB_OP-1:0] OP_SUB = 6'b100010;
    localparam [NB_OP-1:0] OP_AND = 6'b100100;
    localparam [NB_OP-1:0] OP_OR  = 6'b100101;
    localparam [NB_OP-1:0] OP_XOR = 6'b100110;
    localparam [NB_OP-1:0] OP_SRA = 6'b000011;
    localparam [NB_OP-1:0] OP_SRL = 6'b000010;
    localparam [NB_OP-1:0] OP_NOR = 6'b100111;

    localparam NB_SHAMT = $clog2(NB_DATA);

    // estados de la FSM
    localparam [2:0]
        S_OP      = 3'd0, // esperando byte de opcode
        S_A       = 3'd1, // esperando byte del operando A
        S_B       = 3'd2, // esperando byte del operando B
        S_COMPUTE = 3'd3, // calcula (combinacional, 1 ciclo)
        S_TX      = 3'd4; // esperando poder escribir el resultado

    reg [2:0] state_reg, state_next;
    reg [NB_OP-1:0] op_reg, op_next;
    reg signed [NB_DATA-1:0] a_reg, a_next;
    reg signed [NB_DATA-1:0] b_reg, b_next;
    reg signed [NB_DATA-1:0] result_reg, result_next;

    // registro de estado
    always @(posedge clk) begin
        if (reset) begin
            state_reg  <= S_OP;
            op_reg     <= 0;
            a_reg      <= 0;
            b_reg      <= 0;
            result_reg <= 0;
        end else begin
            state_reg  <= state_next;
            op_reg     <= op_next;
            a_reg      <= a_next;
            b_reg      <= b_next;
            result_reg <= result_next;
        end
    end

    // logica de siguiente estado y calculo de la ALU
    reg [NB_SHAMT-1:0] shamt;
    always @(*) begin
        // valores por defecto (se mantienen)
        state_next  = state_reg;
        op_next     = op_reg;
        a_next      = a_reg;
        b_next      = b_reg;
        result_next = result_reg;
        rd          = 1'b0;
        wr          = 1'b0;
        w_data      = {NB_DATA{1'b0}};
        shamt       = b_reg[NB_SHAMT-1:0];

        case (state_reg)
            S_OP: begin
                if (!rx_empty) begin
                    op_next    = r_data[NB_OP-1:0];
                    rd         = 1'b1;   // pulso de 1 ciclo
                    state_next = S_A;
                end
            end
            S_A: begin
                if (!rx_empty) begin
                    a_next     = r_data;
                    rd         = 1'b1;
                    state_next = S_B;
                end
            end
            S_B: begin
                if (!rx_empty) begin
                    b_next     = r_data;
                    rd         = 1'b1;
                    state_next = S_COMPUTE;
                end
            end
            S_COMPUTE: begin
                case (op_reg)
                    OP_ADD : result_next = a_reg + b_reg;
                    OP_SUB : result_next = a_reg - b_reg;
                    OP_AND : result_next = a_reg & b_reg;
                    OP_OR  : result_next = a_reg | b_reg;
                    OP_XOR : result_next = a_reg ^ b_reg;
                    OP_NOR : result_next = ~(a_reg | b_reg);
                    OP_SRA : result_next = a_reg >>> shamt;
                    OP_SRL : result_next = $unsigned(a_reg) >> shamt;
                    default: result_next = {NB_DATA{1'b0}};
                endcase
                state_next = S_TX;
            end
            S_TX: begin
                if (!tx_full) begin
                    w_data     = result_reg;
                    wr         = 1'b1;   // pulso de 1 ciclo
                    state_next = S_OP;
                end
            end
            default: state_next = S_OP;
        endcase
    end
endmodule
