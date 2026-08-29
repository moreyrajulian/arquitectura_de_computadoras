`timescale 1ns / 1ps

//======================================================================
// Testbench autochequeante para la ALU.
//   - estimulos aleatorios con $random y semilla fija (reproducible)
//   - modelo de referencia escrito de forma independiente del RTL
//   - contador de errores + veredicto TEST PASSED / TEST FAILED
//======================================================================

module alu_tb;

    // parameter (no localparam) para poder barrer anchos sin tocar el archivo:
    //   iverilog -g2012 -Palu_tb.NB_DATA=32 -o sim alu.v alu_tb.v
    parameter integer NB_DATA  = 8;
    localparam integer NB_OP   = 6;
    localparam integer N_TESTS = 2000;
    localparam integer NB_SHAMT = (NB_DATA > 1) ? $clog2(NB_DATA) : 1;
    localparam integer T_STEP   = 10;   // ns entre vectores

    reg   [NB_DATA-1:0] tb_a;
    reg   [NB_DATA-1:0] tb_b;
    reg         [NB_OP-1:0]   tb_op;
    wire  [NB_DATA-1:0] tb_result;

    reg   [NB_DATA-1:0] esperado;
    reg         [NB_OP-1:0]   op_list [0:7];

    integer i;
    integer errors;
    integer seed;

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    alu #(
        .NB_DATA (NB_DATA),
        .NB_OP   (NB_OP)
    ) u_alu (
        .i_a      (tb_a),
        .i_b      (tb_b),
        .i_op     (tb_op),
        .o_result (tb_result)
    );

    //------------------------------------------------------------------
    // Modelo de referencia
    //------------------------------------------------------------------
    function signed [NB_DATA-1:0] alu_model;
        input signed [NB_DATA-1:0] a;
        input signed [NB_DATA-1:0] b;
        input        [NB_OP-1:0]   op;
        reg          [NB_SHAMT-1:0] sh;
        begin
            sh = b[NB_SHAMT-1:0];
            case (op)
                6'b100000: alu_model = a + b;
                6'b100010: alu_model = a - b;
                6'b100100: alu_model = a & b;
                6'b100101: alu_model = a | b;
                6'b100110: alu_model = a ^ b;
                6'b100111: alu_model = ~(a | b);
                6'b000011: alu_model = a >>> sh;
                6'b000010: alu_model = $unsigned(a) >> sh;
                default  : alu_model = {NB_DATA{1'b0}};
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // Estimulos + chequeo
    //------------------------------------------------------------------
    initial begin
        $dumpfile("alu_tb.vcd");
        $dumpvars(0, alu_tb);

        errors = 0;
        seed   = 32'hC0FFEE;

        op_list[0] = 6'b100000;  // ADD
        op_list[1] = 6'b100010;  // SUB
        op_list[2] = 6'b100100;  // AND
        op_list[3] = 6'b100101;  // OR
        op_list[4] = 6'b100110;  // XOR
        op_list[5] = 6'b100111;  // NOR
        op_list[6] = 6'b000011;  // SRA
        op_list[7] = 6'b000010;  // SRL

        for (i = 0; i < N_TESTS; i = i + 1) begin
            tb_a = $random(seed);
            tb_b = $random(seed);

            // 1 de cada 10 vectores usa un opcode cualquiera, para ejercitar
            // tambien el camino default del case.
            if (({$random(seed)} % 10) == 0)
                tb_op = $random(seed);
            else
                tb_op = op_list[{$random(seed)} % 8];

            #(T_STEP);   // margen de propagacion (importante en sim. post-impl.)

            esperado = alu_model(tb_a, tb_b, tb_op);

            if (tb_result !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR op=%b a=%0d b=%0d -> dut=%0d esperado=%0d",
                         $time, tb_op, tb_a, tb_b, tb_result, esperado);
            end
        end

        // Casos de borde, no cubiertos de forma confiable por lo aleatorio
        check_vector({NB_DATA{1'b0}}, {NB_DATA{1'b0}},          6'b100000); // 0+0
        check_vector({1'b1, {NB_DATA-1{1'b0}}}, {NB_DATA{1'b1}}, 6'b100000); // min + (-1) -> overflow
        check_vector({1'b1, {NB_DATA-1{1'b0}}}, 1,               6'b000011); // SRA sobre negativo
        check_vector({1'b1, {NB_DATA-1{1'b0}}}, 1,               6'b000010); // SRL sobre negativo
        check_vector({NB_DATA{1'b1}}, {NB_DATA{1'b0}},           6'b100111); // NOR

        if (errors == 0)
            $display("TEST PASSED: %0d vectores aleatorios + casos de borde, 0 errores", N_TESTS);
        else
            $display("TEST FAILED: %0d errores", errors);

        $finish;
    end

    task check_vector;
        input signed [NB_DATA-1:0] a;
        input signed [NB_DATA-1:0] b;
        input        [NB_OP-1:0]   op;
        begin
            tb_a = a; tb_b = b; tb_op = op;
            #(T_STEP);
            if (tb_result !== alu_model(a, b, op)) begin
                errors = errors + 1;
                $display("[%0t] ERROR (borde) op=%b a=%0d b=%0d -> dut=%0d esperado=%0d",
                         $time, op, a, b, tb_result, alu_model(a, b, op));
            end
        end
    endtask

endmodule