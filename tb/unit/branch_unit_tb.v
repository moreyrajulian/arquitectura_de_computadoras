`timescale 1ns / 1ps

//======================================================================
// branch_unit_tb
//
// Testbench autoverificante de branch_unit (docs/spec/verificacion.md
// §3.1, pipeline.md §5.3).
//
// Oráculo, escrito aparte del RTL: el esperado sale de lo que hace cada
// instrucción según isa.md, no de las ecuaciones de §5.3:
//   - beq salta si rs1 == rs2; bne, si rs1 != rs2. El testbench arma
//     alu_out = rs1 - rs2 y zero = (alu_out == 0), como la ALU (§5.2)
//   - jal y jalr saltan siempre
//   - destino: pc + imm (beq, bne, jal); (rs1 + imm) con el bit 0 en 0
//     (jalr), con alu_out = rs1 + imm
//   - el resto de las instrucciones no salta
// Las señales de control de cada instrucción son las de la tabla de
// pipeline.md §4.4 (branch, jal, jalr). Solo se usan las combinaciones
// que genera control_unit: a lo sumo una de las tres en 1. Con branch = 1
// solo se prueban funct3 = 000 (beq) y 001 (bne): un blt recibe la fila
// de branch y su resultado no está especificado (decisión 024).
// redirect_pc se compara solo cuando hay salto: IF lo usa únicamente con
// redirect = 1 (§3.1).
//
// Casos:
//   - beq y bne, tomados y no tomados, con zero en 0 y en 1
//   - Salto hacia atrás (inmediato negativo), máximos de B y J, y pc + imm
//     que pasa por 2^32
//   - jal y jalr siempre redirect, con cualquier zero y funct3
//   - jalr con el bit 0 en 1 a la entrada; destino que no depende de
//     pc + imm, y jal y branch que no dependen de alu_out
//   - Sin salto -> redirect = 0, con cualquier zero y funct3
//   - Barrido: cada instrucción × zero × los funct3 posibles, con datos
//     al azar
//   - Aleatorio con semilla fija: instrucción, operandos, pc e inmediato
//======================================================================

module branch_unit_tb;

    localparam integer NB_PC     = 32;
    localparam integer NB_DATA   = 32;
    localparam integer NB_FUNCT3 = 3;
    localparam integer T_STEP    = 10;      // ns entre vectores
    localparam integer N_BARRIDO = 20;      // vectores por combinación del barrido
    localparam integer N_RANDOM  = 10000;   // vectores aleatorios
    localparam integer MAX_TIME  = 500000;  // ns, watchdog
    localparam integer SEED      = 41;      // semilla fija (issue #41)

    // Instrucción que está en EX
    localparam integer T_OTRA = 0;          // no es de control de flujo
    localparam integer T_BEQ  = 1;
    localparam integer T_BNE  = 2;
    localparam integer T_JAL  = 3;
    localparam integer T_JALR = 4;

    reg                  tb_branch;
    reg                  tb_jal;
    reg                  tb_jalr;
    reg  [NB_FUNCT3-1:0] tb_funct3;
    reg  [NB_PC-1:0]     tb_pc;
    reg  [NB_DATA-1:0]   tb_imm;
    reg                  tb_zero;
    reg  [NB_DATA-1:0]   tb_alu_out;
    wire                 tb_o_redirect;
    wire [NB_PC-1:0]     tb_o_redirect_pc;

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer t;
    integer z;
    integer f;
    integer k;

    reg [NB_DATA-1:0]   rs1;
    reg [NB_DATA-1:0]   rs2;
    reg [NB_DATA-1:0]   imm;
    reg [NB_PC-1:0]     pc;
    reg [NB_DATA-1:0]   r;
    reg [NB_FUNCT3-1:0] f3;

    branch_unit #(
        .NB_PC     (NB_PC),
        .NB_DATA   (NB_DATA),
        .NB_FUNCT3 (NB_FUNCT3)
    ) u_dut (
        .i_branch      (tb_branch),
        .i_jal         (tb_jal),
        .i_jalr        (tb_jalr),
        .i_funct3      (tb_funct3),
        .i_pc          (tb_pc),
        .i_imm         (tb_imm),
        .i_zero        (tb_zero),
        .i_alu_out     (tb_alu_out),
        .o_redirect    (tb_o_redirect),
        .o_redirect_pc (tb_o_redirect_pc)
    );

    //------------------------------------------------------------------
    // Aplica un vector y compara contra lo que hace la instrucción.
    // zero y alu_out entran tal cual, para poder probar cada valor de
    // zero aunque no coincida con alu_out.
    //------------------------------------------------------------------
    task vec;
        input [8*40-1:0]      name;
        input integer         tipo;
        input [NB_FUNCT3-1:0] funct3;
        input [NB_PC-1:0]     pc_in;
        input [NB_DATA-1:0]   imm_in;
        input                 zero;
        input [NB_DATA-1:0]   alu_out;
        reg                   exp_redirect;
        reg   [NB_PC-1:0]     exp_pc;
        begin
            // Control de la instrucción (pipeline.md §4.4)
            tb_branch  = (tipo == T_BEQ) || (tipo == T_BNE);
            tb_jal     = (tipo == T_JAL);
            tb_jalr    = (tipo == T_JALR);
            tb_funct3  = funct3;
            tb_pc      = pc_in;
            tb_imm     = imm_in;
            tb_zero    = zero;
            tb_alu_out = alu_out;

            // Lo que hace la instrucción (isa.md)
            case (tipo)
                T_BEQ:   exp_redirect = (zero == 1'b1);   // rs1 - rs2 == 0
                T_BNE:   exp_redirect = (zero == 1'b0);
                T_JAL:   exp_redirect = 1'b1;
                T_JALR:  exp_redirect = 1'b1;
                default: exp_redirect = 1'b0;
            endcase
            if (tipo == T_JALR)
                exp_pc = alu_out & ~32'h1;                // (rs1 + imm) & ~1
            else
                exp_pc = pc_in + imm_in;

            #(T_STEP);
            checks = checks + 1;
            if (tb_o_redirect !== exp_redirect) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s redirect | tipo=%0d funct3=%b zero=%b dut=%b esperado=%b",
                         $time, name, tipo, funct3, zero, tb_o_redirect, exp_redirect);
            end
            if (exp_redirect) begin
                checks = checks + 1;
                if (tb_o_redirect_pc !== exp_pc) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR %0s redirect_pc | tipo=%0d pc=0x%08h imm=0x%08h alu_out=0x%08h dut=0x%08h esperado=0x%08h",
                             $time, name, tipo, pc_in, imm_in, alu_out, tb_o_redirect_pc, exp_pc);
                end
            end
        end
    endtask

    // beq / bne con los operandos de la instrucción: la ALU resta (§5.3)
    task salto_cond;
        input [8*40-1:0]    name;
        input integer       tipo;
        input [NB_DATA-1:0] a;
        input [NB_DATA-1:0] b;
        input [NB_PC-1:0]   pc_in;
        input [NB_DATA-1:0] imm_in;
        reg   [NB_DATA-1:0] resta;
        begin
            resta = a - b;
            vec(name, tipo, (tipo == T_BNE) ? 3'b001 : 3'b000, pc_in, imm_in,
                (resta == 0), resta);
        end
    endtask

    // jalr con la ALU calculando rs1 + imm
    task jalr;
        input [8*40-1:0]    name;
        input [NB_DATA-1:0] a;
        input [NB_PC-1:0]   pc_in;
        input [NB_DATA-1:0] imm_in;
        reg   [NB_DATA-1:0] suma;
        begin
            suma = a + imm_in;
            vec(name, T_JALR, 3'b000, pc_in, imm_in, (suma == 0), suma);
        end
    endtask

    //------------------------------------------------------------------
    // Inmediatos con la forma de cada formato (pipeline.md §4.3)
    //------------------------------------------------------------------
    function [NB_DATA-1:0] imm_b;           // múltiplo de 2, 13 bits con signo
        input [NB_DATA-1:0] v;
        begin
            imm_b = {{19{v[12]}}, v[12:1], 1'b0};
        end
    endfunction

    function [NB_DATA-1:0] imm_j;           // múltiplo de 2, 21 bits con signo
        input [NB_DATA-1:0] v;
        begin
            imm_j = {{11{v[20]}}, v[20:1], 1'b0};
        end
    endfunction

    function [NB_DATA-1:0] imm_i;           // 12 bits con signo
        input [NB_DATA-1:0] v;
        begin
            imm_i = {{20{v[11]}}, v[11:0]};
        end
    endfunction

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors     = 0;
        checks     = 0;
        seed       = SEED;
        tb_branch  = 1'b0;
        tb_jal     = 1'b0;
        tb_jalr    = 1'b0;
        tb_funct3  = {NB_FUNCT3{1'b0}};
        tb_pc      = {NB_PC{1'b0}};
        tb_imm     = {NB_DATA{1'b0}};
        tb_zero    = 1'b0;
        tb_alu_out = {NB_DATA{1'b0}};

        // beq y bne, tomados y no tomados
        salto_cond("beq tomado",            T_BEQ, 32'd5, 32'd5, 32'h0000_0100, 32'd8);
        salto_cond("beq no tomado",         T_BEQ, 32'd5, 32'd6, 32'h0000_0100, 32'd8);
        salto_cond("bne tomado",            T_BNE, 32'd5, 32'd6, 32'h0000_0100, 32'd8);
        salto_cond("bne no tomado",         T_BNE, 32'd5, 32'd5, 32'h0000_0100, 32'd8);
        salto_cond("beq negativos iguales", T_BEQ, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_0010, 32'd4);
        salto_cond("bne x0 contra -1",      T_BNE, 32'h0000_0000, 32'hFFFF_FFFF, 32'h0000_0010, 32'd4);
        salto_cond("beq solo bit 31",       T_BEQ, 32'h8000_0000, 32'h0000_0000, 32'h0000_0010, 32'd4);

        // Hacia atrás, máximos de B y J y paso por 2^32
        salto_cond("bne hacia atras -16",   T_BNE, 32'd1, 32'd2, 32'h0000_0040, 32'hFFFF_FFF0);
        salto_cond("beq hacia atras -4096", T_BEQ, 32'd7, 32'd7, 32'h0000_1000, 32'hFFFF_F000);
        salto_cond("beq maximo +4094",      T_BEQ, 32'd7, 32'd7, 32'h0000_0004, 32'h0000_0FFE);
        salto_cond("beq a si mismo",        T_BEQ, 32'd0, 32'd0, 32'h0000_0200, 32'h0000_0000);
        salto_cond("bne pasa por 2^32",     T_BNE, 32'd1, 32'd0, 32'hFFFF_FFFC, 32'h0000_0008);
        vec("jal hacia adelante",   T_JAL, 3'b000, 32'h0000_0100, 32'h0000_0020, 1'b0, 32'h0000_0000);
        vec("jal hacia atras",      T_JAL, 3'b101, 32'h0000_0100, 32'hFFFF_FF00, 1'b1, 32'h0000_0000);
        vec("jal maximo +1048574",  T_JAL, 3'b111, 32'h0000_0000, 32'h000F_FFFE, 1'b0, 32'h0000_0000);
        vec("jal minimo -1048576",  T_JAL, 3'b010, 32'h0010_0000, 32'hFFF0_0000, 1'b1, 32'h0000_0000);

        // jal y branch no miran alu_out: alu_out distinto de pc + imm
        vec("jal ignora alu_out",   T_JAL, 3'b000, 32'h0000_0100, 32'h0000_0010, 1'b0, 32'h0000_0FFF);
        vec("beq ignora alu_out",   T_BEQ, 3'b000, 32'h0000_0100, 32'h0000_0010, 1'b1, 32'h0000_0FFF);
        vec("bne ignora alu_out",   T_BNE, 3'b001, 32'h0000_0100, 32'h0000_0010, 1'b0, 32'h0000_0FFF);

        // jalr: rs1 + imm con el bit 0 en 0, no pc + imm
        jalr("jalr bit 0 en 1",         32'h0000_0101, 32'h0000_0040, 32'h0000_0000);
        jalr("jalr bit 0 en 1 por imm", 32'h0000_0200, 32'h0000_0040, 32'hFFFF_FFFD);
        jalr("jalr par queda igual",    32'h0000_0300, 32'h0000_0040, 32'h0000_0004);
        jalr("jalr a 0 (zero = 1)",     32'h0000_0004, 32'h0000_0040, 32'hFFFF_FFFC);
        jalr("jalr a 1 da 0",           32'h0000_0000, 32'h0000_0040, 32'h0000_0001);
        jalr("jalr todo en 1",          32'hFFFF_FFFF, 32'h0000_0040, 32'h0000_0000);
        vec("jalr ignora pc + imm, zero 0", T_JALR, 3'b000, 32'h0000_0100, 32'h0000_0010, 1'b0, 32'h0000_0801);
        vec("jalr ignora pc + imm, zero 1", T_JALR, 3'b000, 32'h0000_0100, 32'h0000_0010, 1'b1, 32'h0000_0801);

        // Sin salto: redirect = 0 aunque zero y funct3 hagan saltar a un branch
        vec("otra, zero 1, funct3 000",  T_OTRA, 3'b000, 32'h0000_0100, 32'h0000_0008, 1'b1, 32'h0000_0000);
        vec("otra, zero 0, funct3 001",  T_OTRA, 3'b001, 32'h0000_0100, 32'h0000_0008, 1'b0, 32'h0000_0005);
        vec("otra, alu_out impar",       T_OTRA, 3'b000, 32'h0000_0100, 32'h0000_0008, 1'b0, 32'h0000_0101);

        // Barrido: instrucción × zero × funct3 posibles, con datos al azar
        for (t = T_OTRA; t <= T_JALR; t = t + 1) begin
            for (z = 0; z < 2; z = z + 1) begin
                for (f = 0; f < (1 << NB_FUNCT3); f = f + 1) begin
                    f3 = f;
                    // beq solo con 000 y bne solo con 001 (decisión 024)
                    if (!((t == T_BEQ && f3 != 3'b000) || (t == T_BNE && f3 != 3'b001))) begin
                        for (k = 0; k < N_BARRIDO; k = k + 1) begin
                            pc = $random(seed);
                            r  = $random(seed);
                            vec("barrido", t, f3, {pc[NB_PC-1:2], 2'b00}, r,
                                z[0], $random(seed));
                        end
                    end
                end
            end
        end

        // Aleatorio: instrucción, operandos (iguales 1 de cada 4), pc e inmediato
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            t   = {$random(seed)} % 5;
            rs1 = $random(seed);
            rs2 = (({$random(seed)} % 4) == 0) ? rs1 : $random(seed);
            pc  = $random(seed);
            pc  = {pc[NB_PC-1:2], 2'b00};
            r   = $random(seed);
            case (t)
                T_BEQ, T_BNE: salto_cond("aleatorio", t, rs1, rs2, pc, imm_b(r));
                T_JALR:       jalr("aleatorio", rs1, pc, imm_i(r));
                T_JAL: begin
                    imm = imm_j(r);
                    vec("aleatorio", T_JAL, $random(seed), pc, imm,
                        ((rs1 + imm) == 0), rs1 + imm);
                end
                default: begin
                    r = $random(seed);
                    vec("aleatorio", T_OTRA, $random(seed), pc, imm_i(r),
                        ((rs1 + rs2) == 0), rs1 + rs2);
                end
            endcase
        end

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
