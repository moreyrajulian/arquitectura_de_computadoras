`timescale 1ns / 1ps

//======================================================================
// hazard_unit_tb
//
// Testbench autoverificante de hazard_unit (docs/spec/verificacion.md
// §3.2, pipeline.md §10.3, decisión 011). Esta versión cubre el
// detector de carga-uso (I-41); los enables y el flush se suman en I-42.
//
// Oráculo, escrito aparte del RTL: la instrucción en ID tiene que
// esperar si alguno de los dos registros que nombra (los campos rs1 y
// rs2, sin decodificar) es el que carga el load en EX, porque ese valor
// recién existe en WB. Un load a x0 no deja ningún valor, una
// instrucción que no es load no se espera y una burbuja en ID no lee
// registros.
//
// Casos:
//   - Dirigidos con palabras reales de los programas de sw/ (ensambladas
//     con rvasm), de las que el testbench saca rs1 = [19:15] y
//     rs2 = [24:20]: uso en rs1, en rs2 y en los dos; sw que guarda el
//     dato y beq que lo compara (frenan, decisión 011); rd = x0,
//     mem_read = 0 e if_id_valid = 0 no frenan; instrucción que no
//     depende del load. Falsos positivos conocidos, que frenan y es
//     correcto: HALT (rs2 = 1) tras un load a x1, lui y jal con el
//     número de registro en el inmediato, y addi con el inmediato en
//     el campo rs2
//   - Exhaustivo: todas las combinaciones de if_id_valid,
//     id_ex_mem_read, id_ex_rd, if_id_rs1 e if_id_rs2
//     (2 * 2 * 32^3 = 131072 vectores)
// No usa números aleatorios: el barrido recorre todo el espacio.
//======================================================================

module hazard_unit_tb;

    localparam integer NB_ADDR  = 5;
    localparam integer NB_INSTR = 32;
    localparam integer N_REGS   = 1 << NB_ADDR;
    localparam integer T_STEP   = 1;            // ns entre vectores
    localparam integer MAX_TIME = 1000000;      // ns, watchdog (barrido: ~1.3e5 ns)

    // Palabras de rvasm (comentario: la instrucción). Los campos se sacan
    // en el testbench, como en riscv_core
    localparam [NB_INSTR-1:0] W_ADD_RS1  = 32'h0002_8333;  // add  x6, x5, x0
    localparam [NB_INSTR-1:0] W_SUB_RS2  = 32'h4070_0433;  // sub  x8, x0, x7
    localparam [NB_INSTR-1:0] W_ADD_DOS  = 32'h0094_8533;  // add  x10, x9, x9
    localparam [NB_INSTR-1:0] W_SW_DATO  = 32'h0050_2223;  // sw   x5, 4(x0)
    localparam [NB_INSTR-1:0] W_BEQ      = 32'h0023_0463;  // beq  x6, x2, 8
    localparam [NB_INSTR-1:0] W_LUI      = 32'h0003_82B7;  // lui  x5, 0x38   (rs1 = 7)
    localparam [NB_INSTR-1:0] W_JAL      = 32'h0080_00EF;  // jal  x1, 8      (rs2 = 8)
    localparam [NB_INSTR-1:0] W_ADDI     = 32'h0070_0193;  // addi x3, x0, 7  (rs2 = 7)
    localparam [NB_INSTR-1:0] W_HALT     = 32'h0010_0073;  // halt            (rs2 = 1)

    reg                tb_if_id_valid;
    reg  [NB_ADDR-1:0] tb_if_id_rs1;
    reg  [NB_ADDR-1:0] tb_if_id_rs2;
    reg                tb_id_ex_mem_read;
    reg  [NB_ADDR-1:0] tb_id_ex_rd;
    wire               tb_o_load_use;

    integer errors;
    integer checks;
    integer vm;
    integer rd;
    integer r1;
    integer r2;

    hazard_unit #(
        .NB_ADDR (NB_ADDR)
    ) u_dut (
        .i_if_id_valid    (tb_if_id_valid),
        .i_if_id_rs1      (tb_if_id_rs1),
        .i_if_id_rs2      (tb_if_id_rs2),
        .i_id_ex_mem_read (tb_id_ex_mem_read),
        .i_id_ex_rd       (tb_id_ex_rd),
        .o_load_use       (tb_o_load_use)
    );

    //------------------------------------------------------------------
    // ¿La instrucción en ID nombra un registro cuyo valor todavía no
    // existe? Recorre sus dos campos de registro fuente
    //------------------------------------------------------------------
    function espera;
        input               valid;
        input [NB_ADDR-1:0] rs1;
        input [NB_ADDR-1:0] rs2;
        input               es_load;
        input [NB_ADDR-1:0] load_rd;
        reg   [NB_ADDR-1:0] campo;
        integer             k;
        begin
            espera = 1'b0;
            if (valid && es_load && load_rd != 0) begin    // x0 siempre vale 0
                for (k = 0; k < 2; k = k + 1) begin
                    campo = (k == 0) ? rs1 : rs2;
                    if (campo == load_rd)
                        espera = 1'b1;
                end
            end
        end
    endfunction

    //------------------------------------------------------------------
    // Aplica un vector y compara load_use
    //------------------------------------------------------------------
    task vec;
        input [8*56-1:0]    name;
        input               valid;
        input [NB_ADDR-1:0] rs1;
        input [NB_ADDR-1:0] rs2;
        input               mem_read;
        input [NB_ADDR-1:0] load_rd;
        reg                 exp_load_use;
        begin
            tb_if_id_valid    = valid;
            tb_if_id_rs1      = rs1;
            tb_if_id_rs2      = rs2;
            tb_id_ex_mem_read = mem_read;
            tb_id_ex_rd       = load_rd;

            exp_load_use = espera(valid, rs1, rs2, mem_read, load_rd);

            #(T_STEP);
            checks = checks + 1;
            if (tb_o_load_use !== exp_load_use) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("[%0t] ERROR %0s load_use | valid=%b rs1=%0d rs2=%0d mem_read=%b rd=%0d dut=%b esperado=%b",
                             $time, name, valid, rs1, rs2, mem_read, load_rd, tb_o_load_use, exp_load_use);
            end
        end
    endtask

    // Vector dirigido con una palabra real en ID y el valor esperado
    // escrito a mano (además del oráculo)
    task instr;
        input [8*56-1:0]     name;
        input [NB_INSTR-1:0] word;
        input                valid;
        input                mem_read;
        input [NB_ADDR-1:0]  load_rd;
        input                exp_manual;
        begin
            vec(name, valid, word[19:15], word[24:20], mem_read, load_rd);
            checks = checks + 1;
            if (tb_o_load_use !== exp_manual) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s load_use | instr=0x%08h dut=%b esperado=%b",
                         $time, name, word, tb_o_load_use, exp_manual);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors            = 0;
        checks            = 0;
        tb_if_id_valid    = 1'b0;
        tb_if_id_rs1      = {NB_ADDR{1'b0}};
        tb_if_id_rs2      = {NB_ADDR{1'b0}};
        tb_id_ex_mem_read = 1'b0;
        tb_id_ex_rd       = {NB_ADDR{1'b0}};

        // Dirigidos (orden: palabra en ID, valid, mem_read, rd del load, esperado)
        instr("uso en rs1 (lw x5; add x6, x5, x0)",     W_ADD_RS1, 1'b1, 1'b1, 5'd5,  1'b1);
        instr("uso en rs2 (lw x7; sub x8, x0, x7)",     W_SUB_RS2, 1'b1, 1'b1, 5'd7,  1'b1);
        instr("uso en los dos (lw x9; add x10, x9, x9)", W_ADD_DOS, 1'b1, 1'b1, 5'd9,  1'b1);
        instr("sw guarda el dato (lw x5; sw x5)",       W_SW_DATO, 1'b1, 1'b1, 5'd5,  1'b1);
        instr("beq compara el dato (lw x6; beq x6)",    W_BEQ,     1'b1, 1'b1, 5'd6,  1'b1);
        instr("sin dependencia (lw x4; add x6, x5)",    W_ADD_RS1, 1'b1, 1'b1, 5'd4,  1'b0);
        instr("mem_read = 0 no frena (rd = x5, no es load)", W_ADD_RS1, 1'b1, 1'b0, 5'd5,  1'b0);
        instr("burbuja en ID no frena",                 W_ADD_RS1, 1'b0, 1'b1, 5'd5,  1'b0);
        instr("load a x0 no frena (rs2 = x0)",          W_ADD_RS1, 1'b1, 1'b1, 5'd0,  1'b0);
        instr("falso positivo: HALT tras lw x1",        W_HALT,    1'b1, 1'b1, 5'd1,  1'b1);
        instr("falso positivo: lui con rs1 = 7",        W_LUI,     1'b1, 1'b1, 5'd7,  1'b1);
        instr("falso positivo: jal con rs2 = 8",        W_JAL,     1'b1, 1'b1, 5'd8,  1'b1);
        instr("falso positivo: addi con imm en rs2",    W_ADDI,    1'b1, 1'b1, 5'd7,  1'b1);
        instr("HALT tras lw x0: no frena",              W_HALT,    1'b1, 1'b1, 5'd0,  1'b0);
        instr("HALT en burbuja: no frena",              W_HALT,    1'b0, 1'b1, 5'd1,  1'b0);
        vec("x31 en rs1 y en rs2",                      1'b1, 5'd31, 5'd31, 1'b1, 5'd31);

        // Exhaustivo: vm = {if_id_valid, id_ex_mem_read}
        for (vm = 0; vm < 4; vm = vm + 1)
            for (rd = 0; rd < N_REGS; rd = rd + 1)
                for (r1 = 0; r1 < N_REGS; r1 = r1 + 1)
                    for (r2 = 0; r2 < N_REGS; r2 = r2 + 1)
                        vec("exhaustivo", vm[1], r1[NB_ADDR-1:0], r2[NB_ADDR-1:0],
                            vm[0], rd[NB_ADDR-1:0]);

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
