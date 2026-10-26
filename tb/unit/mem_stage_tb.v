`timescale 1ns / 1ps

//======================================================================
// mem_stage_tb
//
// Testbench autoverificante de mem_stage (docs/spec/verificacion.md
// §3.1): dmem + mem_wb_reg conectados como pipeline.md §6. Los dos
// módulos ya tienen su testbench; este prueba el cableado entre ellos,
// sobre todo lo que la traza de pipeline_tb no ve en M6 (el flush, que
// vale 0 en el core, y los avisos, que salen del core en I-35).
// Simula el IP dmem_bram, así que corre en xsim dentro del proyecto de
// Vivado (run all).
//
// Casos:
//   - Reset: MEM/WB en burbuja (valid y control en 0) y avisos en 0
//   - Carga por el puerto B con el puerto A deshabilitado, como LOAD
//   - Un load: mem_wb_read_data llega en el mismo flanco que los demás
//     campos de MEM/WB; offset = result[1:0]
//   - Un store seguido de un load a la misma dirección devuelve el dato
//     escrito (sw, y sb y sh sobre una palabra con datos: los bytes
//     vecinos no cambian). En el ciclo del store, read_data es la
//     palabra de antes (READ_FIRST)
//   - en = 0 conserva los 110 bits, read_data incluido, aunque el puerto
//     B escriba la palabra que se estaba leyendo, y no escribe aunque
//     haya un store; también con flush = 1
//   - flush con en = 1 deja burbuja; el store de ese ciclo se escribe
//     igual (flush solo afecta a MEM/WB, §2)
//   - Avisos a la salida: lw desalineado, sw fuera de rango (cae en el
//     alias), persisten; una burbuja no los levanta; el reset los borra
//   - Reset con el core detenido
//   - Puerto B: lectura de lo que escribió el puerto A
//   - o_mem_wb_latch = los 10 campos en el orden de §8 (en cada chequeo)
//   - Aleatorio con semilla fija contra un modelo de §2 y de memoria por
//     bytes, y volcado final de las 1024 palabras por el puerto B
//
// El modelo de memoria es un arreglo de bytes: un store escribe sus 1, 2
// o 4 bytes desde la dirección alineada a su tamaño, dentro de los
// 4 KiB. No usa la máscara ni la replicación de pipeline.md §6.2
// (verificacion.md §2); los casos dirigidos además comparan contra
// constantes escritas a mano. Los funct3 son literales de isa.md.
//
// Como en la traza del modelo (tools/isasim/isasim/latches.py), en una
// burbuja solo se comparan valid y el control; en las retenciones se
// compara todo, bit a bit. Los avisos se comparan en cada ciclo.
//
// Los estímulos cambian en el flanco de bajada y se comprueban en el
// flanco de bajada siguiente, después de un flanco de subida.
//======================================================================

module mem_stage_tb;

    localparam integer NB_PC      = 32;
    localparam integer NB_DATA    = 32;
    localparam integer NB_ADDR    = 5;
    localparam integer NB_FUNCT3  = 3;
    localparam integer NB_CTRL    = 3;                               // de MEM/WB
    localparam integer NB_LATCH   = 1 + NB_PC + 2*NB_DATA + NB_ADDR
                                    + NB_FUNCT3 + 2 + NB_CTRL;       // 110 (§8)
    localparam integer DMEM_WORDS = 1024;
    localparam integer DMEM_BYTES = 4 * DMEM_WORDS;
    localparam integer T_CLK      = 10;     // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM   = 3000;   // ciclos de estímulo aleatorio
    localparam integer MAX_CYCLES = 12000;  // watchdog
    localparam integer SEED       = 46;     // semilla fija (issue #46)

    // funct3 de loads y stores (isa.md)
    localparam [2:0] F_B  = 3'b000;         // lb, sb
    localparam [2:0] F_H  = 3'b001;         // lh, sh
    localparam [2:0] F_W  = 3'b010;         // lw, sw
    localparam [2:0] F_BU = 3'b100;         // lbu
    localparam [2:0] F_HU = 3'b101;         // lhu

    // Control que llega de EX/MEM, {mem_write, reg_write, mem_to_reg, halt}
    localparam [3:0] C_NOP   = 4'b0000;
    localparam [3:0] C_ALU   = 4'b0100;
    localparam [3:0] C_LOAD  = 4'b0110;
    localparam [3:0] C_STORE = 4'b1000;
    localparam [3:0] C_HALT  = 4'b0001;

    reg                  tb_clk;
    reg                  tb_rst;
    reg                  tb_en;
    reg                  tb_flush;
    reg                  tb_valid;
    reg  [NB_PC-1:0]     tb_pc;
    reg  [NB_DATA-1:0]   tb_result;
    reg  [NB_DATA-1:0]   tb_store_data;
    reg  [NB_ADDR-1:0]   tb_rd;
    reg  [NB_FUNCT3-1:0] tb_funct3;
    reg  [3:0]           tb_ctrl;
    reg                  tb_b_en;
    reg  [3:0]           tb_b_we;
    reg  [9:0]           tb_b_addr;
    reg  [NB_DATA-1:0]   tb_b_din;
    wire                 tb_o_valid;
    wire [NB_PC-1:0]     tb_o_pc;
    wire [NB_DATA-1:0]   tb_o_result;
    wire [NB_DATA-1:0]   tb_o_read_data;
    wire [NB_ADDR-1:0]   tb_o_rd;
    wire [NB_FUNCT3-1:0] tb_o_funct3;
    wire [1:0]           tb_o_offset;
    wire                 tb_o_reg_write;
    wire                 tb_o_mem_to_reg;
    wire                 tb_o_halt;
    wire [NB_LATCH-1:0]  tb_o_latch;
    wire                 tb_o_oob;
    wire                 tb_o_misaligned;
    wire [NB_DATA-1:0]   tb_o_b_dout;

    // Los 10 campos de las salidas, en el orden de §8
    wire [NB_CTRL-1:0]  dut_ctrl   = {tb_o_reg_write, tb_o_mem_to_reg, tb_o_halt};
    wire [NB_LATCH-1:0] dut_campos = {tb_o_valid, tb_o_pc, tb_o_result, tb_o_read_data,
                                      tb_o_rd, tb_o_funct3, tb_o_offset, dut_ctrl};

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer k;

    // Modelo
    reg [7:0]           ref_mem [0:DMEM_BYTES-1];
    reg                 m_valid;
    reg [NB_PC-1:0]     m_pc;
    reg [NB_DATA-1:0]   m_result;
    reg [NB_DATA-1:0]   m_read_data;
    reg [NB_ADDR-1:0]   m_rd;
    reg [NB_FUNCT3-1:0] m_funct3;
    reg [1:0]           m_offset;
    reg [NB_CTRL-1:0]   m_ctrl;
    reg                 m_hold;
    reg                 m_oob;
    reg                 m_mis;
    reg [NB_LATCH-1:0]  foto;

    // Estímulo aleatorio
    reg [2:0]           r_op;
    reg [NB_DATA-1:0]   w;

    mem_stage #(
        .NB_PC     (NB_PC),
        .NB_DATA   (NB_DATA),
        .NB_ADDR   (NB_ADDR),
        .NB_FUNCT3 (NB_FUNCT3)
    ) u_dut (
        .i_clk               (tb_clk),
        .i_rst               (tb_rst),
        .i_en_mem_wb         (tb_en),
        .i_flush             (tb_flush),
        .i_ex_mem_valid      (tb_valid),
        .i_ex_mem_pc         (tb_pc),
        .i_ex_mem_result     (tb_result),
        .i_ex_mem_store_data (tb_store_data),
        .i_ex_mem_rd         (tb_rd),
        .i_ex_mem_funct3     (tb_funct3),
        .i_ex_mem_mem_write  (tb_ctrl[3]),
        .i_ex_mem_reg_write  (tb_ctrl[2]),
        .i_ex_mem_mem_to_reg (tb_ctrl[1]),
        .i_ex_mem_halt       (tb_ctrl[0]),
        .o_mem_wb_valid      (tb_o_valid),
        .o_mem_wb_pc         (tb_o_pc),
        .o_mem_wb_result     (tb_o_result),
        .o_mem_wb_read_data  (tb_o_read_data),
        .o_mem_wb_rd         (tb_o_rd),
        .o_mem_wb_funct3     (tb_o_funct3),
        .o_mem_wb_offset     (tb_o_offset),
        .o_mem_wb_reg_write  (tb_o_reg_write),
        .o_mem_wb_mem_to_reg (tb_o_mem_to_reg),
        .o_mem_wb_halt       (tb_o_halt),
        .o_mem_wb_latch      (tb_o_latch),
        .o_dmem_oob          (tb_o_oob),
        .o_dmem_misaligned   (tb_o_misaligned),
        .i_dmem_b_en         (tb_b_en),
        .i_dmem_b_we         (tb_b_we),
        .i_dmem_b_addr       (tb_b_addr),
        .i_dmem_b_din        (tb_b_din),
        .o_dmem_b_dout       (tb_o_b_dout)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Chequeos con etiqueta
    //------------------------------------------------------------------
    task chk;
        input [8*44-1:0]    name;
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
        input [8*44-1:0]     name;
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

    //------------------------------------------------------------------
    // Modelo de memoria por bytes
    //------------------------------------------------------------------
    // Bytes que toca un load o un store según su funct3 (isa.md)
    function integer tam;
        input [NB_FUNCT3-1:0] f3;
        begin
            case (f3)
                F_B, F_BU: tam = 1;
                F_H, F_HU: tam = 2;
                default:   tam = 4;
            endcase
        end
    endfunction

    // Palabra idx, little-endian
    function [NB_DATA-1:0] ref_word;
        input integer idx;
        begin
            ref_word = {ref_mem[4*idx+3], ref_mem[4*idx+2],
                        ref_mem[4*idx+1], ref_mem[4*idx]};
        end
    endfunction

    // Store: n bytes desde la dirección alineada a n, en addr mod 4096
    task ref_store;
        input [NB_DATA-1:0]   addr;
        input [NB_FUNCT3-1:0] f3;
        input [NB_DATA-1:0]   d;
        integer n;
        integer base;
        integer j;
        begin
            n    = tam(f3);
            base = addr % DMEM_BYTES;
            base = base - base % n;
            for (j = 0; j < n; j = j + 1)
                ref_mem[base + j] = d[8*j +: 8];
        end
    endtask

    task ref_set_word;
        input integer       idx;
        input [NB_DATA-1:0] d;
        integer j;
        begin
            for (j = 0; j < 4; j = j + 1)
                ref_mem[4*idx + j] = d[8*j +: 8];
        end
    endtask

    //------------------------------------------------------------------
    // Paso del modelo en un flanco de subida: dmem (memoria.md §3.3,
    // §6.2) y MEM/WB (pipeline.md §2). Se llama con las entradas puestas
    //------------------------------------------------------------------
    task modelo;
        reg store;
        reg load;
        begin
            store  = tb_ctrl[3];
            load   = tb_ctrl[1];
            m_hold = 1'b0;
            // dmem: lee la palabra de antes (READ_FIRST) y escribe el store
            if (tb_en) begin
                m_read_data = ref_word((tb_result % DMEM_BYTES) / 4);
                if (store)
                    ref_store(tb_result, tb_funct3, tb_store_data);
            end
            // avisos
            if (tb_rst) begin
                m_oob = 1'b0;
                m_mis = 1'b0;
            end
            else if (tb_en && (store || load)) begin
                if (tb_result >= DMEM_BYTES)              m_oob = 1'b1;
                if (tb_result % tam(tb_funct3) != 0)      m_mis = 1'b1;
            end
            // MEM/WB
            if (tb_rst) begin
                m_valid = 1'b0;
                m_ctrl  = {NB_CTRL{1'b0}};
            end
            else if (tb_en) begin
                m_valid  = tb_valid & ~tb_flush;
                m_ctrl   = (tb_valid & ~tb_flush) ? tb_ctrl[2:0] : {NB_CTRL{1'b0}};
                m_pc     = tb_pc;
                m_result = tb_result;
                m_rd     = tb_rd;
                m_funct3 = tb_funct3;
                m_offset = tb_result[1:0];
            end
            else
                m_hold = 1'b1;
        end
    endtask

    // MEM/WB contra el modelo. En una burbuja solo valid y control
    task chk_mem_wb;
        input [8*24-1:0] etiqueta;
        reg   [8*44-1:0] n;
        begin
            $sformat(n, "%0s valid", etiqueta);   chk(n, tb_o_valid, m_valid);
            $sformat(n, "%0s control", etiqueta); chk(n, dut_ctrl, m_ctrl);
            if (m_valid) begin
                $sformat(n, "%0s pc", etiqueta);        chk(n, tb_o_pc, m_pc);
                $sformat(n, "%0s result", etiqueta);    chk(n, tb_o_result, m_result);
                $sformat(n, "%0s read_data", etiqueta); chk(n, tb_o_read_data, m_read_data);
                $sformat(n, "%0s rd", etiqueta);        chk(n, tb_o_rd, m_rd);
                $sformat(n, "%0s funct3", etiqueta);    chk(n, tb_o_funct3, m_funct3);
                $sformat(n, "%0s offset", etiqueta);    chk(n, tb_o_offset, m_offset);
            end
            $sformat(n, "%0s o_dmem_oob", etiqueta);        chk(n, tb_o_oob, m_oob);
            $sformat(n, "%0s o_dmem_misaligned", etiqueta); chk(n, tb_o_misaligned, m_mis);
            $sformat(n, "%0s o_mem_wb_latch", etiqueta);
            chk_latch(n, tb_o_latch, dut_campos);
        end
    endtask

    // Una instrucción en EX/MEM durante un ciclo: entra en un flanco de
    // bajada y MEM/WB se compara en el siguiente
    task ciclo;
        input [8*24-1:0]      nombre;
        input                 valid;
        input [3:0]           ctrl;
        input [NB_FUNCT3-1:0] f3;
        input [NB_DATA-1:0]   addr;
        input [NB_DATA-1:0]   d;
        begin
            tb_valid      = valid;
            tb_ctrl       = ctrl;
            tb_funct3     = f3;
            tb_result     = addr;
            tb_store_data = d;
            tb_pc         = tb_pc + 4;
            tb_rd         = tb_rd + 1;
            foto          = tb_o_latch;
            @(posedge tb_clk);
            modelo;
            @(negedge tb_clk);
            if (m_hold)
                chk_latch({nombre, " retenido"}, tb_o_latch, foto);
            chk_mem_wb(nombre);
        end
    endtask

    // Una palabra por el puerto B (con el puerto A quieto): escritura
    // completa o lectura, que se compara un ciclo después
    task puerto_b;
        input               we;
        input [9:0]         addr;
        input [NB_DATA-1:0] din;
        input [NB_DATA-1:0] esperado;
        input               comparar;
        begin
            tb_b_en   = 1'b1;
            tb_b_we   = we ? 4'b1111 : 4'b0000;
            tb_b_addr = addr;
            tb_b_din  = din;
            @(negedge tb_clk);
            if (we)
                ref_set_word(addr, din);
            else if (comparar)
                chk("puerto B", tb_o_b_dout, esperado);
            tb_b_en = 1'b0;
            tb_b_we = 4'b0000;
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors        = 0;
        checks        = 0;
        seed          = SEED;
        tb_rst        = 1'b1;
        tb_en         = 1'b1;
        tb_flush      = 1'b0;
        tb_valid      = 1'b1;              // basura válida durante el reset
        tb_pc         = 32'h0000_0200;
        tb_result     = 32'h0000_0000;
        tb_store_data = 32'h0;
        tb_rd         = 5'd0;
        tb_funct3     = F_W;
        tb_ctrl       = C_LOAD | C_HALT;
        tb_b_en       = 1'b0;
        tb_b_we       = 4'b0000;
        tb_b_addr     = 10'd0;
        tb_b_din      = 32'h0;
        for (k = 0; k < DMEM_BYTES; k = k + 1)
            ref_mem[k] = 8'h00;
        m_valid = 1'b0;
        m_ctrl  = {NB_CTRL{1'b0}};
        m_oob   = 1'b0;
        m_mis   = 1'b0;

        //--------------------------------------------------------------
        // Reset: MEM/WB en burbuja, avisos en 0
        //--------------------------------------------------------------
        repeat (2) @(negedge tb_clk);
        chk_mem_wb("reset");

        //--------------------------------------------------------------
        // Carga por el puerto B con el puerto A deshabilitado (LOAD)
        //--------------------------------------------------------------
        tb_en = 1'b0;
        puerto_b(1'b1, 10'h040, 32'hDEAD_BEEF, 0, 1'b0);   // 0x100
        puerto_b(1'b1, 10'h041, 32'h7F01_8040, 0, 1'b0);   // 0x104
        puerto_b(1'b1, 10'h3FF, 32'hCAFE_BABE, 0, 1'b0);   // 0xFFC
        tb_rst = 1'b0;
        tb_en  = 1'b1;

        //--------------------------------------------------------------
        // Loads: read_data con el resto de MEM/WB; offset = result[1:0]
        //--------------------------------------------------------------
        ciclo("lw 0x100", 1'b1, C_LOAD, F_W, 32'h0000_0100, 0);
        chk("lw 0x100 read_data", tb_o_read_data, 32'hDEAD_BEEF);
        ciclo("lb 0x107", 1'b1, C_LOAD, F_B, 32'h0000_0107, 0);
        chk("lb 0x107 read_data", tb_o_read_data, 32'h7F01_8040);
        chk("lb 0x107 offset", tb_o_offset, 2'd3);
        ciclo("lhu 0xFFE", 1'b1, C_LOAD, F_HU, 32'h0000_0FFE, 0);
        chk("lhu 0xFFE read_data", tb_o_read_data, 32'hCAFE_BABE);
        chk("lhu 0xFFE offset", tb_o_offset, 2'd2);

        //--------------------------------------------------------------
        // Store seguido de un load a la misma dirección
        //--------------------------------------------------------------
        ciclo("sw 0x040", 1'b1, C_STORE, F_W, 32'h0000_0040, 32'h1234_5678);
        chk("sw 0x040 READ_FIRST", tb_o_read_data, 32'h0000_0000);
        ciclo("lw 0x040", 1'b1, C_LOAD, F_W, 32'h0000_0040, 0);
        chk("lw 0x040 dato nuevo", tb_o_read_data, 32'h1234_5678);
        ciclo("sb 0x101", 1'b1, C_STORE, F_B, 32'h0000_0101, 32'hFFFF_FF11);
        chk("sb 0x101 READ_FIRST", tb_o_read_data, 32'hDEAD_BEEF);
        ciclo("lbu 0x101", 1'b1, C_LOAD, F_BU, 32'h0000_0101, 0);
        chk("lbu 0x101 palabra", tb_o_read_data, 32'hDEAD_11EF);
        ciclo("sh 0x106", 1'b1, C_STORE, F_H, 32'h0000_0106, 32'hAAAA_2233);
        ciclo("lh 0x104", 1'b1, C_LOAD, F_H, 32'h0000_0104, 0);
        chk("lh 0x104 palabra", tb_o_read_data, 32'h2233_8040);

        //--------------------------------------------------------------
        // en = 0: conserva los 110 bits y no escribe
        //--------------------------------------------------------------
        ciclo("lw 0x040 antes de retener", 1'b1, C_LOAD, F_W, 32'h0000_0040, 0);
        tb_en = 1'b0;
        // el puerto B escribe la palabra que el A estaba leyendo: read_data
        // no cambia porque es el registro de salida del puerto A
        tb_b_en   = 1'b1;
        tb_b_we   = 4'b1111;
        tb_b_addr = 10'h010;
        tb_b_din  = 32'h0BAD_F00D;
        ciclo("en = 0, B escribe", 1'b1, C_STORE, F_W, 32'h0000_0044, 32'hFFFF_FFFF);
        ref_set_word(10'h010, 32'h0BAD_F00D);
        tb_b_en  = 1'b0;
        tb_b_we  = 4'b0000;
        tb_flush = 1'b1;
        ciclo("en = 0 con flush", 1'b1, C_STORE | C_HALT, F_W, 32'h0000_0048, 32'hFFFF_FFFF);
        tb_flush = 1'b0;
        tb_en    = 1'b1;
        ciclo("lw 0x044 (no se escribió)", 1'b1, C_LOAD, F_W, 32'h0000_0044, 0);
        chk("en = 0 no escribe 0x044", tb_o_read_data, 32'h0000_0000);
        ciclo("lw 0x040 (B escribió)", 1'b1, C_LOAD, F_W, 32'h0000_0040, 0);
        chk("0x040 por B", tb_o_read_data, 32'h0BAD_F00D);

        //--------------------------------------------------------------
        // flush: burbuja en MEM/WB, el store se escribe igual
        //--------------------------------------------------------------
        tb_flush = 1'b1;
        ciclo("flush con store", 1'b1, C_STORE, F_W, 32'h0000_0050, 32'h5555_AAAA);
        ciclo("flush con load y halt", 1'b1, C_LOAD | C_HALT, F_W, 32'h0000_0050, 0);
        tb_flush = 1'b0;
        ciclo("lw 0x050 después del flush", 1'b1, C_LOAD, F_W, 32'h0000_0050, 0);
        chk("flush no anula el store", tb_o_read_data, 32'h5555_AAAA);

        //--------------------------------------------------------------
        // Avisos
        //--------------------------------------------------------------
        ciclo("burbuja con dirección mala", 1'b0, C_NOP, F_W, 32'h0000_1003, 0);
        ciclo("alu con dirección mala", 1'b1, C_ALU, F_W, 32'h0000_1003, 0);
        ciclo("lw desalineado", 1'b1, C_LOAD, F_W, 32'h0000_0102, 0);
        chk("lw desalineado aviso", tb_o_misaligned, 1'b1);
        ciclo("sw fuera de rango", 1'b1, C_STORE, F_W, 32'h0000_1060, 32'h7777_0001);
        chk("sw fuera de rango aviso", tb_o_oob, 1'b1);
        ciclo("lw alias 0x060", 1'b1, C_LOAD, F_W, 32'h0000_0060, 0);
        chk("alias 0x1060 -> 0x060", tb_o_read_data, 32'h7777_0001);
        ciclo("los avisos persisten", 1'b1, C_ALU, F_W, 32'h0000_0000, 0);

        //--------------------------------------------------------------
        // Reset con el core detenido
        //--------------------------------------------------------------
        tb_en  = 1'b0;
        tb_rst = 1'b1;
        ciclo("reset con el core detenido", 1'b1, C_LOAD, F_W, 32'h0000_1001, 0);
        tb_rst = 1'b0;
        tb_en  = 1'b1;

        //--------------------------------------------------------------
        // Puerto B: lee lo que escribió el puerto A
        //--------------------------------------------------------------
        tb_en = 1'b0;
        puerto_b(1'b0, 10'h014, 0, 32'h5555_AAAA, 1'b1);
        puerto_b(1'b0, 10'h041, 0, 32'h2233_8040, 1'b1);
        tb_en = 1'b1;

        //--------------------------------------------------------------
        // Aleatorio contra el modelo: 3/8 stores, 3/8 loads, 2/8 otros
        // (ALU, HALT, burbuja). Direcciones casi siempre en una ventana de
        // 48 bytes para que los accesos se pisen
        //--------------------------------------------------------------
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            tb_rst   = (($random(seed) & 63) == 0);
            tb_en    = (($random(seed) & 7) != 0);
            tb_flush = (($random(seed) & 7) == 0);
            r_op     = $random(seed);
            tb_store_data = $random(seed);
            tb_valid = 1'b1;
            if (r_op < 3) begin
                tb_ctrl = C_STORE;
                case ({$random(seed)} % 3)
                    0:       tb_funct3 = F_B;
                    1:       tb_funct3 = F_H;
                    default: tb_funct3 = F_W;
                endcase
            end
            else if (r_op < 6) begin
                tb_ctrl = C_LOAD;
                case ({$random(seed)} % 5)
                    0:       tb_funct3 = F_B;
                    1:       tb_funct3 = F_H;
                    2:       tb_funct3 = F_W;
                    3:       tb_funct3 = F_BU;
                    default: tb_funct3 = F_HU;
                endcase
            end
            else begin
                tb_funct3 = $random(seed);
                case ({$random(seed)} % 3)
                    0:       tb_ctrl = C_ALU;
                    1:       tb_ctrl = C_HALT;
                    default: begin tb_ctrl = C_NOP; tb_valid = 1'b0; end
                endcase
            end
            if (($random(seed) & 7) == 0)
                tb_result = $random(seed);
            else begin
                tb_result = 32'h0000_00F0 + {$random(seed)} % 48;
                if ($random(seed) & 1)
                    tb_result = tb_result - tb_result % tam(tb_funct3);
            end
            tb_pc = $random(seed);
            tb_rd = $random(seed);
            foto  = tb_o_latch;
            @(posedge tb_clk);
            modelo;
            @(negedge tb_clk);
            if (m_hold)
                chk_latch("aleatorio retenido", tb_o_latch, foto);
            chk_mem_wb("aleatorio");
        end
        tb_rst = 1'b0;

        // Volcado final por el puerto B contra el modelo
        tb_en = 1'b0;
        for (k = 0; k < DMEM_WORDS; k = k + 1)
            puerto_b(1'b0, k[9:0], 0, ref_word(k), 1'b1);

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
