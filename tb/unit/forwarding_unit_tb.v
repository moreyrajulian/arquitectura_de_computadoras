`timescale 1ns / 1ps

//======================================================================
// forwarding_unit_tb
//
// Testbench autoverificante de forwarding_unit (docs/spec/verificacion.md
// §3.2, pipeline.md §10.2).
//
// Oráculo, escrito aparte del RTL: para cada registro fuente r que lee
// la instrucción en EX, recorre las dos instrucciones que la preceden de
// la más nueva (en MEM) a la más vieja (en WB) y se queda con la primera
// que deja un valor en r. Una instrucción deja un valor en r si escribe
// registro (reg_write) y su rd es r, salvo r = x0, que siempre vale 0
// (isa.md). Si ninguna lo deja, el valor correcto es el leído en ID.
// El selector esperado es el código de la fuente elegida (pipeline.md
// §5.1).
//
// Casos:
//   - Dirigidos, con nombre: sin escritura, coincidencia con EX/MEM, con
//     MEM/WB, con las dos (prioridad de EX/MEM), rd = x0 en cada etapa
//     con reg_write = 1, reg_write = 0 con rd coincidente, rs1 = rs2,
//     y fwd_a y fwd_b con fuentes distintas a la vez
//   - Exhaustivo: todas las combinaciones de ex_mem_reg_write,
//     mem_wb_reg_write, ex_mem_rd, mem_wb_rd, id_ex_rs1 e id_ex_rs2
//     (2 * 2 * 32^4 = 4194304 vectores). Cubre cada coincidencia de rd
//     con rs1 / rs2, rd = 0 y la independencia de fwd_a y fwd_b
// No usa números aleatorios: el barrido recorre todo el espacio.
//======================================================================

module forwarding_unit_tb;

    localparam integer NB_ADDR  = 5;
    localparam integer NB_FWD   = 2;
    localparam integer N_REGS   = 1 << NB_ADDR;
    localparam integer T_STEP   = 1;            // ns entre vectores
    localparam integer MAX_TIME = 10000000;     // ns, watchdog (barrido: ~4.2e6 ns)

    // Códigos de fwd_a / fwd_b: literales copiados de la tabla de
    // pipeline.md §5.1, no las constantes de riscv_defs.vh, para que el
    // oráculo no dependa del RTL (como ex_stage_tb)
    localparam [NB_FWD-1:0] SEL_ID_EX  = 2'b00;
    localparam [NB_FWD-1:0] SEL_EX_MEM = 2'b10;
    localparam [NB_FWD-1:0] SEL_WB     = 2'b01;

    reg  [NB_ADDR-1:0] tb_id_ex_rs1;
    reg  [NB_ADDR-1:0] tb_id_ex_rs2;
    reg  [NB_ADDR-1:0] tb_ex_mem_rd;
    reg                tb_ex_mem_reg_write;
    reg  [NB_ADDR-1:0] tb_mem_wb_rd;
    reg                tb_mem_wb_reg_write;
    wire [NB_FWD-1:0]  tb_o_fwd_a;
    wire [NB_FWD-1:0]  tb_o_fwd_b;

    integer errors;
    integer checks;
    integer we;
    integer a;
    integer b;
    integer r1;
    integer r2;

    forwarding_unit #(
        .NB_ADDR (NB_ADDR),
        .NB_FWD  (NB_FWD)
    ) u_dut (
        .i_id_ex_rs1        (tb_id_ex_rs1),
        .i_id_ex_rs2        (tb_id_ex_rs2),
        .i_ex_mem_rd        (tb_ex_mem_rd),
        .i_ex_mem_reg_write (tb_ex_mem_reg_write),
        .i_mem_wb_rd        (tb_mem_wb_rd),
        .i_mem_wb_reg_write (tb_mem_wb_reg_write),
        .o_fwd_a            (tb_o_fwd_a),
        .o_fwd_b            (tb_o_fwd_b)
    );

    //------------------------------------------------------------------
    // Fuente del valor del registro r que lee EX: la instrucción más
    // nueva que lo escribió, o lo leído en ID
    //------------------------------------------------------------------
    function [NB_FWD-1:0] fuente;
        input [NB_ADDR-1:0] r;
        input               mem_escribe;
        input [NB_ADDR-1:0] mem_rd;
        input               wb_escribe;
        input [NB_ADDR-1:0] wb_rd;
        reg                 hallado;
        integer             edad;
        begin
            fuente  = SEL_ID_EX;
            hallado = 1'b0;
            if (r != 0) begin                       // x0 siempre vale 0
                for (edad = 1; edad <= 2; edad = edad + 1) begin
                    if (!hallado) begin
                        if (edad == 1 && mem_escribe && mem_rd == r) begin
                            fuente  = SEL_EX_MEM;   // la anterior, en MEM
                            hallado = 1'b1;
                        end
                        if (edad == 2 && wb_escribe && wb_rd == r) begin
                            fuente  = SEL_WB;       // la de hace dos, en WB
                            hallado = 1'b1;
                        end
                    end
                end
            end
        end
    endfunction

    //------------------------------------------------------------------
    // Aplica un vector y compara fwd_a y fwd_b
    //------------------------------------------------------------------
    task vec;
        input [8*48-1:0]    name;
        input               ex_mem_we;
        input [NB_ADDR-1:0] ex_mem_rd;
        input               mem_wb_we;
        input [NB_ADDR-1:0] mem_wb_rd;
        input [NB_ADDR-1:0] rs1;
        input [NB_ADDR-1:0] rs2;
        reg   [NB_FWD-1:0]  exp_a;
        reg   [NB_FWD-1:0]  exp_b;
        begin
            tb_ex_mem_reg_write = ex_mem_we;
            tb_ex_mem_rd        = ex_mem_rd;
            tb_mem_wb_reg_write = mem_wb_we;
            tb_mem_wb_rd        = mem_wb_rd;
            tb_id_ex_rs1        = rs1;
            tb_id_ex_rs2        = rs2;

            exp_a = fuente(rs1, ex_mem_we, ex_mem_rd, mem_wb_we, mem_wb_rd);
            exp_b = fuente(rs2, ex_mem_we, ex_mem_rd, mem_wb_we, mem_wb_rd);

            #(T_STEP);
            checks = checks + 2;
            if (tb_o_fwd_a !== exp_a) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("[%0t] ERROR %0s fwd_a | ex_mem we=%b rd=%0d mem_wb we=%b rd=%0d rs1=%0d dut=%b esperado=%b",
                             $time, name, ex_mem_we, ex_mem_rd, mem_wb_we, mem_wb_rd, rs1, tb_o_fwd_a, exp_a);
            end
            if (tb_o_fwd_b !== exp_b) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("[%0t] ERROR %0s fwd_b | ex_mem we=%b rd=%0d mem_wb we=%b rd=%0d rs2=%0d dut=%b esperado=%b",
                             $time, name, ex_mem_we, ex_mem_rd, mem_wb_we, mem_wb_rd, rs2, tb_o_fwd_b, exp_b);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors              = 0;
        checks              = 0;
        tb_id_ex_rs1        = {NB_ADDR{1'b0}};
        tb_id_ex_rs2        = {NB_ADDR{1'b0}};
        tb_ex_mem_rd        = {NB_ADDR{1'b0}};
        tb_ex_mem_reg_write = 1'b0;
        tb_mem_wb_rd        = {NB_ADDR{1'b0}};
        tb_mem_wb_reg_write = 1'b0;

        // Dirigidos (orden: ex_mem we, rd, mem_wb we, rd, rs1, rs2)
        vec("sin escrituras",                    1'b0, 5'd5,  1'b0, 5'd5,  5'd5,  5'd5);
        vec("rs1 de EX/MEM",                     1'b1, 5'd5,  1'b0, 5'd0,  5'd5,  5'd6);
        vec("rs2 de EX/MEM (dato de store)",     1'b1, 5'd6,  1'b0, 5'd0,  5'd5,  5'd6);
        vec("rs1 de MEM/WB",                     1'b0, 5'd0,  1'b1, 5'd7,  5'd7,  5'd8);
        vec("rs2 de MEM/WB",                     1'b0, 5'd0,  1'b1, 5'd8,  5'd7,  5'd8);
        vec("las dos escriben rs1: EX/MEM",      1'b1, 5'd9,  1'b1, 5'd9,  5'd9,  5'd1);
        vec("las dos escriben rs2: EX/MEM",      1'b1, 5'd9,  1'b1, 5'd9,  5'd1,  5'd9);
        vec("rs1 = rs2, las dos de EX/MEM",      1'b1, 5'd10, 1'b0, 5'd0,  5'd10, 5'd10);
        vec("rs1 = rs2, las dos de MEM/WB",      1'b0, 5'd0,  1'b1, 5'd10, 5'd10, 5'd10);
        vec("rs1 de EX/MEM, rs2 de MEM/WB",      1'b1, 5'd11, 1'b1, 5'd12, 5'd11, 5'd12);
        vec("rs1 de MEM/WB, rs2 de EX/MEM",      1'b1, 5'd12, 1'b1, 5'd11, 5'd11, 5'd12);
        vec("rd = x0 en EX/MEM no reenvia",      1'b1, 5'd0,  1'b0, 5'd0,  5'd0,  5'd0);
        vec("rd = x0 en MEM/WB no reenvia",      1'b0, 5'd0,  1'b1, 5'd0,  5'd0,  5'd0);
        vec("x0 en las dos no reenvia",          1'b1, 5'd0,  1'b1, 5'd0,  5'd0,  5'd0);
        vec("x0 en EX/MEM no tapa a MEM/WB",     1'b1, 5'd0,  1'b1, 5'd13, 5'd13, 5'd0);
        vec("EX/MEM no escribe: gana MEM/WB",    1'b0, 5'd14, 1'b1, 5'd14, 5'd14, 5'd14);
        vec("MEM/WB no escribe: lo de ID",       1'b0, 5'd14, 1'b0, 5'd14, 5'd14, 5'd14);
        vec("rd distinto: lo de ID",             1'b1, 5'd15, 1'b1, 5'd16, 5'd17, 5'd18);
        vec("x31 de EX/MEM",                     1'b1, 5'd31, 1'b1, 5'd31, 5'd31, 5'd31);

        // Exhaustivo: we = {ex_mem_reg_write, mem_wb_reg_write}
        for (we = 0; we < 4; we = we + 1)
            for (a = 0; a < N_REGS; a = a + 1)
                for (b = 0; b < N_REGS; b = b + 1)
                    for (r1 = 0; r1 < N_REGS; r1 = r1 + 1)
                        for (r2 = 0; r2 < N_REGS; r2 = r2 + 1)
                            vec("exhaustivo", we[1], a[NB_ADDR-1:0], we[0], b[NB_ADDR-1:0],
                                r1[NB_ADDR-1:0], r2[NB_ADDR-1:0]);

        if (errors == 0)
            $display("TEST PASSED: %0d chequeos, 0 errores", checks);
        else
            $display("TEST FAILED: %0d errores sobre %0d chequeos", errors, checks);
        $finish;
    end

    // Watchdog: si la secuencia no termina, falla en vez de colgarse
    initial begin
        #(MAX_TIME);
        $display("TEST FAILED: timeout de %0d ns", MAX_TIME);
        $finish;
    end

endmodule
