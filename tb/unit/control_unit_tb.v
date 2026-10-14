`timescale 1ns / 1ps

//======================================================================
// control_unit_tb
//
// Testbench autoverificante de control_unit (docs/spec/verificacion.md
// §3.1). Exhaustivo sobre lo que mira la unidad: opcode, funct3,
// instr[30], valid y la palabra del HALT.
//
// Compara las 12 señales contra la tabla de verdad de pipeline.md §4.4
// y §4.5, escrita acá aparte del RTL. Los códigos (filas, alu_ctrl,
// imm_sel de §4.3) son literales copiados de la spec: el testbench no
// incluye riscv_defs.vh, así que también verifica las constantes que usa
// control_unit (OPCODE_*, INSTR_HALT, FUNCT3_SRL_SRA, ALU_ADD, ALU_SUB e
// IMM_*; verificacion.md §3.1, fila de I-18). El resto de los ALU_* no
// pasa por este módulo: alu_ctrl se arma con {instr[30], funct3}.
//
// Casos:
//   - Dirigidos: una palabra por cada fila de isa.md, ensamblada con
//     rvasm, y su fila esperada; cada una también con valid = 0 (todo
//     en 0). I aritméticas con inmediato negativo (instr[30] = 1) no son
//     resta; slli/srli/srai con shamt 0 y 31; NOP canónica; jal x0
//   - HALT: con valid = 1 solo activa halt; con valid = 0 todo en 0;
//     las 32 palabras a un bit del HALT no activan halt
//   - NOP (no reconocidas): 0x0000_0000, ecall, 0xFFFF_FFFF, auipc,
//     fence, otras SYSTEM (pipeline.md §4.4, decisión 024)
//   - Barrido exhaustivo: 128 opcodes x 8 funct3 x 2 instr[30] x
//     2 valid, con el resto de los bits al azar. Un opcode conocido
//     recibe la fila de su opcode aunque funct3/funct7 no estén en
//     isa.md (decisión 024)
//   - Aleatorio: N_RANDOM palabras y valid al azar, con semilla fija
//
// Es combinacional: cada vector se aplica y se comprueba T_STEP después.
// Dura ~15 µs de simulación: en xsim, correr con run all.
//======================================================================

module control_unit_tb;

    localparam integer NB_INSTR    = 32;
    localparam integer NB_IMM_SEL  = 3;
    localparam integer NB_ALU_CTRL = 4;
    localparam integer NB_CTL      = NB_IMM_SEL + NB_ALU_CTRL + 10;  // las 12 señales
    localparam integer T_STEP      = 1;       // ns entre vectores
    localparam integer N_RANDOM    = 10000;   // palabras aleatorias
    localparam integer MAX_TIME    = 50000;   // ns, watchdog
    localparam integer SEED        = 36;      // semilla fija (issue #36)

    localparam [NB_INSTR-1:0] HALT = 32'h0010_0073;   // decisión 001

    // alu_ctrl (pipeline.md §4.5)
    localparam [3:0] SPEC_ALU_ADD  = 4'b0000;
    localparam [3:0] SPEC_ALU_SUB  = 4'b1000;
    localparam [3:0] SPEC_ALU_SLL  = 4'b0001;
    localparam [3:0] SPEC_ALU_SLT  = 4'b0010;
    localparam [3:0] SPEC_ALU_SLTU = 4'b0011;
    localparam [3:0] SPEC_ALU_XOR  = 4'b0100;
    localparam [3:0] SPEC_ALU_SRL  = 4'b0101;
    localparam [3:0] SPEC_ALU_SRA  = 4'b1101;
    localparam [3:0] SPEC_ALU_OR   = 4'b0110;
    localparam [3:0] SPEC_ALU_AND  = 4'b0111;

    //------------------------------------------------------------------
    // Filas de la tabla de verdad de pipeline.md §4.4 ("x" = 0), con
    // imm_sel de §4.3 (I = 000, S = 001, B = 010, U = 011, J = 100).
    // Orden: imm_sel, alu_ctrl, alu_src_a, alu_src_b, branch, jal, jalr,
    //        mem_read, mem_write, reg_write, mem_to_reg, halt
    //------------------------------------------------------------------
    //                                imm_sel alu_ctrl a     b     br    jal   jalr  mr    mw    rw    m2r   halt
    localparam [NB_CTL-1:0] FILA_LOAD   = {3'b000, 4'b0000, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0};
    localparam [NB_CTL-1:0] FILA_STORE  = {3'b001, 4'b0000, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0};
    localparam [NB_CTL-1:0] FILA_BRANCH = {3'b010, 4'b1000, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0};
    localparam [NB_CTL-1:0] FILA_JAL    = {3'b100, 4'b0000, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0};
    localparam [NB_CTL-1:0] FILA_JALR   = {3'b000, 4'b0000, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0};
    localparam [NB_CTL-1:0] FILA_LUI    = {3'b011, 4'b0000, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0};
    localparam [NB_CTL-1:0] FILA_HALT   = {3'b000, 4'b0000, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1};
    localparam [NB_CTL-1:0] FILA_NOP    = {NB_CTL{1'b0}};   // no reconocida y burbuja

    // R-type e I aritmética: la fila depende de alu_ctrl
    function [NB_CTL-1:0] fila_r;
        input [3:0] alu_ctrl;
        begin
            fila_r = {3'b000, alu_ctrl, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0};
        end
    endfunction

    function [NB_CTL-1:0] fila_i;
        input [3:0] alu_ctrl;
        begin
            fila_i = {3'b000, alu_ctrl, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0};
        end
    endfunction

    //------------------------------------------------------------------
    // Modelo: la tabla de §4.4 por opcode, con el HALT por palabra
    // completa (decisión 001) y alu_ctrl según §4.5
    //------------------------------------------------------------------
    function [NB_CTL-1:0] modelo;
        input                valid;
        input [NB_INSTR-1:0] word;
        reg   [2:0]          f3;
        reg                  b30;
        begin
            f3     = word[14:12];
            b30    = word[30];
            modelo = FILA_NOP;
            if (valid) begin
                if (word == HALT)
                    modelo = FILA_HALT;
                else begin
                    case (word[6:0])
                        7'b0110011: modelo = fila_r({b30, f3});
                        7'b0010011: modelo = fila_i({(f3 == 3'b101) & b30, f3});
                        7'b0000011: modelo = FILA_LOAD;
                        7'b0100011: modelo = FILA_STORE;
                        7'b1100011: modelo = FILA_BRANCH;
                        7'b1101111: modelo = FILA_JAL;
                        7'b1100111: modelo = FILA_JALR;
                        7'b0110111: modelo = FILA_LUI;
                        default:    modelo = FILA_NOP;
                    endcase
                end
            end
        end
    endfunction

    reg                    tb_valid;
    reg  [NB_INSTR-1:0]    tb_instr;
    wire [NB_IMM_SEL-1:0]  tb_o_imm_sel;
    wire [NB_ALU_CTRL-1:0] tb_o_alu_ctrl;
    wire                   tb_o_alu_src_a;
    wire                   tb_o_alu_src_b;
    wire                   tb_o_branch;
    wire                   tb_o_jal;
    wire                   tb_o_jalr;
    wire                   tb_o_mem_read;
    wire                   tb_o_mem_write;
    wire                   tb_o_reg_write;
    wire                   tb_o_mem_to_reg;
    wire                   tb_o_halt;

    // Las 12 salidas en el orden de las filas
    wire [NB_CTL-1:0] tb_o_ctl = {tb_o_imm_sel, tb_o_alu_ctrl, tb_o_alu_src_a,
                                  tb_o_alu_src_b, tb_o_branch, tb_o_jal, tb_o_jalr,
                                  tb_o_mem_read, tb_o_mem_write, tb_o_reg_write,
                                  tb_o_mem_to_reg, tb_o_halt};

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer op;
    integer f3;
    integer b30;
    integer v;

    reg [NB_INSTR-1:0] word;

    control_unit #(
        .NB_INSTR    (NB_INSTR),
        .NB_IMM_SEL  (NB_IMM_SEL),
        .NB_ALU_CTRL (NB_ALU_CTRL)
    ) u_dut (
        .i_valid      (tb_valid),
        .i_instr      (tb_instr),
        .o_imm_sel    (tb_o_imm_sel),
        .o_alu_ctrl   (tb_o_alu_ctrl),
        .o_alu_src_a  (tb_o_alu_src_a),
        .o_alu_src_b  (tb_o_alu_src_b),
        .o_branch     (tb_o_branch),
        .o_jal        (tb_o_jal),
        .o_jalr       (tb_o_jalr),
        .o_mem_read   (tb_o_mem_read),
        .o_mem_write  (tb_o_mem_write),
        .o_reg_write  (tb_o_reg_write),
        .o_mem_to_reg (tb_o_mem_to_reg),
        .o_halt       (tb_o_halt)
    );

    //------------------------------------------------------------------
    // Una línea por señal distinta, para que el log diga cuál falló
    //------------------------------------------------------------------
    task campo;
        input [8*12-1:0] name;
        input [3:0]      obtenido;
        input [3:0]      esperado;
        begin
            if (obtenido !== esperado)
                $display("        %0s dut=%b esperado=%b", name, obtenido, esperado);
        end
    endtask

    task chk;
        input [8*32-1:0]   name;
        input [NB_CTL-1:0] esperado;
        begin
            checks = checks + 1;
            if (tb_o_ctl !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | instr=0x%08h valid=%0b",
                         $time, name, tb_instr, tb_valid);
                campo("imm_sel",    tb_o_ctl[16:14], esperado[16:14]);
                campo("alu_ctrl",   tb_o_ctl[13:10], esperado[13:10]);
                campo("alu_src_a",  tb_o_ctl[9],     esperado[9]);
                campo("alu_src_b",  tb_o_ctl[8],     esperado[8]);
                campo("branch",     tb_o_ctl[7],     esperado[7]);
                campo("jal",        tb_o_ctl[6],     esperado[6]);
                campo("jalr",       tb_o_ctl[5],     esperado[5]);
                campo("mem_read",   tb_o_ctl[4],     esperado[4]);
                campo("mem_write",  tb_o_ctl[3],     esperado[3]);
                campo("reg_write",  tb_o_ctl[2],     esperado[2]);
                campo("mem_to_reg", tb_o_ctl[1],     esperado[1]);
                campo("halt",       tb_o_ctl[0],     esperado[0]);
            end
        end
    endtask

    task aplicar;
        input                valid;
        input [NB_INSTR-1:0] instr;
        begin
            tb_valid = valid;
            tb_instr = instr;
            #(T_STEP);
        end
    endtask

    // Fila escrita a mano para una instrucción de isa.md; también
    // comprueba que el modelo da lo mismo y que con valid = 0 es burbuja
    task dirigido;
        input [8*32-1:0]     name;
        input [NB_INSTR-1:0] instr;
        input [NB_CTL-1:0]   esperado;
        begin
            checks = checks + 1;
            if (modelo(1'b1, instr) !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | el modelo del testbench no coincide con la fila escrita a mano",
                         $time, name);
            end
            aplicar(1'b1, instr);
            chk(name, esperado);
            aplicar(1'b0, instr);
            chk("burbuja (valid = 0)", FILA_NOP);
        end
    endtask

    task no_reconocida;
        input [8*32-1:0]     name;
        input [NB_INSTR-1:0] instr;
        begin
            aplicar(1'b1, instr);
            chk(name, FILA_NOP);
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors   = 0;
        checks   = 0;
        seed     = SEED;
        tb_valid = 1'b0;
        tb_instr = {NB_INSTR{1'b0}};
        #(T_STEP);

        // 1. Una palabra por fila de isa.md (rvasm)
        dirigido("add x3, x1, x2",      32'h0020_81b3, fila_r(SPEC_ALU_ADD));
        dirigido("sub x3, x1, x2",      32'h4020_81b3, fila_r(SPEC_ALU_SUB));
        dirigido("sll x3, x1, x2",      32'h0020_91b3, fila_r(SPEC_ALU_SLL));
        dirigido("srl x3, x1, x2",      32'h0020_d1b3, fila_r(SPEC_ALU_SRL));
        dirigido("sra x3, x1, x2",      32'h4020_d1b3, fila_r(SPEC_ALU_SRA));
        dirigido("and x3, x1, x2",      32'h0020_f1b3, fila_r(SPEC_ALU_AND));
        dirigido("or x3, x1, x2",       32'h0020_e1b3, fila_r(SPEC_ALU_OR));
        dirigido("xor x3, x1, x2",      32'h0020_c1b3, fila_r(SPEC_ALU_XOR));
        dirigido("slt x3, x1, x2",      32'h0020_a1b3, fila_r(SPEC_ALU_SLT));
        dirigido("sltu x3, x1, x2",     32'h0020_b1b3, fila_r(SPEC_ALU_SLTU));

        dirigido("lb x5, -1(x6)",       32'hfff3_0283, FILA_LOAD);
        dirigido("lh x5, 2(x6)",        32'h0023_1283, FILA_LOAD);
        dirigido("lw x5, -4(x6)",       32'hffc3_2283, FILA_LOAD);
        dirigido("lbu x5, 2047(x6)",    32'h7ff3_4283, FILA_LOAD);
        dirigido("lhu x5, -2048(x6)",   32'h8003_5283, FILA_LOAD);

        // inmediato negativo: instr[30] = 1 y no es resta (§4.5)
        dirigido("addi x5, x6, -1",     32'hfff3_0293, fila_i(SPEC_ALU_ADD));
        dirigido("andi x5, x6, -1",     32'hfff3_7293, fila_i(SPEC_ALU_AND));
        dirigido("ori x5, x6, -2048",   32'h8003_6293, fila_i(SPEC_ALU_OR));
        dirigido("xori x5, x6, -1",     32'hfff3_4293, fila_i(SPEC_ALU_XOR));
        dirigido("slti x5, x6, -1",     32'hfff3_2293, fila_i(SPEC_ALU_SLT));
        dirigido("sltiu x5, x6, -1",    32'hfff3_3293, fila_i(SPEC_ALU_SLTU));
        dirigido("slli x5, x6, 31",     32'h01f3_1293, fila_i(SPEC_ALU_SLL));
        dirigido("srli x5, x6, 31",     32'h01f3_5293, fila_i(SPEC_ALU_SRL));
        dirigido("srai x5, x6, 31",     32'h41f3_5293, fila_i(SPEC_ALU_SRA));
        dirigido("slli x5, x6, 0",      32'h0003_1293, fila_i(SPEC_ALU_SLL));
        dirigido("srai x5, x6, 0",      32'h4003_5293, fila_i(SPEC_ALU_SRA));
        dirigido("nop (addi x0, x0, 0)", 32'h0000_0013, fila_i(SPEC_ALU_ADD));

        dirigido("jalr x1, -4(x6)",     32'hffc3_00e7, FILA_JALR);
        dirigido("jal x1, -100",        32'hf9df_f0ef, FILA_JAL);
        dirigido("jal x0, -136",        32'hf79f_f06f, FILA_JAL);

        dirigido("sb x5, -1(x6)",       32'hfe53_0fa3, FILA_STORE);
        dirigido("sh x5, 2(x6)",        32'h0053_1123, FILA_STORE);
        dirigido("sw x5, -4(x6)",       32'hfe53_2e23, FILA_STORE);

        dirigido("beq x1, x2, -116",    32'hf820_86e3, FILA_BRANCH);
        dirigido("bne x1, x2, 8",       32'h0020_9463, FILA_BRANCH);

        dirigido("lui x5, 0xFFFFF",     32'hffff_f2b7, FILA_LUI);

        // 2. HALT: solo con valid = 1 (pipeline.md §4.4, decisión 001)
        dirigido("halt (ebreak)",       HALT,          FILA_HALT);
        for (i = 0; i < NB_INSTR; i = i + 1) begin
            word = HALT ^ (32'h1 << i);
            aplicar(1'b1, word);
            chk("HALT con un bit cambiado", modelo(1'b1, word));
            checks = checks + 1;
            if (tb_o_halt !== 1'b0) begin
                errors = errors + 1;
                $display("[%0t] ERROR HALT con el bit %0d cambiado activa halt | instr=0x%08h",
                         $time, i, word);
            end
        end

        // 3. No reconocidas: NOP (pipeline.md §4.4, decisión 024)
        no_reconocida("0x0000_0000",               32'h0000_0000);
        no_reconocida("0xFFFF_FFFF",               32'hffff_ffff);
        no_reconocida("ecall",                     32'h0000_0073);
        no_reconocida("SYSTEM con rd = x1",        32'h0010_00f3);
        no_reconocida("SYSTEM funct3 = 001 (csrrw)", 32'h3402_9073);
        no_reconocida("auipc x5, 1",               32'h0000_1297);
        no_reconocida("fence",                     32'h0ff0_000f);

        // 4. Barrido exhaustivo de opcode, funct3, instr[30] y valid
        for (op = 0; op < 128; op = op + 1)
            for (f3 = 0; f3 < 8; f3 = f3 + 1)
                for (b30 = 0; b30 < 2; b30 = b30 + 1)
                    for (v = 0; v < 2; v = v + 1) begin
                        word        = $random(seed);
                        word[6:0]   = op;
                        word[14:12] = f3;
                        word[30]    = b30;
                        aplicar(v, word);
                        chk("barrido", modelo(v, word));
                    end

        // 5. Aleatorio
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            word = $random(seed);
            aplicar($random(seed) & 1, word);
            chk("aleatorio", modelo(tb_valid, word));
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
