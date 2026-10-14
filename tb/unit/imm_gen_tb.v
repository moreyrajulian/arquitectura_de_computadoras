`timescale 1ns / 1ps

//======================================================================
// imm_gen_tb
//
// Testbench autoverificante de imm_gen (docs/spec/verificacion.md §3.1).
//
// Oráculos, los dos escritos aparte del RTL:
//   - Vectores del ensamblador: cada palabra la generó rvasm a partir de
//     la línea que figura como nombre del caso, y el esperado es el
//     inmediato escrito en esa línea, no una fórmula. rvasm está validado
//     contra LLVM y GNU as (tools/assembler/validate_reference.py).
//   - Codificador propio: arma la instrucción en el sentido inverso al
//     del DUT (reparte los bits del inmediato en los campos) y rellena el
//     resto al azar. Cubre lo que rvasm no puede generar: los saltos de
//     rvasm son múltiplos de 4, así que nunca ponen en 1 el bit 1 del
//     inmediato de B y J (instr[8] e instr[21]), ni dan sus máximos 4094
//     y 1048574.
//
// Casos:
//   - Por formato: positivo, negativo, máximo y mínimo (rvasm)
//   - imm[11] de B (instr[7]) y de J (instr[20]); srai con funct7 en el
//     inmediato (0x400 | shamt); sltiu se extiende con signo (§4.3)
//   - El signo sale siempre de instr[31]: palabras 0x8000_0000,
//     0x7FFF_FFFF y 0xFFFF_FFFF en los cinco formatos
//   - Códigos de imm_sel sin formato -> 0
//   - Aleatorio con semilla fija: inmediato y relleno, los cinco formatos
//
// No depende de los valores de IMM_*: usa los nombres de riscv_defs.vh,
// así que pasa con cualquier codificación de valores distintos.
//======================================================================

module imm_gen_tb;

    localparam integer NB_INSTR   = 32;
    localparam integer NB_IMM     = 32;
    localparam integer NB_IMM_SEL = 3;
    localparam integer T_STEP     = 10;      // ns entre vectores
    localparam integer N_RANDOM   = 1000;    // vectores aleatorios por formato
    localparam integer MAX_TIME   = 200000;  // ns, watchdog
    localparam integer SEED       = 37;      // semilla fija (issue #37)

    `include "riscv_defs.vh"

    reg  [NB_INSTR-1:0]   tb_instr;
    reg  [NB_IMM_SEL-1:0] tb_imm_sel;
    wire [NB_IMM-1:0]     tb_imm;

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer f;
    integer code;

    reg [NB_IMM-1:0]     r;
    reg [NB_IMM-1:0]     imm;
    reg [NB_INSTR-1:0]   relleno;
    reg [NB_IMM_SEL-1:0] sel;

    imm_gen #(
        .NB_INSTR   (NB_INSTR),
        .NB_IMM     (NB_IMM),
        .NB_IMM_SEL (NB_IMM_SEL)
    ) u_dut (
        .i_instr   (tb_instr),
        .i_imm_sel (tb_imm_sel),
        .o_imm     (tb_imm)
    );

    //------------------------------------------------------------------
    // Codificador de referencia: ubica cada bit del inmediato en su campo
    // de la instrucción (isa.md, figura de formatos) y deja los demás
    // bits como vienen en resto. valor ya tiene la forma del formato
    // (B y J con bit 0 en 0, U con [11:0] en 0).
    //------------------------------------------------------------------
    function [NB_INSTR-1:0] codificar;
        input [NB_IMM_SEL-1:0] formato;
        input [NB_IMM-1:0]     valor;
        input [NB_INSTR-1:0]   resto;
        reg   [NB_INSTR-1:0]   w;
        begin
            w = resto;
            if (formato == IMM_I) begin
                w[31:20] = valor[11:0];
            end
            else if (formato == IMM_S) begin
                w[31:25] = valor[11:5];
                w[11:7]  = valor[4:0];
            end
            else if (formato == IMM_B) begin
                w[31]    = valor[12];
                w[7]     = valor[11];
                w[30:25] = valor[10:5];
                w[11:8]  = valor[4:1];
            end
            else if (formato == IMM_U) begin
                w[31:12] = valor[31:12];
            end
            else if (formato == IMM_J) begin
                w[31]    = valor[20];
                w[19:12] = valor[19:12];
                w[20]    = valor[11];
                w[30:21] = valor[10:1];
            end
            codificar = w;
        end
    endfunction

    // Lleva un valor aleatorio a la forma del inmediato de cada formato:
    // los bits que el formato no codifica salen de la extensión de signo
    function [NB_IMM-1:0] forma;
        input [NB_IMM_SEL-1:0] formato;
        input [NB_IMM-1:0]     v;
        begin
            if (formato == IMM_I || formato == IMM_S)
                forma = {{20{v[11]}}, v[11:0]};
            else if (formato == IMM_B)
                forma = {{19{v[12]}}, v[12:1], 1'b0};
            else if (formato == IMM_U)
                forma = {v[31:12], 12'b0};
            else
                forma = {{11{v[20]}}, v[20:1], 1'b0};
        end
    endfunction

    function [NB_IMM_SEL-1:0] formato_n;
        input integer n;
        begin
            case (n)
                0:       formato_n = IMM_I;
                1:       formato_n = IMM_S;
                2:       formato_n = IMM_B;
                3:       formato_n = IMM_U;
                default: formato_n = IMM_J;
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // Aplica un vector y compara, con etiqueta para el log
    //------------------------------------------------------------------
    task vec;
        input [8*40-1:0]       name;
        input [NB_INSTR-1:0]   instr;
        input [NB_IMM_SEL-1:0] imm_sel;
        input [NB_IMM-1:0]     esperado;
        begin
            tb_instr   = instr;
            tb_imm_sel = imm_sel;
            #(T_STEP);
            checks = checks + 1;
            if (tb_imm !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | instr=0x%08h imm_sel=%0d dut=0x%08h esperado=0x%08h",
                         $time, name, instr, imm_sel, tb_imm, esperado);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors     = 0;
        checks     = 0;
        seed       = SEED;
        tb_instr   = {NB_INSTR{1'b0}};
        tb_imm_sel = {NB_IMM_SEL{1'b0}};

        // Los cinco códigos tienen que ser distintos, si no el resto no prueba nada
        if (IMM_I == IMM_S || IMM_I == IMM_B || IMM_I == IMM_U || IMM_I == IMM_J ||
            IMM_S == IMM_B || IMM_S == IMM_U || IMM_S == IMM_J ||
            IMM_B == IMM_U || IMM_B == IMM_J || IMM_U == IMM_J) begin
            errors = errors + 1;
            $display("ERROR codificación IMM_* con valores repetidos en riscv_defs.vh");
        end

        // Vectores de rvasm (cada instrucción ensamblada sola, en PC = 0)
        vec("addi x5, x6, 1",      32'h0013_0293, IMM_I, 32'h0000_0001);
        vec("addi x7, x8, -1",     32'hFFF4_0393, IMM_I, 32'hFFFF_FFFF);
        vec("addi x31, x31, 2047", 32'h7FFF_8F93, IMM_I, 32'h0000_07FF);
        vec("addi x1, x2, -2048",  32'h8001_0093, IMM_I, 32'hFFFF_F800);
        vec("lw x10, 1000(x11)",   32'h3E85_A503, IMM_I, 32'h0000_03E8);
        vec("lb x12, -100(x13)",   32'hF9C6_8603, IMM_I, 32'hFFFF_FF9C);
        vec("jalr x1, -4(x5)",     32'hFFC2_80E7, IMM_I, 32'hFFFF_FFFC);
        vec("sltiu x14, x15, -1",  32'hFFF7_B713, IMM_I, 32'hFFFF_FFFF);
        vec("slli x20, x21, 31",   32'h01FA_9A13, IMM_I, 32'h0000_001F);
        vec("srai x16, x17, 3",    32'h4038_D813, IMM_I, 32'h0000_0403);
        vec("srai x18, x19, 31",   32'h41F9_D913, IMM_I, 32'h0000_041F);
        vec("sw x5, 1(x6)",        32'h0053_20A3, IMM_S, 32'h0000_0001);
        vec("sw x7, -1(x8)",       32'hFE74_2FA3, IMM_S, 32'hFFFF_FFFF);
        vec("sb x31, 2047(x30)",   32'h7FFF_0FA3, IMM_S, 32'h0000_07FF);
        vec("sh x1, -2048(x2)",    32'h8011_1023, IMM_S, 32'hFFFF_F800);
        vec("sw x9, 1365(x10)",    32'h5495_2AA3, IMM_S, 32'h0000_0555);
        vec("sw x11, -1366(x12)",  32'hAAB6_2523, IMM_S, 32'hFFFF_FAAA);
        vec("beq x1, x2, 4",       32'h0020_8263, IMM_B, 32'h0000_0004);
        vec("bne x3, x4, -4",      32'hFE41_9EE3, IMM_B, 32'hFFFF_FFFC);
        vec("beq x5, x6, 4092",    32'h7E62_8EE3, IMM_B, 32'h0000_0FFC);
        vec("bne x7, x8, -4096",   32'h8083_9063, IMM_B, 32'hFFFF_F000);
        vec("beq x9, x10, 2048",   32'h00A4_80E3, IMM_B, 32'h0000_0800);
        vec("bne x11, x12, -2048", 32'h80C5_90E3, IMM_B, 32'hFFFF_F800);
        vec("beq x13, x14, 1364",  32'h54E6_8A63, IMM_B, 32'h0000_0554);
        vec("jal x1, 4",           32'h0040_00EF, IMM_J, 32'h0000_0004);
        vec("jal x0, -4",          32'hFFDF_F06F, IMM_J, 32'hFFFF_FFFC);
        vec("jal x5, 1048572",     32'h7FDF_F2EF, IMM_J, 32'h000F_FFFC);
        vec("jal x31, -1048576",   32'h8000_0FEF, IMM_J, 32'hFFF0_0000);
        vec("jal x2, 2048",        32'h0010_016F, IMM_J, 32'h0000_0800);
        vec("jal x3, 4096",        32'h0000_11EF, IMM_J, 32'h0000_1000);
        vec("jal x4, 349524",      32'h5545_526F, IMM_J, 32'h0005_5554);
        vec("lui x1, 0",           32'h0000_00B7, IMM_U, 32'h0000_0000);
        vec("lui x2, 0x7FFFF",     32'h7FFF_F137, IMM_U, 32'h7FFF_F000);
        vec("lui x3, 0x80000",     32'h8000_01B7, IMM_U, 32'h8000_0000);
        vec("lui x4, 0xFFFFF",     32'hFFFF_F237, IMM_U, 32'hFFFF_F000);
        vec("lui x5, 0x12345",     32'h1234_52B7, IMM_U, 32'h1234_5000);

        // Máximos de B y J, fuera del alcance de rvasm (bit 1 en 1)
        vec("B maximo 4094",       codificar(IMM_B, 32'h0000_0FFE, 32'h0000_0063), IMM_B, 32'h0000_0FFE);
        vec("J maximo 1048574",    codificar(IMM_J, 32'h000F_FFFE, 32'h0000_006F), IMM_J, 32'h000F_FFFE);
        vec("B bit 1 (instr[8])",  32'h0000_0100, IMM_B, 32'h0000_0002);
        vec("J bit 1 (instr[21])", 32'h0020_0000, IMM_J, 32'h0000_0002);

        // El signo sale de instr[31] y nada más
        vec("I solo instr[31]",    32'h8000_0000, IMM_I, 32'hFFFF_F800);
        vec("S solo instr[31]",    32'h8000_0000, IMM_S, 32'hFFFF_F800);
        vec("B solo instr[31]",    32'h8000_0000, IMM_B, 32'hFFFF_F000);
        vec("U solo instr[31]",    32'h8000_0000, IMM_U, 32'h8000_0000);
        vec("J solo instr[31]",    32'h8000_0000, IMM_J, 32'hFFF0_0000);
        vec("I todo menos [31]",   32'h7FFF_FFFF, IMM_I, 32'h0000_07FF);
        vec("S todo menos [31]",   32'h7FFF_FFFF, IMM_S, 32'h0000_07FF);
        vec("B todo menos [31]",   32'h7FFF_FFFF, IMM_B, 32'h0000_0FFE);
        vec("U todo menos [31]",   32'h7FFF_FFFF, IMM_U, 32'h7FFF_F000);
        vec("J todo menos [31]",   32'h7FFF_FFFF, IMM_J, 32'h000F_FFFE);
        vec("I todo en 1",         32'hFFFF_FFFF, IMM_I, 32'hFFFF_FFFF);
        vec("S todo en 1",         32'hFFFF_FFFF, IMM_S, 32'hFFFF_FFFF);
        vec("B todo en 1",         32'hFFFF_FFFF, IMM_B, 32'hFFFF_FFFE);
        vec("U todo en 1",         32'hFFFF_FFFF, IMM_U, 32'hFFFF_F000);
        vec("J todo en 1",         32'hFFFF_FFFF, IMM_J, 32'hFFFF_FFFE);

        // Códigos sin formato: inmediato en 0 (pipeline.md §4.3)
        for (code = 0; code < (1 << NB_IMM_SEL); code = code + 1) begin
            sel = code;
            if (sel != IMM_I && sel != IMM_S && sel != IMM_B &&
                sel != IMM_U && sel != IMM_J) begin
                vec("codigo sin formato, todo en 1", 32'hFFFF_FFFF, sel, 32'h0000_0000);
                vec("codigo sin formato, rvasm",     32'h7FDF_F2EF, sel, 32'h0000_0000);
            end
        end

        // Aleatorio: inmediato y relleno al azar, contra el codificador
        for (f = 0; f < 5; f = f + 1) begin
            for (i = 0; i < N_RANDOM; i = i + 1) begin
                r       = $random(seed);
                relleno = $random(seed);
                imm     = forma(formato_n(f), r);
                vec("aleatorio", codificar(formato_n(f), imm, relleno), formato_n(f), imm);
            end
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
