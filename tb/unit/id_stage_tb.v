`timescale 1ns / 1ps

//======================================================================
// id_stage_tb
//
// Testbench autoverificante de id_stage (docs/spec/verificacion.md §3.1):
// regfile + control_unit + imm_gen + id_ex_reg conectados como
// pipeline.md §4. Los módulos ya tienen su testbench; este prueba el
// cableado entre ellos, sobre todo lo que la traza de pipeline_tb no
// ejercita en M4 (WB y flush valen 0 en el core, y los saltos se cortan).
//
// Casos:
//   - Reset: ID/EX en burbuja (valid y control en 0) y banco en 0, visto
//     por el puerto de la Debug Unit
//   - Puerto de debug: lee cada registro sin bypass; x0 se lee 0 aunque
//     el arreglo tenga otra cosa
//   - Una palabra por fila de la tabla de verdad de §4.4 (R, I aritmética
//     con addi negativo, srai y sltiu, load, store, beq, bne, jal, jalr,
//     lui, HALT, no reconocida, burbuja): los 20 campos de ID/EX. Las
//     palabras son del ensamblador, con el inmediato escrito en la fuente
//     (mismo oráculo que imm_gen_tb); el control sale a mano de §4.4/§4.5
//   - o_id_is_halt solo con HALT y valid = 1
//   - Escritura de WB: bypass en rs1 y en rs2 en el mismo ciclo, el
//     puerto de debug lo ve desde el ciclo siguiente; con enable = 0 no
//     escribe; enable y en_id_ex son independientes; rd = 0 no escribe
//   - en_id_ex = 0 conserva los 161 bits, también con flush = 1
//   - flush con en_id_ex = 1 deja burbuja; reset con el core detenido
//   - o_id_ex_latch = los 20 campos en el orden de §8 (en cada chequeo)
//   - Aleatorio con semilla fija contra un modelo de §4.2 y §2
//
// Como en la traza del modelo (tools/isasim/isasim/latches.py), en una
// burbuja solo se comparan valid y el control; en las retenciones se
// compara todo, bit a bit.
//
// Los estímulos cambian en el flanco de bajada y se comprueban en el
// flanco de bajada siguiente, después de un flanco de subida.
//======================================================================

module id_stage_tb;

    localparam integer NB_PC       = 32;
    localparam integer NB_INSTR    = 32;
    localparam integer NB_DATA     = 32;
    localparam integer NB_ADDR     = 5;
    localparam integer NB_FUNCT3   = 3;
    localparam integer NB_ALU_CTRL = 4;
    localparam integer NB_CTRL     = NB_ALU_CTRL + 10;               // 14
    localparam integer NB_LATCH    = 1 + NB_PC + 3*NB_DATA + 3*NB_ADDR
                                     + NB_FUNCT3 + NB_CTRL;          // 161 (§8)
    localparam integer N_REGS      = 1 << NB_ADDR;
    localparam integer T_CLK       = 10;    // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM    = 3000;  // ciclos de estímulo aleatorio
    localparam integer MAX_CYCLES  = 8000;  // watchdog
    localparam integer SEED        = 39;    // semilla fija (issue #39)

    // Palabras de rvasm (tools/assembler), con la fuente al lado
    localparam [31:0] W_ADD   = 32'h007302b3;   // add   x5, x6, x7
    localparam [31:0] W_SUB   = 32'h40a48433;   // sub   x8, x9, x10
    localparam [31:0] W_SRA   = 32'h40d655b3;   // sra   x11, x12, x13
    localparam [31:0] W_ADDI  = 32'hffd78713;   // addi  x14, x15, -3
    localparam [31:0] W_SRAI  = 32'h4078d813;   // srai  x16, x17, 7
    localparam [31:0] W_SLTIU = 32'hfff9b913;   // sltiu x18, x19, -1
    localparam [31:0] W_LW    = 32'hff8aaa03;   // lw    x20, -8(x21)
    localparam [31:0] W_LBU   = 32'h005bcb03;   // lbu   x22, 5(x23)
    localparam [31:0] W_SW    = 32'hff8caa23;   // sw    x24, -12(x25)
    localparam [31:0] W_SB    = 32'h7fad8fa3;   // sb    x26, 2047(x27)
    localparam [31:0] W_BEQ   = 32'hffde08e3;   // beq   x28, x29, -16
    localparam [31:0] W_BNE   = 32'h41ff1063;   // bne   x30, x31, 1024
    localparam [31:0] W_JAL   = 32'h801ff0ef;   // jal   x1, -2048
    localparam [31:0] W_JALR  = 32'h00c18167;   // jalr  x2, 12(x3)
    localparam [31:0] W_LUI   = 32'habcde237;   // lui   x4, 0xABCDE
    localparam [31:0] W_HALT  = 32'h00100073;   // halt (ebreak)
    localparam [31:0] W_CERO  = 32'h00000000;   // no reconocida
    localparam [31:0] W_ECALL = 32'h00000073;   // ecall: SYSTEM distinto de HALT
    localparam [31:0] W_ADD0  = 32'h000002b3;   // add   x5, x0, x0

    // Control esperado, {alu_ctrl, alu_src_a, alu_src_b, branch, jal, jalr,
    // mem_read, mem_write, reg_write, mem_to_reg, halt}, de §4.4 y §4.5
    //                                 alu   a b br jal jalr mr mw rw m2r h
    localparam [13:0] C_NOP   = 14'b0000_0_0_0__0__0___0__0__0__0___0;
    localparam [13:0] C_ADD   = 14'b0000_0_0_0__0__0___0__0__1__0___0;
    localparam [13:0] C_SUB   = 14'b1000_0_0_0__0__0___0__0__1__0___0;
    localparam [13:0] C_SRA   = 14'b1101_0_0_0__0__0___0__0__1__0___0;
    localparam [13:0] C_ADDI  = 14'b0000_0_1_0__0__0___0__0__1__0___0;
    localparam [13:0] C_SRAI  = 14'b1101_0_1_0__0__0___0__0__1__0___0;
    localparam [13:0] C_SLTIU = 14'b0011_0_1_0__0__0___0__0__1__0___0;
    localparam [13:0] C_LOAD  = 14'b0000_0_1_0__0__0___1__0__1__1___0;
    localparam [13:0] C_STORE = 14'b0000_0_1_0__0__0___0__1__0__0___0;
    localparam [13:0] C_BR    = 14'b1000_0_0_1__0__0___0__0__0__0___0;
    localparam [13:0] C_JAL   = 14'b0000_0_0_0__1__0___0__0__1__0___0;
    localparam [13:0] C_JALR  = 14'b0000_0_1_0__0__1___0__0__1__0___0;
    localparam [13:0] C_LUI   = 14'b0000_1_1_0__0__0___0__0__1__0___0;
    localparam [13:0] C_HALT  = 14'b0000_0_0_0__0__0___0__0__0__0___1;

    reg                    tb_clk;
    reg                    tb_rst;
    reg                    tb_enable;
    reg                    tb_en_id_ex;
    reg                    tb_flush;
    reg                    tb_if_id_valid;
    reg  [NB_PC-1:0]       tb_if_id_pc;
    reg  [NB_INSTR-1:0]    tb_if_id_instr;
    reg                    tb_wb_reg_write;
    reg  [NB_ADDR-1:0]     tb_wb_rd;
    reg  [NB_DATA-1:0]     tb_wb_data;
    reg  [NB_ADDR-1:0]     tb_dbg_reg_addr;
    wire [NB_DATA-1:0]     tb_o_dbg_reg_data;
    wire                   tb_o_id_is_halt;
    wire                   tb_o_valid;
    wire [NB_PC-1:0]       tb_o_pc;
    wire [NB_DATA-1:0]     tb_o_rs1_data;
    wire [NB_DATA-1:0]     tb_o_rs2_data;
    wire [NB_DATA-1:0]     tb_o_imm;
    wire [NB_ADDR-1:0]     tb_o_rs1;
    wire [NB_ADDR-1:0]     tb_o_rs2;
    wire [NB_ADDR-1:0]     tb_o_rd;
    wire [NB_FUNCT3-1:0]   tb_o_funct3;
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
    wire [NB_LATCH-1:0]    tb_o_latch;

    // Los 20 campos de las salidas, en el orden de §8
    wire [NB_CTRL-1:0]  dut_ctrl  = {tb_o_alu_ctrl, tb_o_alu_src_a, tb_o_alu_src_b,
                                     tb_o_branch, tb_o_jal, tb_o_jalr, tb_o_mem_read,
                                     tb_o_mem_write, tb_o_reg_write, tb_o_mem_to_reg,
                                     tb_o_halt};
    wire [NB_LATCH-1:0] dut_campos = {tb_o_valid, tb_o_pc, tb_o_rs1_data, tb_o_rs2_data,
                                      tb_o_imm, tb_o_rs1, tb_o_rs2, tb_o_rd,
                                      tb_o_funct3, dut_ctrl};

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer k;

    // Modelo del banco y de ID/EX
    reg [NB_DATA-1:0]  mregs [0:N_REGS-1];
    reg                m_valid;
    reg [NB_PC-1:0]    m_pc;
    reg [NB_DATA-1:0]  m_rs1_data;
    reg [NB_DATA-1:0]  m_rs2_data;
    reg [NB_INSTR-1:0] m_instr;
    reg                m_hold;
    reg [NB_LATCH-1:0] foto;

    id_stage #(
        .NB_PC       (NB_PC),
        .NB_INSTR    (NB_INSTR),
        .NB_DATA     (NB_DATA),
        .NB_ADDR     (NB_ADDR),
        .NB_FUNCT3   (NB_FUNCT3),
        .NB_ALU_CTRL (NB_ALU_CTRL)
    ) u_dut (
        .i_clk              (tb_clk),
        .i_rst              (tb_rst),
        .i_enable           (tb_enable),
        .i_en_id_ex         (tb_en_id_ex),
        .i_flush            (tb_flush),
        .i_if_id_valid      (tb_if_id_valid),
        .i_if_id_pc         (tb_if_id_pc),
        .i_if_id_instr      (tb_if_id_instr),
        .i_wb_reg_write     (tb_wb_reg_write),
        .i_wb_rd            (tb_wb_rd),
        .i_wb_data          (tb_wb_data),
        .i_dbg_reg_addr     (tb_dbg_reg_addr),
        .o_dbg_reg_data     (tb_o_dbg_reg_data),
        .o_id_is_halt       (tb_o_id_is_halt),
        .o_id_ex_valid      (tb_o_valid),
        .o_id_ex_pc         (tb_o_pc),
        .o_id_ex_rs1_data   (tb_o_rs1_data),
        .o_id_ex_rs2_data   (tb_o_rs2_data),
        .o_id_ex_imm        (tb_o_imm),
        .o_id_ex_rs1        (tb_o_rs1),
        .o_id_ex_rs2        (tb_o_rs2),
        .o_id_ex_rd         (tb_o_rd),
        .o_id_ex_funct3     (tb_o_funct3),
        .o_id_ex_alu_ctrl   (tb_o_alu_ctrl),
        .o_id_ex_alu_src_a  (tb_o_alu_src_a),
        .o_id_ex_alu_src_b  (tb_o_alu_src_b),
        .o_id_ex_branch     (tb_o_branch),
        .o_id_ex_jal        (tb_o_jal),
        .o_id_ex_jalr       (tb_o_jalr),
        .o_id_ex_mem_read   (tb_o_mem_read),
        .o_id_ex_mem_write  (tb_o_mem_write),
        .o_id_ex_reg_write  (tb_o_reg_write),
        .o_id_ex_mem_to_reg (tb_o_mem_to_reg),
        .o_id_ex_halt       (tb_o_halt),
        .o_id_ex_latch      (tb_o_latch)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Chequeos con etiqueta
    //------------------------------------------------------------------
    task chk;
        input [8*40-1:0]    name;
        input [NB_DATA-1:0] obtenido;
        input [NB_DATA-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | dut=0x%0h esperado=0x%0h",
                         $time, name, obtenido, esperado);
            end
        end
    endtask

    task chk_latch;
        input [8*40-1:0]     name;
        input [NB_LATCH-1:0] obtenido;
        input [NB_LATCH-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | dut=0x%0h esperado=0x%0h",
                         $time, name, obtenido, esperado);
            end
        end
    endtask

    // Valor inicial de cada registro: distinto en todos y reconocible
    function [NB_DATA-1:0] valor_ini;
        input integer r;
        begin
            valor_ini = {8'hA5, 3'b000, r[4:0], 8'h5A, 3'b000, r[4:0]};
        end
    endfunction

    // Lectura de ID según §4.2: x0 vale 0 y el bypass gana sobre el arreglo
    function [NB_DATA-1:0] lectura;
        input [NB_ADDR-1:0] r;
        begin
            if (r == 0)
                lectura = {NB_DATA{1'b0}};
            else if (tb_wb_reg_write && tb_wb_rd == r)
                lectura = tb_wb_data;
            else
                lectura = mregs[r];
        end
    endfunction

    //------------------------------------------------------------------
    // Contenido de ID/EX contra lo esperado. En una burbuja solo valid y
    // control; imm solo si la instrucción tiene inmediato (latches.py)
    //------------------------------------------------------------------
    task chk_id_ex;
        input [8*24-1:0]    etiqueta;
        input               valid;
        input [NB_PC-1:0]   pc;
        input [NB_INSTR-1:0] instr;
        input [NB_DATA-1:0] rs1_data;
        input [NB_DATA-1:0] rs2_data;
        input               imm_def;
        input [NB_DATA-1:0] imm;
        input [NB_CTRL-1:0] ctrl;
        reg   [8*40-1:0]    n;
        begin
            $sformat(n, "%0s valid", etiqueta);   chk(n, tb_o_valid, valid);
            $sformat(n, "%0s control", etiqueta); chk(n, dut_ctrl, ctrl);
            if (valid) begin
                $sformat(n, "%0s pc", etiqueta);       chk(n, tb_o_pc, pc);
                $sformat(n, "%0s rs1_data", etiqueta); chk(n, tb_o_rs1_data, rs1_data);
                $sformat(n, "%0s rs2_data", etiqueta); chk(n, tb_o_rs2_data, rs2_data);
                $sformat(n, "%0s rs1", etiqueta);      chk(n, tb_o_rs1, instr[19:15]);
                $sformat(n, "%0s rs2", etiqueta);      chk(n, tb_o_rs2, instr[24:20]);
                $sformat(n, "%0s rd", etiqueta);       chk(n, tb_o_rd, instr[11:7]);
                $sformat(n, "%0s funct3", etiqueta);   chk(n, tb_o_funct3, instr[14:12]);
                if (imm_def) begin
                    $sformat(n, "%0s imm", etiqueta);  chk(n, tb_o_imm, imm);
                end
            end
            $sformat(n, "%0s o_id_ex_latch", etiqueta);
            chk_latch(n, tb_o_latch, dut_campos);
        end
    endtask

    // Una instrucción de la tabla de §4.4: entra a ID en un flanco de bajada
    // y se compara en ID/EX en el siguiente. Las lecturas del banco se
    // calculan antes del flanco (sin escritura de WB en este caso)
    task caso;
        input [8*24-1:0]     nombre;
        input                valid;
        input [NB_INSTR-1:0] instr;
        input                imm_def;
        input [NB_DATA-1:0]  imm;
        input [NB_CTRL-1:0]  ctrl;
        reg   [NB_DATA-1:0]  d1;
        reg   [NB_DATA-1:0]  d2;
        reg   [8*40-1:0]     n;
        begin
            tb_if_id_valid = valid;
            tb_if_id_pc    = tb_if_id_pc + 4;
            tb_if_id_instr = instr;
            d1 = lectura(instr[19:15]);
            d2 = lectura(instr[24:20]);
            #1;
            $sformat(n, "%0s o_id_is_halt", nombre);
            chk(n, tb_o_id_is_halt, valid && instr == W_HALT);
            @(negedge tb_clk);
            // con flush entra una burbuja (§2); ctrl ya viene en 0
            chk_id_ex(nombre, valid & ~tb_flush, tb_if_id_pc, instr, d1, d2, imm_def,
                      imm, ctrl);
        end
    endtask

    // Recorre el puerto de debug con el core detenido (nada cambia aunque
    // pasen flancos); vuelve en un flanco de bajada con todo como estaba
    task chk_banco;
        input [8*24-1:0] cuando;
        reg              en_ant;
        reg              en_id_ex_ant;
        reg   [8*40-1:0] n;
        begin
            en_ant       = tb_enable;
            en_id_ex_ant = tb_en_id_ex;
            tb_enable    = 1'b0;
            tb_en_id_ex  = 1'b0;
            for (k = 0; k < N_REGS; k = k + 1) begin
                tb_dbg_reg_addr = k[NB_ADDR-1:0];
                #1;
                $sformat(n, "%0s debug x%0d", cuando, k);
                chk(n, tb_o_dbg_reg_data, (k == 0) ? {NB_DATA{1'b0}} : mregs[k]);
            end
            @(negedge tb_clk);
            tb_enable   = en_ant;
            tb_en_id_ex = en_id_ex_ant;
        end
    endtask

    // Carga del banco por jerarquía, como pipeline_tb (decisión 021). En x0
    // queda basura a propósito: ningún puerto tiene que verla
    task cargar_banco;
        begin
            u_dut.u_regfile.regs[0] = 32'hDEAD_BEEF;
            mregs[0] = {NB_DATA{1'b0}};
            for (k = 1; k < N_REGS; k = k + 1) begin
                u_dut.u_regfile.regs[k] = valor_ini(k);
                mregs[k] = valor_ini(k);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Paso del modelo en un flanco de subida (pipeline.md §2 y §4.2)
    //------------------------------------------------------------------
    task modelo;
        reg [NB_DATA-1:0] d1;
        reg [NB_DATA-1:0] d2;
        begin
            d1 = lectura(tb_if_id_instr[19:15]);
            d2 = lectura(tb_if_id_instr[24:20]);
            m_hold = 1'b0;
            if (tb_rst) begin
                m_valid = 1'b0;
                for (k = 0; k < N_REGS; k = k + 1)
                    mregs[k] = {NB_DATA{1'b0}};
            end
            else begin
                if (tb_en_id_ex) begin
                    m_valid    = tb_if_id_valid & ~tb_flush;
                    m_pc       = tb_if_id_pc;
                    m_instr    = tb_if_id_instr;
                    m_rs1_data = d1;
                    m_rs2_data = d2;
                end
                else
                    m_hold = 1'b1;
                if (tb_enable && tb_wb_reg_write && tb_wb_rd != 0)
                    mregs[tb_wb_rd] = tb_wb_data;
            end
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors          = 0;
        checks          = 0;
        seed            = SEED;
        tb_rst          = 1'b1;
        tb_enable       = 1'b0;
        tb_en_id_ex     = 1'b0;
        tb_flush        = 1'b0;
        tb_if_id_valid  = 1'b0;
        tb_if_id_pc     = 32'h0000_0100;
        tb_if_id_instr  = W_CERO;
        tb_wb_reg_write = 1'b0;
        tb_wb_rd        = {NB_ADDR{1'b0}};
        tb_wb_data      = {NB_DATA{1'b0}};
        tb_dbg_reg_addr = {NB_ADDR{1'b0}};

        //--------------------------------------------------------------
        // Reset: el banco en 0 aunque tuviera algo, ID/EX en burbuja
        //--------------------------------------------------------------
        @(negedge tb_clk);
        for (k = 0; k < N_REGS; k = k + 1) begin
            u_dut.u_regfile.regs[k] = valor_ini(k);
            mregs[k] = {NB_DATA{1'b0}};
        end
        tb_if_id_valid = 1'b1;
        tb_if_id_instr = W_HALT;          // basura válida a la entrada
        tb_en_id_ex    = 1'b1;
        tb_enable      = 1'b1;
        repeat (2) @(negedge tb_clk);
        chk_id_ex("reset", 1'b0, 0, 0, 0, 0, 1'b0, 0, C_NOP);
        tb_rst = 1'b0;
        chk_banco("reset");

        //--------------------------------------------------------------
        // Puerto de debug y x0
        //--------------------------------------------------------------
        cargar_banco;
        chk_banco("carga");

        //--------------------------------------------------------------
        // Tabla de verdad de §4.4, una palabra por fila
        //--------------------------------------------------------------
        caso("add",       1'b1, W_ADD,   1'b0, 32'h0,        C_ADD);
        caso("sub",       1'b1, W_SUB,   1'b0, 32'h0,        C_SUB);
        caso("sra",       1'b1, W_SRA,   1'b0, 32'h0,        C_SRA);
        caso("addi -3",   1'b1, W_ADDI,  1'b1, 32'hFFFF_FFFD, C_ADDI);
        caso("srai 7",    1'b1, W_SRAI,  1'b1, 32'h0000_0407, C_SRAI);
        caso("sltiu -1",  1'b1, W_SLTIU, 1'b1, 32'hFFFF_FFFF, C_SLTIU);
        caso("lw -8",     1'b1, W_LW,    1'b1, 32'hFFFF_FFF8, C_LOAD);
        caso("lbu 5",     1'b1, W_LBU,   1'b1, 32'h0000_0005, C_LOAD);
        caso("sw -12",    1'b1, W_SW,    1'b1, 32'hFFFF_FFF4, C_STORE);
        caso("sb 2047",   1'b1, W_SB,    1'b1, 32'h0000_07FF, C_STORE);
        caso("beq -16",   1'b1, W_BEQ,   1'b1, 32'hFFFF_FFF0, C_BR);
        caso("bne 1024",  1'b1, W_BNE,   1'b1, 32'h0000_0400, C_BR);
        caso("jal -2048", 1'b1, W_JAL,   1'b1, 32'hFFFF_F800, C_JAL);
        caso("jalr 12",   1'b1, W_JALR,  1'b1, 32'h0000_000C, C_JALR);
        caso("lui",       1'b1, W_LUI,   1'b1, 32'hABCD_E000, C_LUI);
        caso("halt",      1'b1, W_HALT,  1'b0, 32'h0,        C_HALT);
        caso("0x0",       1'b1, W_CERO,  1'b0, 32'h0,        C_NOP);
        caso("ecall",     1'b1, W_ECALL, 1'b0, 32'h0,        C_NOP);
        caso("burbuja",   1'b0, W_HALT,  1'b0, 32'h0,        C_NOP);
        caso("burbuja jal", 1'b0, W_JAL, 1'b0, 32'h0,        C_NOP);

        //--------------------------------------------------------------
        // Escritura de WB y bypass (decisión 007)
        //--------------------------------------------------------------
        // Bypass en rs1: add x5, x6, x7 mientras WB escribe x6
        tb_wb_reg_write = 1'b1;
        tb_wb_rd        = 5'd6;
        tb_wb_data      = 32'h1111_0006;
        tb_dbg_reg_addr = 5'd6;
        #1;
        chk("debug x6 sin bypass antes del flanco", tb_o_dbg_reg_data, mregs[6]);
        caso("bypass rs1", 1'b1, W_ADD, 1'b0, 32'h0, C_ADD);
        mregs[6] = 32'h1111_0006;
        tb_wb_reg_write = 1'b0;
        #1;
        chk("debug x6 escrito", tb_o_dbg_reg_data, 32'h1111_0006);
        @(negedge tb_clk);

        // Bypass en rs2
        tb_wb_reg_write = 1'b1;
        tb_wb_rd        = 5'd7;
        tb_wb_data      = 32'h2222_0007;
        caso("bypass rs2", 1'b1, W_ADD, 1'b0, 32'h0, C_ADD);
        mregs[7] = 32'h2222_0007;
        tb_wb_reg_write = 1'b0;

        // rd = 0: ni bypass ni escritura
        tb_wb_reg_write = 1'b1;
        tb_wb_rd        = 5'd0;
        tb_wb_data      = 32'h3333_0000;
        caso("x0 sin bypass", 1'b1, W_ADD0, 1'b0, 32'h0, C_ADD);
        tb_wb_reg_write = 1'b0;

        // enable = 0: no escribe, y ID/EX (en_id_ex = 0) no cambia
        foto            = tb_o_latch;
        tb_enable       = 1'b0;
        tb_en_id_ex     = 1'b0;
        tb_wb_reg_write = 1'b1;
        tb_wb_rd        = 5'd8;
        tb_wb_data      = 32'h4444_0008;
        tb_if_id_instr  = W_JAL;
        tb_if_id_valid  = 1'b1;
        @(negedge tb_clk);
        tb_wb_reg_write = 1'b0;
        chk_latch("enable = 0: ID/EX retenido", tb_o_latch, foto);

        // enable = 1 con en_id_ex = 0: el banco escribe y el latch no cambia
        tb_enable       = 1'b1;
        tb_wb_reg_write = 1'b1;
        @(negedge tb_clk);
        mregs[8] = 32'h4444_0008;
        tb_wb_reg_write = 1'b0;
        chk_latch("en_id_ex = 0, enable = 1: ID/EX retenido", tb_o_latch, foto);
        chk_banco("escrituras de WB");

        //--------------------------------------------------------------
        // en > flush, flush, reset con el core detenido
        //--------------------------------------------------------------
        tb_en_id_ex = 1'b1;
        caso("antes de retener", 1'b1, W_LW, 1'b1, 32'hFFFF_FFF8, C_LOAD);
        foto           = tb_o_latch;
        tb_en_id_ex    = 1'b0;
        tb_flush       = 1'b1;
        tb_if_id_instr = W_SW;
        tb_if_id_pc    = tb_if_id_pc + 4;
        repeat (3) @(negedge tb_clk);
        chk_latch("en = 0 con flush = 1: retenido", tb_o_latch, foto);

        tb_en_id_ex = 1'b1;
        caso("flush", 1'b1, W_JAL, 1'b0, 32'h0, C_NOP);
        caso("flush halt", 1'b1, W_HALT, 1'b0, 32'h0, C_NOP);
        tb_flush = 1'b0;
        caso("despues del flush", 1'b1, W_JALR, 1'b1, 32'h0000_000C, C_JALR);

        tb_enable   = 1'b0;
        tb_en_id_ex = 1'b0;
        tb_rst      = 1'b1;
        for (k = 0; k < N_REGS; k = k + 1)
            mregs[k] = {NB_DATA{1'b0}};
        @(negedge tb_clk);
        tb_rst = 1'b0;
        chk_id_ex("reset con el core detenido", 1'b0, 0, 0, 0, 0, 1'b0, 0, C_NOP);
        chk_banco("reset con el core detenido");

        //--------------------------------------------------------------
        // Aleatorio contra el modelo
        //--------------------------------------------------------------
        cargar_banco;
        m_valid = 1'b0;
        m_hold  = 1'b0;
        foto    = tb_o_latch;
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            tb_rst          = (($random(seed) & 63) == 0);
            tb_enable       = (($random(seed) & 7) != 0);
            tb_en_id_ex     = (($random(seed) & 7) != 0);
            tb_flush        = (($random(seed) & 3) == 0);
            tb_if_id_valid  = $random(seed);
            tb_if_id_pc     = $random(seed);
            tb_if_id_instr  = $random(seed);
            tb_wb_reg_write = $random(seed);
            tb_wb_rd        = $random(seed);
            tb_wb_data      = $random(seed);
            tb_dbg_reg_addr = $random(seed);
            #1;
            chk("aleatorio debug", tb_o_dbg_reg_data,
                (tb_dbg_reg_addr == 0) ? {NB_DATA{1'b0}} : mregs[tb_dbg_reg_addr]);
            foto = tb_o_latch;
            @(posedge tb_clk);
            modelo;
            @(negedge tb_clk);
            if (m_hold)
                chk_latch("aleatorio retenido", tb_o_latch, foto);
            else
                chk_id_ex("aleatorio", m_valid, m_pc, m_instr, m_rs1_data, m_rs2_data,
                          1'b0, 0, m_valid ? dut_ctrl : {NB_CTRL{1'b0}});
        end
        tb_rst          = 1'b0;
        tb_wb_reg_write = 1'b0;
        chk_banco("despues del aleatorio");

        if (errors == 0)
            $display("TEST PASSED: %0d chequeos, 0 errores", checks);
        else
            $display("TEST FAILED: %0d errores sobre %0d chequeos", errors, checks);
        $finish;
    end

    // Watchdog: si la secuencia no termina, falla en vez de colgarse
    initial begin
        repeat (MAX_CYCLES) @(posedge tb_clk);
        $display("TEST FAILED: timeout de %0d ciclos", MAX_CYCLES);
        $finish;
    end

endmodule
