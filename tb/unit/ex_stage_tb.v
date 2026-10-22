`timescale 1ns / 1ps

//======================================================================
// ex_stage_tb
//
// Testbench autoverificante de ex_stage (docs/spec/verificacion.md §3.1):
// muxes de forwarding y de operandos + alu + branch_unit + mux de
// resultado + ex_mem_reg conectados como pipeline.md §5. Los módulos ya
// tienen su testbench; este prueba el cableado entre ellos, sobre todo lo
// que la traza de pipeline_tb no ve en M5: el forwarding (fwd_a = fwd_b =
// 00 en el core hasta I-39), redirect y redirect_pc (no son campos de
// EX/MEM y no vuelven a IF hasta I-36) y el flush (0 en el core).
//
// Casos:
//   - Reset: EX/MEM en burbuja (valid y control en 0)
//   - Las 10 operaciones de la ALU con operandos de registro; addi con
//     inmediato negativo; lui (alu_a = 0); dirección de lw y sw con
//     store_data = rs2_val; HALT; burbuja
//   - beq y bne tomados y no tomados; jal y jalr con result = pc + 4 y
//     su destino (jalr con el bit 0 en 1 antes de limpiarlo). redirect_pc
//     se compara en todos los casos (§5.3 lo define siempre)
//   - Forwarding: 10 (ex_mem_result, la salida del propio EX/MEM) y 01
//     (wb_data) en A y en B, los dos a la vez, en store_data, en el
//     operando que el control descarta (lui, addi), en beq/bne y en jalr;
//     el código 11 toma lo leído en ID (§5.6)
//   - en_ex_mem = 0 conserva los 109 bits, también con flush = 1
//   - flush con en_ex_mem = 1 deja burbuja; reset con el core detenido
//   - o_ex_mem_latch = los 10 campos en el orden de §8 (en cada chequeo)
//   - Aleatorio con semilla fija contra un modelo de §5 y §2, con el
//     control de una fila de la tabla de §4.4 por ciclo
//
// Los esperados de los casos dirigidos están calculados a mano. Los
// códigos de alu_ctrl, el control de cada instrucción y los de fwd_a /
// fwd_b son literales copiados de pipeline.md §4.4, §4.5 y §5.1, no las
// constantes de riscv_defs.vh. Solo se usan filas que genera
// control_unit: con branch = 1, funct3 = 000 o 001; con jalr = 1,
// funct3 = 000 (decisiones 024 y 025).
//
// Como en la traza del modelo (tools/isasim/isasim/latches.py), en una
// burbuja solo se comparan valid y el control; en las retenciones se
// compara todo, bit a bit. En el aleatorio, fwd = 10 solo se elige si
// EX/MEM tiene una instrucción: una burbuja tiene reg_write = 0 y la
// unidad de forwarding nunca la elige (§10.2), y sus datos no importan.
//
// Los estímulos cambian en el flanco de bajada y se comprueban en el
// flanco de bajada siguiente, después de un flanco de subida.
//======================================================================

module ex_stage_tb;

    localparam integer NB_PC       = 32;
    localparam integer NB_DATA     = 32;
    localparam integer NB_ADDR     = 5;
    localparam integer NB_FUNCT3   = 3;
    localparam integer NB_ALU_CTRL = 4;
    localparam integer NB_FWD      = 2;
    localparam integer NB_CTRL_IN  = NB_ALU_CTRL + 9;                 // 13
    localparam integer NB_CTRL     = 4;                               // de EX/MEM
    localparam integer NB_LATCH    = 1 + NB_PC + 2*NB_DATA + NB_ADDR
                                     + NB_FUNCT3 + NB_CTRL;           // 109 (§8)
    localparam integer T_CLK       = 10;    // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM    = 4000;  // ciclos de estímulo aleatorio
    localparam integer MAX_CYCLES  = 8000;  // watchdog
    localparam integer SEED        = 43;    // semilla fija (issue #43)

    // fwd_a / fwd_b (§5.1)
    localparam [1:0] F_ID = 2'b00;          // id_ex_rs*_data
    localparam [1:0] F_EM = 2'b10;          // ex_mem_result
    localparam [1:0] F_WB = 2'b01;          // wb_data

    // alu_ctrl (§4.5)
    localparam [3:0] A_ADD  = 4'b0000;
    localparam [3:0] A_SUB  = 4'b1000;
    localparam [3:0] A_SLL  = 4'b0001;
    localparam [3:0] A_SLT  = 4'b0010;
    localparam [3:0] A_SLTU = 4'b0011;
    localparam [3:0] A_XOR  = 4'b0100;
    localparam [3:0] A_SRL  = 4'b0101;
    localparam [3:0] A_SRA  = 4'b1101;
    localparam [3:0] A_OR   = 4'b0110;
    localparam [3:0] A_AND  = 4'b0111;

    // Control que llega de ID/EX, {alu_ctrl, alu_src_a, alu_src_b, branch,
    // jal, jalr, mem_write, reg_write, mem_to_reg, halt}, de §4.4 (sin
    // mem_read, que EX no usa). Las filas R e I aritmética llevan el
    // alu_ctrl aparte (c_r, c_i)
    //                                 alu   a b br jal jalr mw rw m2r h
    localparam [12:0] C_NOP   = 13'b0000_0_0_0__0___0__0__0___0__0;
    localparam [12:0] C_LOAD  = 13'b0000_0_1_0__0___0__0__1___1__0;
    localparam [12:0] C_STORE = 13'b0000_0_1_0__0___0__1__0___0__0;
    localparam [12:0] C_BR    = 13'b1000_0_0_1__0___0__0__0___0__0;
    localparam [12:0] C_JAL   = 13'b0000_0_0_0__1___0__0__1___0__0;
    localparam [12:0] C_JALR  = 13'b0000_0_1_0__0___1__0__1___0__0;
    localparam [12:0] C_LUI   = 13'b0000_1_1_0__0___0__0__1___0__0;
    localparam [12:0] C_HALT  = 13'b0000_0_0_0__0___0__0__0___0__1;

    reg                    tb_clk;
    reg                    tb_rst;
    reg                    tb_en_ex_mem;
    reg                    tb_flush;
    reg  [NB_FWD-1:0]      tb_fwd_a;
    reg  [NB_FWD-1:0]      tb_fwd_b;
    reg  [NB_DATA-1:0]     tb_wb_data;
    reg                    tb_valid;
    reg  [NB_PC-1:0]       tb_pc;
    reg  [NB_DATA-1:0]     tb_rs1_data;
    reg  [NB_DATA-1:0]     tb_rs2_data;
    reg  [NB_DATA-1:0]     tb_imm;
    reg  [NB_ADDR-1:0]     tb_rd;
    reg  [NB_FUNCT3-1:0]   tb_funct3;
    reg  [NB_CTRL_IN-1:0]  tb_ctrl;
    wire                   tb_o_redirect;
    wire [NB_PC-1:0]       tb_o_redirect_pc;
    wire                   tb_o_valid;
    wire [NB_PC-1:0]       tb_o_pc;
    wire [NB_DATA-1:0]     tb_o_result;
    wire [NB_DATA-1:0]     tb_o_store_data;
    wire [NB_ADDR-1:0]     tb_o_rd;
    wire [NB_FUNCT3-1:0]   tb_o_funct3;
    wire                   tb_o_mem_write;
    wire                   tb_o_reg_write;
    wire                   tb_o_mem_to_reg;
    wire                   tb_o_halt;
    wire [NB_LATCH-1:0]    tb_o_latch;

    // Los 10 campos de las salidas, en el orden de §8
    wire [NB_CTRL-1:0]  dut_ctrl   = {tb_o_mem_write, tb_o_reg_write, tb_o_mem_to_reg,
                                      tb_o_halt};
    wire [NB_LATCH-1:0] dut_campos = {tb_o_valid, tb_o_pc, tb_o_result, tb_o_store_data,
                                      tb_o_rd, tb_o_funct3, dut_ctrl};

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer t;

    // Modelo de EX/MEM
    reg                 m_valid;
    reg [NB_PC-1:0]     m_pc;
    reg [NB_DATA-1:0]   m_result;
    reg [NB_DATA-1:0]   m_store;
    reg [NB_ADDR-1:0]   m_rd;
    reg [NB_FUNCT3-1:0] m_funct3;
    reg [NB_CTRL-1:0]   m_ctrl;
    reg                 m_hold;
    reg [NB_LATCH-1:0]  foto;

    // Salidas combinacionales del modelo de EX (ex_ref)
    reg                 r_redirect;
    reg [NB_PC-1:0]     r_redirect_pc;
    reg [NB_DATA-1:0]   r_result;
    reg [NB_DATA-1:0]   r_store;

    ex_stage #(
        .NB_PC       (NB_PC),
        .NB_DATA     (NB_DATA),
        .NB_ADDR     (NB_ADDR),
        .NB_FUNCT3   (NB_FUNCT3),
        .NB_ALU_CTRL (NB_ALU_CTRL),
        .NB_FWD      (NB_FWD)
    ) u_dut (
        .i_clk               (tb_clk),
        .i_rst               (tb_rst),
        .i_en_ex_mem         (tb_en_ex_mem),
        .i_flush             (tb_flush),
        .i_fwd_a             (tb_fwd_a),
        .i_fwd_b             (tb_fwd_b),
        .i_wb_data           (tb_wb_data),
        .i_id_ex_valid       (tb_valid),
        .i_id_ex_pc          (tb_pc),
        .i_id_ex_rs1_data    (tb_rs1_data),
        .i_id_ex_rs2_data    (tb_rs2_data),
        .i_id_ex_imm         (tb_imm),
        .i_id_ex_rd          (tb_rd),
        .i_id_ex_funct3      (tb_funct3),
        .i_id_ex_alu_ctrl    (tb_ctrl[12:9]),
        .i_id_ex_alu_src_a   (tb_ctrl[8]),
        .i_id_ex_alu_src_b   (tb_ctrl[7]),
        .i_id_ex_branch      (tb_ctrl[6]),
        .i_id_ex_jal         (tb_ctrl[5]),
        .i_id_ex_jalr        (tb_ctrl[4]),
        .i_id_ex_mem_write   (tb_ctrl[3]),
        .i_id_ex_reg_write   (tb_ctrl[2]),
        .i_id_ex_mem_to_reg  (tb_ctrl[1]),
        .i_id_ex_halt        (tb_ctrl[0]),
        .o_redirect          (tb_o_redirect),
        .o_redirect_pc       (tb_o_redirect_pc),
        .o_ex_mem_valid      (tb_o_valid),
        .o_ex_mem_pc         (tb_o_pc),
        .o_ex_mem_result     (tb_o_result),
        .o_ex_mem_store_data (tb_o_store_data),
        .o_ex_mem_rd         (tb_o_rd),
        .o_ex_mem_funct3     (tb_o_funct3),
        .o_ex_mem_mem_write  (tb_o_mem_write),
        .o_ex_mem_reg_write  (tb_o_reg_write),
        .o_ex_mem_mem_to_reg (tb_o_mem_to_reg),
        .o_ex_mem_halt       (tb_o_halt),
        .o_ex_mem_latch      (tb_o_latch)
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

    // Filas R e I aritmética de §4.4 con su alu_ctrl
    function [NB_CTRL_IN-1:0] c_r;
        input [NB_ALU_CTRL-1:0] op;
        begin
            c_r = {op, 9'b0_0_0__0___0__0__1___0__0};
        end
    endfunction

    function [NB_CTRL_IN-1:0] c_i;
        input [NB_ALU_CTRL-1:0] op;
        begin
            c_i = {op, 9'b0_1_0__0___0__0__1___0__0};
        end
    endfunction

    //------------------------------------------------------------------
    // Contenido de EX/MEM contra lo esperado. En una burbuja solo valid y
    // control (latches.py)
    //------------------------------------------------------------------
    task chk_ex_mem;
        input [8*24-1:0]      etiqueta;
        input                 valid;
        input [NB_PC-1:0]     pc;
        input [NB_DATA-1:0]   result;
        input [NB_DATA-1:0]   store;
        input [NB_ADDR-1:0]   rd;
        input [NB_FUNCT3-1:0] funct3;
        input [NB_CTRL-1:0]   ctrl;
        reg   [8*40-1:0]      n;
        begin
            $sformat(n, "%0s valid", etiqueta);   chk(n, tb_o_valid, valid);
            $sformat(n, "%0s control", etiqueta); chk(n, dut_ctrl, ctrl);
            if (valid) begin
                $sformat(n, "%0s pc", etiqueta);         chk(n, tb_o_pc, pc);
                $sformat(n, "%0s result", etiqueta);     chk(n, tb_o_result, result);
                $sformat(n, "%0s store_data", etiqueta); chk(n, tb_o_store_data, store);
                $sformat(n, "%0s rd", etiqueta);         chk(n, tb_o_rd, rd);
                $sformat(n, "%0s funct3", etiqueta);     chk(n, tb_o_funct3, funct3);
            end
            $sformat(n, "%0s o_ex_mem_latch", etiqueta);
            chk_latch(n, tb_o_latch, dut_campos);
        end
    endtask

    // Instrucción en ID/EX (en un flanco de bajada); el forwarding se
    // elige aparte con tb_fwd_a, tb_fwd_b y tb_wb_data
    task entrada;
        input                  valid;
        input [NB_CTRL_IN-1:0] ctrl;
        input [NB_FUNCT3-1:0]  funct3;
        input [NB_ADDR-1:0]    rd;
        input [NB_PC-1:0]      pc;
        input [NB_DATA-1:0]    rs1_data;
        input [NB_DATA-1:0]    rs2_data;
        input [NB_DATA-1:0]    imm;
        begin
            tb_valid    = valid;
            tb_ctrl     = ctrl;
            tb_funct3   = funct3;
            tb_rd       = rd;
            tb_pc       = pc;
            tb_rs1_data = rs1_data;
            tb_rs2_data = rs2_data;
            tb_imm      = imm;
        end
    endtask

    // Comprueba la salida de saltos antes del flanco y EX/MEM en el
    // flanco de bajada siguiente. Con flush entra una burbuja (§2)
    task caso;
        input [8*24-1:0]    nombre;
        input [NB_DATA-1:0] result;
        input [NB_DATA-1:0] store;
        input               redirect;
        input [NB_PC-1:0]   redirect_pc;
        reg   [8*40-1:0]    n;
        begin
            #1;
            $sformat(n, "%0s redirect", nombre);    chk(n, tb_o_redirect, redirect);
            $sformat(n, "%0s redirect_pc", nombre); chk(n, tb_o_redirect_pc, redirect_pc);
            @(negedge tb_clk);
            chk_ex_mem(nombre, tb_valid & ~tb_flush, tb_pc, result, store, tb_rd,
                       tb_funct3, (tb_valid & ~tb_flush) ? tb_ctrl[3:0] : {NB_CTRL{1'b0}});
        end
    endtask

    //------------------------------------------------------------------
    // Modelo de EX (pipeline.md §5.1 a §5.4), sobre el EX/MEM del modelo
    //------------------------------------------------------------------
    function [NB_DATA-1:0] alu_ref;
        input [NB_DATA-1:0]     a;
        input [NB_DATA-1:0]     b;
        input [NB_ALU_CTRL-1:0] op;
        begin
            case (op)
                A_ADD:   alu_ref = a + b;
                A_SUB:   alu_ref = a - b;
                A_SLL:   alu_ref = a << b[4:0];
                A_SLT:   alu_ref = ($signed(a) < $signed(b)) ? 1 : 0;
                A_SLTU:  alu_ref = (a < b) ? 1 : 0;
                A_XOR:   alu_ref = a ^ b;
                A_SRL:   alu_ref = a >> b[4:0];
                A_SRA:   alu_ref = $signed(a) >>> b[4:0];
                A_OR:    alu_ref = a | b;
                A_AND:   alu_ref = a & b;
                default: alu_ref = {NB_DATA{1'b0}};
            endcase
        end
    endfunction

    function [NB_DATA-1:0] fwd_ref;
        input [NB_FWD-1:0]  sel;
        input [NB_DATA-1:0] leido;
        begin
            if (sel == F_EM)
                fwd_ref = m_result;
            else if (sel == F_WB)
                fwd_ref = tb_wb_data;
            else
                fwd_ref = leido;
        end
    endfunction

    task ex_ref;
        reg [NB_DATA-1:0] rs1_val;
        reg [NB_DATA-1:0] rs2_val;
        reg [NB_DATA-1:0] alu_out;
        begin
            rs1_val = fwd_ref(tb_fwd_a, tb_rs1_data);
            rs2_val = fwd_ref(tb_fwd_b, tb_rs2_data);
            alu_out = alu_ref(tb_ctrl[8] ? {NB_DATA{1'b0}} : rs1_val,
                              tb_ctrl[7] ? tb_imm : rs2_val, tb_ctrl[12:9]);
            // beq salta si son iguales, bne si son distintos (isa.md)
            r_redirect = (tb_ctrl[6] && ((rs1_val == rs2_val) ^ tb_funct3[0]))
                         || tb_ctrl[5] || tb_ctrl[4];
            r_redirect_pc = tb_ctrl[4] ? (alu_out & ~32'h1) : tb_pc + tb_imm;
            r_result = (tb_ctrl[5] || tb_ctrl[4]) ? tb_pc + 4 : alu_out;
            r_store  = rs2_val;
        end
    endtask

    // Paso de EX/MEM en un flanco de subida (§2); ex_ref ya calculado
    task modelo;
        begin
            m_hold = 1'b0;
            if (tb_rst) begin
                m_valid = 1'b0;
                m_ctrl  = {NB_CTRL{1'b0}};
            end
            else if (tb_en_ex_mem) begin
                m_valid  = tb_valid & ~tb_flush;
                m_ctrl   = (tb_valid & ~tb_flush) ? tb_ctrl[3:0] : {NB_CTRL{1'b0}};
                m_pc     = tb_pc;
                m_result = r_result;
                m_store  = r_store;
                m_rd     = tb_rd;
                m_funct3 = tb_funct3;
            end
            else
                m_hold = 1'b1;
        end
    endtask

    // Una fila de la tabla de §4.4 al azar, con un funct3 que control_unit
    // acepta para esa fila
    task fila_al_azar;
        reg [3:0] op;
        begin
            t = $random(seed) & 15;
            case ({$random(seed)} % 10)
                0: op = A_ADD;  1: op = A_SUB;  2: op = A_SLL;  3: op = A_SLT;
                4: op = A_SLTU; 5: op = A_XOR;  6: op = A_SRL;  7: op = A_SRA;
                8: op = A_OR;   default: op = A_AND;
            endcase
            tb_valid  = 1'b1;
            tb_funct3 = $random(seed);
            case (t)
                0, 1, 2: begin tb_ctrl = c_r(op); tb_funct3 = op[2:0]; end
                3, 4: begin
                    if (op == A_SUB) op = A_ADD;    // no hay subi (§4.5)
                    tb_ctrl = c_i(op); tb_funct3 = op[2:0];
                end
                5:  tb_ctrl = C_LOAD;
                6:  tb_ctrl = C_STORE;
                7:  begin tb_ctrl = C_BR; tb_funct3 = 3'b000; end    // beq
                8:  begin tb_ctrl = C_BR; tb_funct3 = 3'b001; end    // bne
                9:  tb_ctrl = C_JAL;
                10: begin tb_ctrl = C_JALR; tb_funct3 = 3'b000; end
                11: tb_ctrl = C_LUI;
                12: tb_ctrl = C_HALT;
                13: tb_ctrl = C_NOP;                                // no reconocida
                default: begin tb_ctrl = C_NOP; tb_valid = 1'b0; end // burbuja
            endcase
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors       = 0;
        checks       = 0;
        seed         = SEED;
        tb_rst       = 1'b1;
        tb_en_ex_mem = 1'b1;
        tb_flush     = 1'b0;
        tb_fwd_a     = F_ID;
        tb_fwd_b     = F_ID;
        tb_wb_data   = 32'h0BAD_0BAD;
        // basura válida a la entrada durante el reset
        entrada(1'b1, C_JAL | C_HALT, 3'b111, 5'd31, 32'hFFFF_FFFC, 32'h1, 32'h2, 32'h3);

        //--------------------------------------------------------------
        // Reset: EX/MEM en burbuja
        //--------------------------------------------------------------
        repeat (2) @(negedge tb_clk);
        chk_ex_mem("reset", 1'b0, 0, 0, 0, 0, 0, 4'b0000);
        tb_rst = 1'b0;

        //--------------------------------------------------------------
        // Una instrucción por fila; esperados a mano
        //--------------------------------------------------------------
        //            valid ctrl          f3      rd     pc            rs1           rs2           imm
        entrada(1'b1, c_r(A_ADD),  3'b000, 5'd5,  32'h0000_0100, 32'h7FFF_FFFF, 32'h0000_0001, 32'h10);
        caso("add",  32'h8000_0000, 32'h0000_0001, 1'b0, 32'h0000_0110);
        entrada(1'b1, c_r(A_SUB),  3'b000, 5'd6,  32'h0000_0104, 32'h0000_0005, 32'h0000_0007, 32'h10);
        caso("sub",  32'hFFFF_FFFE, 32'h0000_0007, 1'b0, 32'h0000_0114);
        entrada(1'b1, c_r(A_SLL),  3'b001, 5'd7,  32'h0000_0108, 32'h0000_0001, 32'hFFFF_FFE5, 32'h10);
        caso("sll",  32'h0000_0020, 32'hFFFF_FFE5, 1'b0, 32'h0000_0118);
        entrada(1'b1, c_r(A_SLT),  3'b010, 5'd8,  32'h0000_010C, 32'hFFFF_FFFF, 32'h0000_0001, 32'h10);
        caso("slt",  32'h0000_0001, 32'h0000_0001, 1'b0, 32'h0000_011C);
        entrada(1'b1, c_r(A_SLTU), 3'b011, 5'd9,  32'h0000_0110, 32'hFFFF_FFFF, 32'h0000_0001, 32'h10);
        caso("sltu", 32'h0000_0000, 32'h0000_0001, 1'b0, 32'h0000_0120);
        entrada(1'b1, c_r(A_XOR),  3'b100, 5'd10, 32'h0000_0114, 32'hF0F0_F0F0, 32'hFF00_FF00, 32'h10);
        caso("xor",  32'h0FF0_0FF0, 32'hFF00_FF00, 1'b0, 32'h0000_0124);
        entrada(1'b1, c_r(A_SRL),  3'b101, 5'd11, 32'h0000_0118, 32'h8000_0000, 32'h0000_001F, 32'h10);
        caso("srl",  32'h0000_0001, 32'h0000_001F, 1'b0, 32'h0000_0128);
        entrada(1'b1, c_r(A_SRA),  3'b101, 5'd12, 32'h0000_011C, 32'h8000_0000, 32'h0000_0004, 32'h10);
        caso("sra",  32'hF800_0000, 32'h0000_0004, 1'b0, 32'h0000_012C);
        entrada(1'b1, c_r(A_OR),   3'b110, 5'd13, 32'h0000_0120, 32'hF0F0_0000, 32'h0000_0F0F, 32'h10);
        caso("or",   32'hF0F0_0F0F, 32'h0000_0F0F, 1'b0, 32'h0000_0130);
        entrada(1'b1, c_r(A_AND),  3'b111, 5'd14, 32'h0000_0124, 32'hFFFF_0000, 32'h0F0F_0F0F, 32'h10);
        caso("and",  32'h0F0F_0000, 32'h0F0F_0F0F, 1'b0, 32'h0000_0134);

        entrada(1'b1, c_i(A_ADD),  3'b000, 5'd15, 32'h0000_0128, 32'h0000_0002, 32'h0000_1234, 32'hFFFF_FFFD);
        caso("addi -3", 32'hFFFF_FFFF, 32'h0000_1234, 1'b0, 32'h0000_0125);
        entrada(1'b1, C_LUI,       3'b110, 5'd4,  32'h0000_012C, 32'hDEAD_BEEF, 32'h0000_0000, 32'hABCD_E000);
        caso("lui",  32'hABCD_E000, 32'h0000_0000, 1'b0, 32'hABCD_E12C);
        entrada(1'b1, C_LOAD,      3'b010, 5'd20, 32'h0000_0130, 32'h0000_0100, 32'h0000_0077, 32'hFFFF_FFF8);
        caso("lw -8", 32'h0000_00F8, 32'h0000_0077, 1'b0, 32'h0000_0128);
        entrada(1'b1, C_STORE,     3'b010, 5'd24, 32'h0000_0134, 32'h0000_0200, 32'hCAFE_BABE, 32'hFFFF_FFF4);
        caso("sw -12", 32'h0000_01F4, 32'hCAFE_BABE, 1'b0, 32'h0000_0128);

        entrada(1'b1, C_BR,        3'b000, 5'd17, 32'h0000_0140, 32'h0000_0055, 32'h0000_0055, 32'hFFFF_FFF0);
        caso("beq tomado", 32'h0000_0000, 32'h0000_0055, 1'b1, 32'h0000_0130);
        entrada(1'b1, C_BR,        3'b000, 5'd18, 32'h0000_0144, 32'h0000_0055, 32'h0000_0056, 32'hFFFF_FFF0);
        caso("beq no tomado", 32'hFFFF_FFFF, 32'h0000_0056, 1'b0, 32'h0000_0134);
        entrada(1'b1, C_BR,        3'b001, 5'd19, 32'h0000_0148, 32'h0000_0001, 32'h0000_0002, 32'h0000_0400);
        caso("bne tomado", 32'hFFFF_FFFF, 32'h0000_0002, 1'b1, 32'h0000_0548);
        entrada(1'b1, C_BR,        3'b001, 5'd20, 32'h0000_014C, 32'h0000_0009, 32'h0000_0009, 32'h0000_0400);
        caso("bne no tomado", 32'h0000_0000, 32'h0000_0009, 1'b0, 32'h0000_054C);
        entrada(1'b1, C_JAL,       3'b111, 5'd1,  32'h0000_1000, 32'h0000_0033, 32'h0000_0044, 32'hFFFF_F800);
        caso("jal -2048", 32'h0000_1004, 32'h0000_0044, 1'b1, 32'h0000_0800);
        entrada(1'b1, C_JALR,      3'b000, 5'd2,  32'h0000_3000, 32'h0000_2001, 32'h0000_0055, 32'h0000_000C);
        caso("jalr bit 0", 32'h0000_3004, 32'h0000_0055, 1'b1, 32'h0000_200C);
        entrada(1'b1, C_HALT,      3'b000, 5'd0,  32'h0000_0150, 32'h0000_0010, 32'h0000_0020, 32'h0000_0001);
        caso("halt", 32'h0000_0030, 32'h0000_0020, 1'b0, 32'h0000_0151);
        entrada(1'b1, C_NOP,       3'b000, 5'd0,  32'h0000_0154, 32'h0000_0010, 32'h0000_0020, 32'h0000_0000);
        caso("no reconocida", 32'h0000_0030, 32'h0000_0020, 1'b0, 32'h0000_0154);
        entrada(1'b0, C_NOP,       3'b000, 5'd3,  32'h0000_0158, 32'h0000_0010, 32'h0000_0020, 32'h0000_0000);
        caso("burbuja", 32'h0, 32'h0, 1'b0, 32'h0000_0158);

        //--------------------------------------------------------------
        // Forwarding (§5.1). La entrada 10 es lo que quedó en EX/MEM en
        // el caso anterior
        //--------------------------------------------------------------
        entrada(1'b1, c_r(A_ADD),  3'b000, 5'd5,  32'h0000_0200, 32'h1111_0000, 32'h0000_0000, 32'h0);
        caso("antes del forwarding", 32'h1111_0000, 32'h0000_0000, 1'b0, 32'h0000_0200);

        tb_fwd_a = F_EM;
        entrada(1'b1, c_r(A_ADD),  3'b000, 5'd6,  32'h0000_0204, 32'hDEAD_0001, 32'h0000_0005, 32'h0);
        caso("fwd_a = 10", 32'h1111_0005, 32'h0000_0005, 1'b0, 32'h0000_0204);
        tb_fwd_a = F_WB; tb_wb_data = 32'h2222_0000;
        entrada(1'b1, c_r(A_ADD),  3'b000, 5'd7,  32'h0000_0208, 32'hDEAD_0002, 32'h0000_0005, 32'h0);
        caso("fwd_a = 01", 32'h2222_0005, 32'h0000_0005, 1'b0, 32'h0000_0208);
        tb_fwd_a = F_ID; tb_fwd_b = F_EM;
        entrada(1'b1, c_r(A_SUB),  3'b000, 5'd8,  32'h0000_020C, 32'h3000_0000, 32'hDEAD_0003, 32'h0);
        caso("fwd_b = 10", 32'h0DDD_FFFB, 32'h2222_0005, 1'b0, 32'h0000_020C);
        tb_fwd_b = F_WB; tb_wb_data = 32'h0000_0100;
        entrada(1'b1, c_r(A_SUB),  3'b000, 5'd9,  32'h0000_0210, 32'h0000_1000, 32'hDEAD_0004, 32'h0);
        caso("fwd_b = 01", 32'h0000_0F00, 32'h0000_0100, 1'b0, 32'h0000_0210);
        tb_fwd_a = 2'b11; tb_fwd_b = 2'b11; tb_wb_data = 32'h0000_9999;
        entrada(1'b1, c_r(A_ADD),  3'b000, 5'd10, 32'h0000_0214, 32'h0000_0040, 32'h0000_0002, 32'h0);
        caso("fwd = 11", 32'h0000_0042, 32'h0000_0002, 1'b0, 32'h0000_0214);
        tb_fwd_a = F_EM; tb_fwd_b = F_WB; tb_wb_data = 32'h0000_0008;
        entrada(1'b1, c_r(A_SUB),  3'b000, 5'd11, 32'h0000_0218, 32'hDEAD_0005, 32'hDEAD_0006, 32'h0);
        caso("fwd_a = 10, fwd_b = 01", 32'h0000_003A, 32'h0000_0008, 1'b0, 32'h0000_0218);
        tb_fwd_a = F_WB; tb_fwd_b = F_EM; tb_wb_data = 32'h0000_0100;
        entrada(1'b1, c_r(A_SUB),  3'b000, 5'd12, 32'h0000_021C, 32'hDEAD_0007, 32'hDEAD_0008, 32'h0);
        caso("fwd_a = 01, fwd_b = 10", 32'h0000_00C6, 32'h0000_003A, 1'b0, 32'h0000_021C);

        // store_data sale de rs2_val (§5.5)
        tb_fwd_a = F_ID; tb_fwd_b = F_EM;
        entrada(1'b1, C_STORE,     3'b010, 5'd0,  32'h0000_0220, 32'h0000_0300, 32'hDEAD_0009, 32'h4);
        caso("sw con fwd_b = 10", 32'h0000_0304, 32'h0000_00C6, 1'b0, 32'h0000_0224);
        tb_fwd_a = F_EM; tb_fwd_b = F_WB; tb_wb_data = 32'hABCD_0123;
        entrada(1'b1, C_STORE,     3'b000, 5'd0,  32'h0000_0224, 32'hDEAD_000A, 32'hDEAD_000B, 32'h8);
        caso("sb con fwd_a = 10, fwd_b = 01", 32'h0000_030C, 32'hABCD_0123, 1'b0, 32'h0000_022C);

        // Operando que el control descarta: el mux de A o de B no lo usa
        tb_fwd_a = F_ID; tb_fwd_b = F_EM;
        entrada(1'b1, c_i(A_ADD),  3'b000, 5'd13, 32'h0000_0228, 32'h0000_0010, 32'hDEAD_000C, 32'h1);
        caso("addi con fwd_b = 10", 32'h0000_0011, 32'h0000_030C, 1'b0, 32'h0000_0229);
        tb_fwd_a = F_WB; tb_fwd_b = F_ID; tb_wb_data = 32'h0000_FFFF;
        entrada(1'b1, C_LUI,       3'b000, 5'd14, 32'h0000_022C, 32'hDEAD_000D, 32'h0000_0000, 32'h1234_5000);
        caso("lui con fwd_a = 01", 32'h1234_5000, 32'h0000_0000, 1'b0, 32'h1234_522C);

        // Saltos con operandos reenviados
        tb_fwd_a = F_EM; tb_fwd_b = F_ID;
        entrada(1'b1, C_BR,        3'b000, 5'd15, 32'h0000_0400, 32'hDEAD_000E, 32'h1234_5000, 32'h20);
        caso("beq con fwd_a = 10", 32'h0000_0000, 32'h1234_5000, 1'b1, 32'h0000_0420);
        tb_fwd_a = F_ID; tb_fwd_b = F_WB; tb_wb_data = 32'h0000_0007;
        entrada(1'b1, C_BR,        3'b001, 5'd16, 32'h0000_0404, 32'h0000_0007, 32'h0000_0008, 32'h20);
        caso("bne con fwd_b = 01", 32'h0000_0000, 32'h0000_0007, 1'b0, 32'h0000_0424);
        tb_fwd_a = F_WB; tb_fwd_b = F_ID; tb_wb_data = 32'h0000_5001;
        entrada(1'b1, C_JALR,      3'b000, 5'd17, 32'h0000_0600, 32'hDEAD_000F, 32'h0000_0000, 32'h10);
        caso("jalr con fwd_a = 01", 32'h0000_0604, 32'h0000_0000, 1'b1, 32'h0000_5010);
        tb_fwd_a = F_EM;
        entrada(1'b1, C_JALR,      3'b000, 5'd18, 32'h0000_0700, 32'hDEAD_0010, 32'h0000_0000, 32'h3);
        caso("jalr con fwd_a = 10", 32'h0000_0704, 32'h0000_0000, 1'b1, 32'h0000_0606);
        tb_fwd_a = F_ID; tb_fwd_b = F_ID;

        //--------------------------------------------------------------
        // en > flush, flush, reset con el core detenido
        //--------------------------------------------------------------
        entrada(1'b1, C_LOAD,      3'b100, 5'd21, 32'h0000_0800, 32'h0000_0010, 32'h0000_0BBB, 32'h5);
        caso("antes de retener", 32'h0000_0015, 32'h0000_0BBB, 1'b0, 32'h0000_0805);
        foto         = tb_o_latch;
        tb_en_ex_mem = 1'b0;
        entrada(1'b1, C_STORE,     3'b010, 5'd22, 32'h0000_0804, 32'h0000_0020, 32'h0000_0CCC, 32'h6);
        repeat (2) @(negedge tb_clk);
        chk_latch("en = 0: retenido", tb_o_latch, foto);
        tb_flush = 1'b1;
        entrada(1'b1, C_JAL | C_HALT, 3'b111, 5'd23, 32'h0000_0808, 32'h1, 32'h2, 32'h3);
        repeat (3) @(negedge tb_clk);
        chk_latch("en = 0 con flush = 1: retenido", tb_o_latch, foto);
        // redirect no depende de en: es combinacional (§5.3)
        #1;
        chk("redirect con en = 0", tb_o_redirect, 1'b1);
        chk("redirect_pc con en = 0", tb_o_redirect_pc, 32'h0000_080B);
        @(negedge tb_clk);

        tb_en_ex_mem = 1'b1;
        entrada(1'b1, c_r(A_ADD),  3'b000, 5'd24, 32'h0000_0900, 32'h1, 32'h2, 32'h0);
        caso("flush", 32'h3, 32'h2, 1'b0, 32'h0000_0900);
        entrada(1'b1, C_STORE | C_LOAD | C_HALT, 3'b010, 5'd25, 32'h0000_0904, 32'h1, 32'h2, 32'h0);
        caso("flush con todo el control", 32'h1, 32'h2, 1'b0, 32'h0000_0904);
        tb_flush = 1'b0;
        entrada(1'b1, C_JALR,      3'b000, 5'd26, 32'h0000_0908, 32'h0000_0100, 32'h2, 32'h1);
        caso("despues del flush", 32'h0000_090C, 32'h2, 1'b1, 32'h0000_0100);

        tb_en_ex_mem = 1'b0;
        tb_rst       = 1'b1;
        @(negedge tb_clk);
        tb_rst = 1'b0;
        chk_ex_mem("reset con el core detenido", 1'b0, 0, 0, 0, 0, 0, 4'b0000);

        //--------------------------------------------------------------
        // Aleatorio contra el modelo. Arranca con un reset para que el
        // modelo y el DUT partan del mismo estado
        //--------------------------------------------------------------
        m_valid = 1'b0;
        m_ctrl  = {NB_CTRL{1'b0}};
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            tb_rst       = (i == 0) || (($random(seed) & 63) == 0);
            tb_en_ex_mem = (($random(seed) & 7) != 0);
            tb_flush     = (($random(seed) & 7) == 0);
            fila_al_azar;
            tb_pc        = $random(seed);
            tb_rs1_data  = $random(seed);
            tb_rs2_data  = $random(seed);
            tb_imm       = $random(seed);
            tb_rd        = $random(seed);
            tb_wb_data   = $random(seed);
            // a veces operandos iguales, para que beq y bne salten
            if (($random(seed) & 3) == 0)
                tb_rs2_data = tb_rs1_data;
            tb_fwd_a     = $random(seed);
            tb_fwd_b     = $random(seed);
            if (!m_valid && tb_fwd_a == F_EM) tb_fwd_a = F_ID;
            if (!m_valid && tb_fwd_b == F_EM) tb_fwd_b = F_ID;
            ex_ref;
            #1;
            chk("aleatorio redirect", tb_o_redirect, r_redirect);
            chk("aleatorio redirect_pc", tb_o_redirect_pc, r_redirect_pc);
            foto = tb_o_latch;
            @(posedge tb_clk);
            modelo;
            @(negedge tb_clk);
            if (m_hold)
                chk_latch("aleatorio retenido", tb_o_latch, foto);
            else
                chk_ex_mem("aleatorio", m_valid, m_pc, m_result, m_store, m_rd, m_funct3,
                           m_ctrl);
        end

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
