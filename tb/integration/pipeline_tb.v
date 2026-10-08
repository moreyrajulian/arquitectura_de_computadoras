`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// pipeline_tb
//
// Banco de pruebas incremental del pipeline (I-17, decisión 021). Un único
// testbench que valida cada etapa al integrarla y queda como regresión de
// las siguientes (verificacion.md §1, nivel 2; con +FINAL, nivel 3).
//
// Qué compara:
//   - Traza: en cada ciclo, cada registro de segmentación integrado contra
//     la traza del modelo de referencia (tools/isasim, decisión 020):
//     (dut ^ ref) & mask, con los campos de pipeline.md §8 en el orden de
//     su tabla, el primero en los bits altos.
//   - Estado final (+FINAL, desde M7): registros, dmem, halted, pipeline
//     vacío, avisos y ciclos contra el .exp escrito a mano (§5).
//
// Uso:
//   python scripts/prep_tb.py sw/<programa>.s [--modo sin_riesgos|completo]
//   xsim ... -testplusarg DIR=<build/tb/<programa>, ruta absoluta> [-testplusarg FINAL]
//
// Etapas: cada integración agrega su define (abajo, o con -d en xvlog). Los
// defines son acumulativos: definir una etapa define las anteriores.
//
// Cortes de la traza (el modelo simula siempre el pipeline completo):
//   - sin STAGE_HALT (I-37) no hay parada por HALT: cada latch se compara
//     hasta el ciclo en que el HALT llega a él;
//   - sin STAGE_REDIRECT (I-36) el salto no vuelve a IF: el latch k
//     (0 = IF/ID) se compara hasta el ciclo r + 1 + k, con r el ciclo del
//     primer salto tomado en EX.
//
// Interfaz que espera de riscv_core (la implementa I-22, verificacion.md §8):
//   i_clk, i_rst, i_enable, i_imem_b_{en,we,addr,din}, o_halted
//   + STAGE_MEM: i_dmem_b_{en,we,addr,din}, o_dmem_b_dout
//   + STAGE_WB : o_imem_fault, o_dmem_oob, o_dmem_misaligned
//   y los campos de los latches como señales del módulo superior, con el
//   nombre <latch>_<campo> (u_dut.if_id_valid, u_dut.id_ex_alu_ctrl, ...).
//
// Latencia: el ciclo 1 es el primero después del reset (todos los latches
// en burbuja, PC = 0), igual que la línea 1 de la traza.
//======================================================================

//----------------------------------------------------------------------
// Etapas integradas. Descomentar la de cada integración.
//----------------------------------------------------------------------
`ifndef STAGE_IF
`define STAGE_IF                // I-22: IF/ID
`endif
// `define STAGE_ID             // I-27: ID/EX y banco de registros
// `define STAGE_EX             // I-31: EX/MEM
// `define STAGE_MEM            // I-34: MEM/WB y memoria de datos
// `define STAGE_WB             // I-35: escritura del banco, halted y avisos
// `define STAGE_REDIRECT       // I-36: el salto tomado cambia el PC
// `define STAGE_HALT           // I-37: parada por HALT (stop_fetch)

`ifdef STAGE_HALT
`ifndef STAGE_WB
`define STAGE_WB
`endif
`endif
`ifdef STAGE_REDIRECT
`ifndef STAGE_EX
`define STAGE_EX
`endif
`endif
`ifdef STAGE_WB
`ifndef STAGE_MEM
`define STAGE_MEM
`endif
`endif
`ifdef STAGE_MEM
`ifndef STAGE_EX
`define STAGE_EX
`endif
`endif
`ifdef STAGE_EX
`ifndef STAGE_ID
`define STAGE_ID
`endif
`endif

// Arreglo del banco de registros dentro del core (carga del estado inicial
// y lectura del estado final). I-27 lo ajusta si el camino es otro.
`ifndef REGFILE
`define REGFILE u_dut.u_regfile.regs
`endif

module pipeline_tb;

    localparam integer T_CLK      = 10;         // ns, 100 MHz como la Basys 3
    localparam integer NB_DATA    = 32;
    localparam integer NB_ADDR    = 10;         // IMEM_AW = DMEM_AW (memoria.md §1)
    localparam integer MEM_WORDS  = 1024;
    localparam integer N_REGS     = 32;

    parameter  integer MAX_CYCLES = 2000;       // watchdog: ciclos con enable = 1
    localparam integer MAX_LINES  = MAX_CYCLES + 2;

    // Anchos de los latches (pipeline.md §8)
    localparam integer NB_IF_ID   = 65;
    localparam integer NB_ID_EX   = 161;
    localparam integer NB_EX_MEM  = 109;
    localparam integer NB_MEM_WB  = 110;
    localparam integer NB_LATCH   = 161;        // el más ancho, para la comparación

    localparam integer L_IF_ID    = 0;
    localparam integer L_ID_EX    = 1;
    localparam integer L_EX_MEM   = 2;
    localparam integer L_MEM_WB   = 3;

    // Posiciones de corte.hex (scripts/prep_tb.py, CORTE)
    localparam integer C_LINEAS   = 0;
    localparam integer C_HALT     = 1;          // 1..4: HALT en cada latch
    localparam integer C_REDIRECT = 5;

    // Posiciones de exp_misc.hex
    localparam integer E_HALTED   = 0;
    localparam integer E_VACIO    = 1;
    localparam integer E_AVISOS   = 2;
    localparam integer E_CICLOS   = 3;

    //------------------------------------------------------------------
    // DUT
    //------------------------------------------------------------------
    reg                tb_clk;
    reg                tb_rst;
    reg                tb_enable;
    reg                tb_imem_b_en;
    reg                tb_imem_b_we;
    reg  [NB_ADDR-1:0] tb_imem_b_addr;
    reg  [NB_DATA-1:0] tb_imem_b_din;
    wire               tb_o_halted;
`ifdef STAGE_MEM
    reg                tb_dmem_b_en;
    reg  [3:0]         tb_dmem_b_we;
    reg  [NB_ADDR-1:0] tb_dmem_b_addr;
    reg  [NB_DATA-1:0] tb_dmem_b_din;
    wire [NB_DATA-1:0] tb_o_dmem_b_dout;
`endif
`ifdef STAGE_WB
    wire               tb_o_imem_fault;
    wire               tb_o_dmem_oob;
    wire               tb_o_dmem_misaligned;
`endif

    riscv_core u_dut (
        .i_clk             (tb_clk),
        .i_rst             (tb_rst),
        .i_enable          (tb_enable),
        .i_imem_b_en       (tb_imem_b_en),
        .i_imem_b_we       (tb_imem_b_we),
        .i_imem_b_addr     (tb_imem_b_addr),
        .i_imem_b_din      (tb_imem_b_din),
`ifdef STAGE_MEM
        .i_dmem_b_en       (tb_dmem_b_en),
        .i_dmem_b_we       (tb_dmem_b_we),
        .i_dmem_b_addr     (tb_dmem_b_addr),
        .i_dmem_b_din      (tb_dmem_b_din),
        .o_dmem_b_dout     (tb_o_dmem_b_dout),
`endif
`ifdef STAGE_WB
        .o_imem_fault      (tb_o_imem_fault),
        .o_dmem_oob        (tb_o_dmem_oob),
        .o_dmem_misaligned (tb_o_dmem_misaligned),
`endif
        .o_halted          (tb_o_halted)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Latches del DUT, concatenados en el orden de pipeline.md §8
    //------------------------------------------------------------------
`ifdef STAGE_IF
    wire [NB_IF_ID-1:0] dut_if_id = {
        u_dut.if_id_valid, u_dut.if_id_pc, u_dut.if_id_instr
    };
`endif
`ifdef STAGE_ID
    wire [NB_ID_EX-1:0] dut_id_ex = {
        u_dut.id_ex_valid, u_dut.id_ex_pc, u_dut.id_ex_rs1_data, u_dut.id_ex_rs2_data,
        u_dut.id_ex_imm, u_dut.id_ex_rs1, u_dut.id_ex_rs2, u_dut.id_ex_rd,
        u_dut.id_ex_funct3, u_dut.id_ex_alu_ctrl, u_dut.id_ex_alu_src_a,
        u_dut.id_ex_alu_src_b, u_dut.id_ex_branch, u_dut.id_ex_jal, u_dut.id_ex_jalr,
        u_dut.id_ex_mem_read, u_dut.id_ex_mem_write, u_dut.id_ex_reg_write,
        u_dut.id_ex_mem_to_reg, u_dut.id_ex_halt
    };
`endif
`ifdef STAGE_EX
    wire [NB_EX_MEM-1:0] dut_ex_mem = {
        u_dut.ex_mem_valid, u_dut.ex_mem_pc, u_dut.ex_mem_result, u_dut.ex_mem_store_data,
        u_dut.ex_mem_rd, u_dut.ex_mem_funct3, u_dut.ex_mem_mem_write,
        u_dut.ex_mem_reg_write, u_dut.ex_mem_mem_to_reg, u_dut.ex_mem_halt
    };
`endif
`ifdef STAGE_MEM
    wire [NB_MEM_WB-1:0] dut_mem_wb = {
        u_dut.mem_wb_valid, u_dut.mem_wb_pc, u_dut.mem_wb_result, u_dut.mem_wb_read_data,
        u_dut.mem_wb_rd, u_dut.mem_wb_funct3, u_dut.mem_wb_offset,
        u_dut.mem_wb_reg_write, u_dut.mem_wb_mem_to_reg, u_dut.mem_wb_halt
    };
`endif

    //------------------------------------------------------------------
    // Archivos de prep_tb.py
    //------------------------------------------------------------------
    reg [NB_IF_ID-1:0]  ref_if_id       [0:MAX_LINES-1];
    reg [NB_IF_ID-1:0]  ref_if_id_mask  [0:MAX_LINES-1];
    reg [NB_ID_EX-1:0]  ref_id_ex       [0:MAX_LINES-1];
    reg [NB_ID_EX-1:0]  ref_id_ex_mask  [0:MAX_LINES-1];
    reg [NB_EX_MEM-1:0] ref_ex_mem      [0:MAX_LINES-1];
    reg [NB_EX_MEM-1:0] ref_ex_mem_mask [0:MAX_LINES-1];
    reg [NB_MEM_WB-1:0] ref_mem_wb      [0:MAX_LINES-1];
    reg [NB_MEM_WB-1:0] ref_mem_wb_mask [0:MAX_LINES-1];

    reg [NB_DATA-1:0]   imem_words [0:MEM_WORDS-1];
    reg [NB_DATA-1:0]   dmem_init  [0:MEM_WORDS-1];
    reg [NB_DATA-1:0]   regs_init  [0:N_REGS-1];
    reg [NB_DATA-1:0]   corte      [0:5];
    reg [NB_DATA-1:0]   exp_regs   [0:N_REGS-1];
    reg [NB_DATA-1:0]   exp_dmem   [0:MEM_WORDS-1];
    reg [NB_DATA-1:0]   exp_misc   [0:3];

    reg [8*512-1:0] dir;
    reg [8*600-1:0] fname;

    integer errors;
    integer checks;
    integer i;
    integer lineas;
    integer ciclo;
    integer ultimo;
    integer lim [0:3];
    integer ciclos_run;
    reg     final_mode;
    reg     fallo;

    //------------------------------------------------------------------
    // Campos de cada latch, para informar cuál falló (pipeline.md §8)
    //------------------------------------------------------------------
    function integer n_campos;
        input integer l;
        begin
            case (l)
                L_IF_ID:  n_campos = 3;
                L_ID_EX:  n_campos = 20;
                default:  n_campos = 10;
            endcase
        end
    endfunction

    function integer ancho_latch;
        input integer l;
        begin
            case (l)
                L_IF_ID:  ancho_latch = NB_IF_ID;
                L_ID_EX:  ancho_latch = NB_ID_EX;
                L_EX_MEM: ancho_latch = NB_EX_MEM;
                default:  ancho_latch = NB_MEM_WB;
            endcase
        end
    endfunction

    function [8*8-1:0] nombre_latch;
        input integer l;
        begin
            case (l)
                L_IF_ID:  nombre_latch = "if_id";
                L_ID_EX:  nombre_latch = "id_ex";
                L_EX_MEM: nombre_latch = "ex_mem";
                default:  nombre_latch = "mem_wb";
            endcase
        end
    endfunction

    // Ancho del campo c del latch l (del bit más alto al más bajo)
    function integer ancho_campo;
        input integer l;
        input integer c;
        begin
            case (l)
                L_IF_ID: ancho_campo = (c == 0) ? 1 : 32;
                L_ID_EX:
                    case (c)
                        0:                ancho_campo = 1;      // valid
                        1, 2, 3, 4:       ancho_campo = 32;     // pc, rs1_data, rs2_data, imm
                        5, 6, 7:          ancho_campo = 5;      // rs1, rs2, rd
                        8:                ancho_campo = 3;      // funct3
                        9:                ancho_campo = 4;      // alu_ctrl
                        default:          ancho_campo = 1;      // control de 1 bit
                    endcase
                L_EX_MEM:
                    case (c)
                        1, 2, 3:          ancho_campo = 32;     // pc, result, store_data
                        4:                ancho_campo = 5;      // rd
                        5:                ancho_campo = 3;      // funct3
                        default:          ancho_campo = 1;
                    endcase
                default:
                    case (c)
                        1, 2, 3:          ancho_campo = 32;     // pc, result, read_data
                        4:                ancho_campo = 5;      // rd
                        5:                ancho_campo = 3;      // funct3
                        6:                ancho_campo = 2;      // offset
                        default:          ancho_campo = 1;
                    endcase
            endcase
        end
    endfunction

    function [8*12-1:0] nombre_campo;
        input integer l;
        input integer c;
        begin
            case (l)
                L_IF_ID:
                    case (c)
                        0:       nombre_campo = "valid";
                        1:       nombre_campo = "pc";
                        default: nombre_campo = "instr";
                    endcase
                L_ID_EX:
                    case (c)
                        0:       nombre_campo = "valid";
                        1:       nombre_campo = "pc";
                        2:       nombre_campo = "rs1_data";
                        3:       nombre_campo = "rs2_data";
                        4:       nombre_campo = "imm";
                        5:       nombre_campo = "rs1";
                        6:       nombre_campo = "rs2";
                        7:       nombre_campo = "rd";
                        8:       nombre_campo = "funct3";
                        9:       nombre_campo = "alu_ctrl";
                        10:      nombre_campo = "alu_src_a";
                        11:      nombre_campo = "alu_src_b";
                        12:      nombre_campo = "branch";
                        13:      nombre_campo = "jal";
                        14:      nombre_campo = "jalr";
                        15:      nombre_campo = "mem_read";
                        16:      nombre_campo = "mem_write";
                        17:      nombre_campo = "reg_write";
                        18:      nombre_campo = "mem_to_reg";
                        default: nombre_campo = "halt";
                    endcase
                L_EX_MEM:
                    case (c)
                        0:       nombre_campo = "valid";
                        1:       nombre_campo = "pc";
                        2:       nombre_campo = "result";
                        3:       nombre_campo = "store_data";
                        4:       nombre_campo = "rd";
                        5:       nombre_campo = "funct3";
                        6:       nombre_campo = "mem_write";
                        7:       nombre_campo = "reg_write";
                        8:       nombre_campo = "mem_to_reg";
                        default: nombre_campo = "halt";
                    endcase
                default:
                    case (c)
                        0:       nombre_campo = "valid";
                        1:       nombre_campo = "pc";
                        2:       nombre_campo = "result";
                        3:       nombre_campo = "read_data";
                        4:       nombre_campo = "rd";
                        5:       nombre_campo = "funct3";
                        6:       nombre_campo = "offset";
                        7:       nombre_campo = "reg_write";
                        8:       nombre_campo = "mem_to_reg";
                        default: nombre_campo = "halt";
                    endcase
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // Chequeo con etiqueta (plantilla de decisión 010)
    //------------------------------------------------------------------
    task chk;
        input [8*32-1:0]    name;
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

    // Compara un latch en un ciclo. Si difiere, informa cada campo distinto.
    task chk_latch;
        input integer        l;
        input [NB_LATCH-1:0] dut;
        input [NB_LATCH-1:0] esperado;
        input [NB_LATCH-1:0] mask;
        reg   [NB_LATCH-1:0] diff;
        reg   [NB_LATCH-1:0] m;
        integer c;
        integer pos;
        integer w;
        begin
            checks = checks + 1;
            diff   = (dut ^ esperado) & mask;
            if (diff !== {NB_LATCH{1'b0}}) begin
                fallo = 1'b1;
                pos   = ancho_latch(l);
                for (c = 0; c < n_campos(l); c = c + 1) begin
                    w   = ancho_campo(l, c);
                    pos = pos - w;
                    m   = ({{(NB_LATCH-1){1'b0}}, 1'b1} << w) - 1'b1;
                    if (((diff >> pos) & m) !== {NB_LATCH{1'b0}}) begin
                        errors = errors + 1;
                        $display("[%0t] ERROR ciclo %0d %0s.%0s | dut=0x%0h esperado=0x%0h",
                                 $time, ciclo, nombre_latch(l), nombre_campo(l, c),
                                 (dut >> pos) & m, (esperado >> pos) & m);
                    end
                end
            end
        end
    endtask

    //------------------------------------------------------------------
    // Lectura de archivos
    //------------------------------------------------------------------
    task leer;
        input [8*40-1:0] nombre;
        output [8*600-1:0] ruta;
        begin
            $sformat(ruta, "%0s/%0s", dir, nombre);
        end
    endtask

    task terminar_mal;
        input [8*80-1:0] motivo;
        begin
            $display("TEST FAILED: %0s", motivo);
            $finish;
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors         = 0;
        checks         = 0;
        fallo          = 1'b0;
        ciclos_run     = 0;
        tb_rst         = 1'b1;
        tb_enable      = 1'b0;
        tb_imem_b_en   = 1'b0;
        tb_imem_b_we   = 1'b0;
        tb_imem_b_addr = {NB_ADDR{1'b0}};
        tb_imem_b_din  = {NB_DATA{1'b0}};
`ifdef STAGE_MEM
        tb_dmem_b_en   = 1'b0;
        tb_dmem_b_we   = 4'b0000;
        tb_dmem_b_addr = {NB_ADDR{1'b0}};
        tb_dmem_b_din  = {NB_DATA{1'b0}};
`endif

        if (!$value$plusargs("DIR=%s", dir))
            terminar_mal("falta +DIR=<directorio de scripts/prep_tb.py>");
        final_mode = $test$plusargs("FINAL");
`ifndef STAGE_WB
        if (final_mode)
            terminar_mal("+FINAL necesita STAGE_WB");
`endif

        // corte.hex primero: dice cuántas líneas tiene la traza
        for (i = 0; i < 6; i = i + 1) corte[i] = 0;
        leer("corte.hex", fname);
        $readmemh(fname, corte);
        lineas = corte[C_LINEAS];
        if (lineas == 0)
            terminar_mal("no se pudo leer corte.hex (¿corriste prep_tb.py?)");
        if (lineas > MAX_LINES)
            terminar_mal("la traza es más larga que MAX_CYCLES");

        leer("modelo.ciclo.if_id.hex",       fname); $readmemh(fname, ref_if_id,       0, lineas-1);
        leer("modelo.ciclo.if_id.mask.hex",  fname); $readmemh(fname, ref_if_id_mask,  0, lineas-1);
        leer("modelo.ciclo.id_ex.hex",       fname); $readmemh(fname, ref_id_ex,       0, lineas-1);
        leer("modelo.ciclo.id_ex.mask.hex",  fname); $readmemh(fname, ref_id_ex_mask,  0, lineas-1);
        leer("modelo.ciclo.ex_mem.hex",      fname); $readmemh(fname, ref_ex_mem,      0, lineas-1);
        leer("modelo.ciclo.ex_mem.mask.hex", fname); $readmemh(fname, ref_ex_mem_mask, 0, lineas-1);
        leer("modelo.ciclo.mem_wb.hex",      fname); $readmemh(fname, ref_mem_wb,      0, lineas-1);
        leer("modelo.ciclo.mem_wb.mask.hex", fname); $readmemh(fname, ref_mem_wb_mask, 0, lineas-1);
        leer("imem.hex",      fname); $readmemh(fname, imem_words);
        leer("dmem_init.hex", fname); $readmemh(fname, dmem_init);
        leer("regs_init.hex", fname); $readmemh(fname, regs_init);
        if (final_mode) begin
            for (i = 0; i < 4; i = i + 1) exp_misc[i] = 0;
            leer("exp_regs.hex", fname); $readmemh(fname, exp_regs);
            leer("exp_dmem.hex", fname); $readmemh(fname, exp_dmem);
            leer("exp_misc.hex", fname); $readmemh(fname, exp_misc);
            if (exp_misc[E_CICLOS] == 0)
                terminar_mal("no se pudo leer exp_misc.hex (¿el programa tiene .exp?)");
        end

        // Hasta qué ciclo se compara cada latch (ver encabezado)
        for (i = 0; i < 4; i = i + 1) begin
            lim[i] = lineas;
`ifndef STAGE_HALT
            if (corte[C_HALT + i] != 0)
                lim[i] = corte[C_HALT + i];
`endif
`ifndef STAGE_REDIRECT
            if (corte[C_REDIRECT] != 0 && corte[C_REDIRECT] + 1 + i < lim[i]) begin
                lim[i] = corte[C_REDIRECT] + 1 + i;
                $display("INFO: %0s se compara hasta el ciclo %0d: salto tomado en EX en el ciclo %0d sin STAGE_REDIRECT",
                         nombre_latch(i), lim[i], corte[C_REDIRECT]);
            end
`endif
        end
        ultimo = 0;
`ifdef STAGE_IF
        if (lim[L_IF_ID]  > ultimo) ultimo = lim[L_IF_ID];
`endif
`ifdef STAGE_ID
        if (lim[L_ID_EX]  > ultimo) ultimo = lim[L_ID_EX];
`endif
`ifdef STAGE_EX
        if (lim[L_EX_MEM] > ultimo) ultimo = lim[L_EX_MEM];
`endif
`ifdef STAGE_MEM
        if (lim[L_MEM_WB] > ultimo) ultimo = lim[L_MEM_WB];
`endif
        $display("INFO: %0s, %0d líneas de traza, se comparan los ciclos 1 a %0d",
                 dir, lineas, ultimo);

        // Carga con el core en reset, como LOAD (memoria.md §3.5 y §4)
        repeat (2) @(negedge tb_clk);
        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            tb_imem_b_en   = 1'b1;
            tb_imem_b_we   = 1'b1;
            tb_imem_b_addr = i[NB_ADDR-1:0];
            tb_imem_b_din  = imem_words[i];
            @(negedge tb_clk);
        end
        tb_imem_b_en = 1'b0;
        tb_imem_b_we = 1'b0;
`ifdef STAGE_MEM
        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            tb_dmem_b_en   = 1'b1;
            tb_dmem_b_we   = 4'b1111;
            tb_dmem_b_addr = i[NB_ADDR-1:0];
            tb_dmem_b_din  = dmem_init[i];
            @(negedge tb_clk);
        end
        tb_dmem_b_en = 1'b0;
        tb_dmem_b_we = 4'b0000;
`endif
        @(negedge tb_clk);

        // Ciclo 1: latches en burbuja por el reset, PC = 0
        tb_rst    = 1'b0;
`ifdef STAGE_ID
        // El reset pone el banco en cero (decisión 007): se carga por jerarquía
        // después de soltarlo, antes del primer flanco
        for (i = 1; i < N_REGS; i = i + 1)
            `REGFILE[i] = regs_init[i];
`endif
        tb_enable = 1'b1;
        ciclo     = 1;
        while (ciclo <= ultimo && !fallo) begin
`ifdef STAGE_IF
            if (ciclo <= lim[L_IF_ID])
                chk_latch(L_IF_ID,  dut_if_id,  ref_if_id[ciclo-1],  ref_if_id_mask[ciclo-1]);
`endif
`ifdef STAGE_ID
            if (ciclo <= lim[L_ID_EX])
                chk_latch(L_ID_EX,  dut_id_ex,  ref_id_ex[ciclo-1],  ref_id_ex_mask[ciclo-1]);
`endif
`ifdef STAGE_EX
            if (ciclo <= lim[L_EX_MEM])
                chk_latch(L_EX_MEM, dut_ex_mem, ref_ex_mem[ciclo-1], ref_ex_mem_mask[ciclo-1]);
`endif
`ifdef STAGE_MEM
            if (ciclo <= lim[L_MEM_WB])
                chk_latch(L_MEM_WB, dut_mem_wb, ref_mem_wb[ciclo-1], ref_mem_wb_mask[ciclo-1]);
`endif
            if (ciclo < ultimo && !fallo)
                @(negedge tb_clk);
            ciclo = ciclo + 1;
        end

`ifdef STAGE_WB
        // Estado final contra el .exp (verificacion.md §5)
        if (final_mode && !fallo) begin
            while (!tb_o_halted)
                @(negedge tb_clk);
            // primer ciclo con halted = 1: el pipeline tiene que estar vacío
            tb_enable = 1'b0;
            chk("halted", {{(NB_DATA-1){1'b0}}, tb_o_halted}, exp_misc[E_HALTED]);
            chk("pipeline_vacio",
                {{(NB_DATA-1){1'b0}}, ~(u_dut.if_id_valid | u_dut.id_ex_valid |
                                         u_dut.ex_mem_valid | u_dut.mem_wb_valid)},
                exp_misc[E_VACIO]);
            chk("avisos {imem_fault, dmem_oob, dmem_misaligned}",
                {{(NB_DATA-3){1'b0}}, tb_o_imem_fault, tb_o_dmem_oob, tb_o_dmem_misaligned},
                exp_misc[E_AVISOS]);
            chk("ciclos", ciclos_run, exp_misc[E_CICLOS]);
            for (i = 1; i < N_REGS; i = i + 1) begin
                $sformat(fname, "x%0d", i);
                chk(fname[8*32-1:0], `REGFILE[i], exp_regs[i]);
            end
            // dmem por el puerto B, como READ_DMEM (un ciclo de latencia)
            tb_dmem_b_en   = 1'b1;
            tb_dmem_b_we   = 4'b0000;
            tb_dmem_b_addr = {NB_ADDR{1'b0}};
            for (i = 0; i < MEM_WORDS; i = i + 1) begin
                @(negedge tb_clk);
                $sformat(fname, "dmem 0x%03h", 4 * i);
                chk(fname[8*32-1:0], tb_o_dmem_b_dout, exp_dmem[i]);
                tb_dmem_b_addr = i + 1;
            end
            tb_dmem_b_en = 1'b0;
        end
`endif

        if (errors == 0)
            $display("TEST PASSED: %0d chequeos, 0 errores", checks);
        else
            $display("TEST FAILED: %0d errores sobre %0d chequeos", errors, checks);
        $finish;
    end

    // Ciclos con enable = 1 hasta el HALT en WB inclusive (verificacion.md §5)
    always @(posedge tb_clk)
        if (!tb_rst && tb_enable && !tb_o_halted)
            ciclos_run <= ciclos_run + 1;

    // Watchdog: cuenta solo los ciclos con el core andando, no la carga ni la lectura
    initial begin : watchdog
        integer n;
        n = 0;
        while (n < MAX_CYCLES) begin
            @(posedge tb_clk);
            if (!tb_rst && tb_enable)
                n = n + 1;
        end
        $display("TEST FAILED: timeout de %0d ciclos", MAX_CYCLES);
        $finish;
    end

endmodule

`default_nettype wire
