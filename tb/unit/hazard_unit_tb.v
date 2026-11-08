`timescale 1ns / 1ps

//======================================================================
// hazard_unit_tb
//
// Testbench autoverificante de hazard_unit (docs/spec/verificacion.md
// §3.2, pipeline.md §10.3 y §10.4, decisión 011). Cubre el detector de
// carga-uso (I-41) y los enables y el flush (I-42).
//
// Oráculo, escrito aparte del RTL:
//   - Carga-uso: la instrucción en ID tiene que esperar si alguno de los
//     dos registros que nombra (los campos rs1 y rs2, sin decodificar) es
//     el que carga el load en EX, porque ese valor recién existe en WB. Un
//     load a x0 no deja ningún valor, una instrucción que no es load no se
//     espera y una burbuja en ID no lee registros.
//   - Enables y flush: la tabla de pipeline.md §10.4, fila por fila, dice
//     qué hace cada registro en cada situación: retiene, carga o carga una
//     burbuja. La situación se elige por prioridad: core detenido
//     (enable = 0), salto tomado (gana sobre el stall, §3.3), stall por
//     carga-uso, HALT en vuelo (§3.4) y normal. Lo que hace cada registro
//     con las salidas del DUT sale de la prioridad rst > en > flush de §2:
//     en = 0 retiene aunque flush = 1. Así el oráculo no repite las
//     ecuaciones del RTL, sino el efecto sobre el pipeline.
//
// Casos:
//   - Dirigidos de carga-uso con palabras reales de los programas de sw/
//     (ensambladas con rvasm), de las que el testbench saca rs1 = [19:15]
//     y rs2 = [24:20]: uso en rs1, en rs2 y en los dos; sw que guarda el
//     dato y beq que lo compara (frenan, decisión 011); rd = x0,
//     mem_read = 0 e if_id_valid = 0 no frenan; instrucción que no
//     depende del load. Falsos positivos conocidos, que frenan y es
//     correcto: HALT (rs2 = 1) tras un load a x1, lui y jal con el número
//     de registro en el inmediato, y addi con el inmediato en el campo rs2
//   - Dirigidos de enables y flush, con las 10 salidas escritas a mano:
//     cada fila de la tabla de §10.4 (normal, stall, salto tomado, HALT en
//     vuelo, core detenido); en gana sobre flush con un stall y el HALT en
//     ID (halt_stall); stall y salto a la vez (gana el salto, stall = 0);
//     HALT en el camino equivocado de un salto (redirect y stop_fetch);
//     core detenido en medio de un stall y con un salto en EX
//   - Exhaustivo: todas las combinaciones de enable, redirect, stop_fetch,
//     if_id_valid, id_ex_mem_read, id_ex_rd, if_id_rs1 e if_id_rs2
//     (2^3 * 2 * 2 * 32^3 = 1048576 vectores)
// No usa números aleatorios: el barrido recorre todo el espacio.
//======================================================================

module hazard_unit_tb;

    localparam integer NB_ADDR  = 5;
    localparam integer NB_INSTR = 32;
    localparam integer N_REGS   = 1 << NB_ADDR;
    localparam integer T_STEP   = 1;            // ns entre vectores
    localparam integer MAX_TIME = 2000000;      // ns, watchdog (barrido: ~1.05e6 ns)

    // Qué hace un registro en el flanco (pipeline.md §2 y §10.4)
    localparam [1:0] RETIENE = 2'd0;
    localparam [1:0] CARGA   = 2'd1;
    localparam [1:0] BURBUJA = 2'd2;

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

    reg                tb_enable;
    reg                tb_redirect;
    reg                tb_stop_fetch;
    reg                tb_if_id_valid;
    reg  [NB_ADDR-1:0] tb_if_id_rs1;
    reg  [NB_ADDR-1:0] tb_if_id_rs2;
    reg                tb_id_ex_mem_read;
    reg  [NB_ADDR-1:0] tb_id_ex_rd;
    wire               tb_o_load_use;
    wire               tb_o_stall;
    wire               tb_o_en_pc;
    wire               tb_o_en_if_id;
    wire               tb_o_en_id_ex;
    wire               tb_o_en_ex_mem;
    wire               tb_o_en_mem_wb;
    wire               tb_o_flush_if_id;
    wire               tb_o_flush_id_ex;
    wire               tb_o_flush_ex_mem;
    wire               tb_o_flush_mem_wb;

    // Las 10 salidas de control en un vector, en el orden de los puertos:
    // {stall, en_pc, en_if_id, en_id_ex, en_ex_mem, en_mem_wb,
    //  flush_if_id, flush_id_ex, flush_ex_mem, flush_mem_wb}
    wire [9:0] tb_o_ctrl = {tb_o_stall, tb_o_en_pc, tb_o_en_if_id, tb_o_en_id_ex,
                            tb_o_en_ex_mem, tb_o_en_mem_wb, tb_o_flush_if_id,
                            tb_o_flush_id_ex, tb_o_flush_ex_mem, tb_o_flush_mem_wb};

    integer errors;
    integer checks;
    integer ctl;
    integer vm;
    integer rd;
    integer r1;
    integer r2;

    hazard_unit #(
        .NB_ADDR (NB_ADDR)
    ) u_dut (
        .i_enable         (tb_enable),
        .i_redirect       (tb_redirect),
        .i_stop_fetch     (tb_stop_fetch),
        .i_if_id_valid    (tb_if_id_valid),
        .i_if_id_rs1      (tb_if_id_rs1),
        .i_if_id_rs2      (tb_if_id_rs2),
        .i_id_ex_mem_read (tb_id_ex_mem_read),
        .i_id_ex_rd       (tb_id_ex_rd),
        .o_load_use       (tb_o_load_use),
        .o_stall          (tb_o_stall),
        .o_en_pc          (tb_o_en_pc),
        .o_en_if_id       (tb_o_en_if_id),
        .o_en_id_ex       (tb_o_en_id_ex),
        .o_en_ex_mem      (tb_o_en_ex_mem),
        .o_en_mem_wb      (tb_o_en_mem_wb),
        .o_flush_if_id    (tb_o_flush_if_id),
        .o_flush_id_ex    (tb_o_flush_id_ex),
        .o_flush_ex_mem   (tb_o_flush_ex_mem),
        .o_flush_mem_wb   (tb_o_flush_mem_wb)
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
    // Qué hace un registro con las entradas que recibe (pipeline.md §2):
    // en = 0 retiene aunque flush = 1
    //------------------------------------------------------------------
    function [1:0] accion;
        input en;
        input flush;
        begin
            if (!en)
                accion = RETIENE;
            else if (flush)
                accion = BURBUJA;
            else
                accion = CARGA;
        end
    endfunction

    //------------------------------------------------------------------
    // Tabla de pipeline.md §10.4: qué hace cada registro en la situación
    // del ciclo. Devuelve {en_pc, IF/ID, ID/EX, EX/MEM, MEM/WB}: en_pc en
    // 1 bit (el mux de §3.1 decide el valor nuevo del PC) y una acción de
    // 2 bits por registro de segmentación
    //------------------------------------------------------------------
    function [8:0] tabla;
        input enable;
        input salto;           // redirect: beq/bne tomado, jal o jalr en EX
        input halt_en_vuelo;   // stop_fetch
        input dato_falta;      // la instrucción en ID espera al load en EX
        begin
            if (!enable)                                    // core detenido
                tabla = {1'b0, RETIENE, RETIENE, RETIENE, RETIENE};
            else if (salto)                                 // gana sobre el stall (§3.3)
                tabla = {1'b1, BURBUJA, BURBUJA, CARGA, CARGA};
            else if (dato_falta)                            // stall por load-use
                tabla = {1'b0, RETIENE, BURBUJA, CARGA, CARGA};
            else if (halt_en_vuelo)                         // el PC lo retiene el mux de §3.1
                tabla = {1'b1, BURBUJA, CARGA, CARGA, CARGA};
            else                                            // normal
                tabla = {1'b1, CARGA, CARGA, CARGA, CARGA};
        end
    endfunction

    // Compara un valor contra el esperado (máximo 20 líneas de error)
    task chk;
        input [8*56-1:0] name;
        input [8*20-1:0] campo;
        input [9:0]      dut;
        input [9:0]      exp;
        begin
            checks = checks + 1;
            if (dut !== exp) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("[%0t] ERROR %0s %0s | en=%b redirect=%b stop_fetch=%b valid=%b rs1=%0d rs2=%0d mem_read=%b rd=%0d dut=%b esperado=%b",
                             $time, name, campo, tb_enable, tb_redirect, tb_stop_fetch, tb_if_id_valid,
                             tb_if_id_rs1, tb_if_id_rs2, tb_id_ex_mem_read, tb_id_ex_rd, dut, exp);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Aplica un vector y compara las salidas contra el oráculo
    //------------------------------------------------------------------
    task vec;
        input [8*56-1:0]    name;
        input               enable;
        input               redirect;
        input               stop_fetch;
        input               valid;
        input [NB_ADDR-1:0] rs1;
        input [NB_ADDR-1:0] rs2;
        input               mem_read;
        input [NB_ADDR-1:0] load_rd;
        reg                 exp_load_use;
        reg   [8:0]         exp_tabla;
        begin
            tb_enable         = enable;
            tb_redirect       = redirect;
            tb_stop_fetch     = stop_fetch;
            tb_if_id_valid    = valid;
            tb_if_id_rs1      = rs1;
            tb_if_id_rs2      = rs2;
            tb_id_ex_mem_read = mem_read;
            tb_id_ex_rd       = load_rd;

            exp_load_use = espera(valid, rs1, rs2, mem_read, load_rd);
            exp_tabla    = tabla(enable, redirect, stop_fetch, exp_load_use);

            #(T_STEP);
            chk(name, "load_use", tb_o_load_use, exp_load_use);
            // stall: la instrucción espera y no hay un salto que la descarte
            chk(name, "stall",    tb_o_stall,    exp_load_use & ~redirect);
            chk(name, "en_pc",    tb_o_en_pc,    exp_tabla[8]);
            chk(name, "IF/ID",    accion(tb_o_en_if_id,  tb_o_flush_if_id),  exp_tabla[7:6]);
            chk(name, "ID/EX",    accion(tb_o_en_id_ex,  tb_o_flush_id_ex),  exp_tabla[5:4]);
            chk(name, "EX/MEM",   accion(tb_o_en_ex_mem, tb_o_flush_ex_mem), exp_tabla[3:2]);
            chk(name, "MEM/WB",   accion(tb_o_en_mem_wb, tb_o_flush_mem_wb), exp_tabla[1:0]);
        end
    endtask

    // Carga-uso dirigido: una palabra real en ID, con el core andando y sin
    // salto ni HALT, y load_use esperado escrito a mano (además del oráculo)
    task instr;
        input [8*56-1:0]     name;
        input [NB_INSTR-1:0] word;
        input                valid;
        input                mem_read;
        input [NB_ADDR-1:0]  load_rd;
        input                exp_manual;
        begin
            vec(name, 1'b1, 1'b0, 1'b0, valid, word[19:15], word[24:20], mem_read, load_rd);
            chk(name, "load_use (a mano)", tb_o_load_use, exp_manual);
        end
    endtask

    // Enables y flush dirigido: una palabra real en ID con el load en EX, y
    // las 10 salidas escritas a mano en el orden de tb_o_ctrl (además del
    // oráculo)
    task fila;
        input [8*56-1:0]     name;
        input                enable;
        input                redirect;
        input                stop_fetch;
        input [NB_INSTR-1:0] word;
        input                mem_read;
        input [NB_ADDR-1:0]  load_rd;
        input [9:0]          exp_manual;
        begin
            vec(name, enable, redirect, stop_fetch, 1'b1, word[19:15], word[24:20], mem_read, load_rd);
            chk(name, "salidas (a mano)", tb_o_ctrl, exp_manual);
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors            = 0;
        checks            = 0;
        tb_enable         = 1'b0;
        tb_redirect       = 1'b0;
        tb_stop_fetch     = 1'b0;
        tb_if_id_valid    = 1'b0;
        tb_if_id_rs1      = {NB_ADDR{1'b0}};
        tb_if_id_rs2      = {NB_ADDR{1'b0}};
        tb_id_ex_mem_read = 1'b0;
        tb_id_ex_rd       = {NB_ADDR{1'b0}};

        // Carga-uso (orden: palabra en ID, valid, mem_read, rd del load, esperado)
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
        vec("x31 en rs1 y en rs2", 1'b1, 1'b0, 1'b0,    1'b1, 5'd31, 5'd31, 1'b1, 5'd31);

        // Enables y flush (orden: enable, redirect, stop_fetch, palabra en
        // ID, mem_read y rd de EX, y a mano {stall, en_pc, en_if_id,
        // en_id_ex, en_ex_mem, en_mem_wb, flush_if_id, flush_id_ex,
        // flush_ex_mem, flush_mem_wb}). Las filas de la tabla de §10.4:
        fila("tabla 10.4: normal (lw x4; add x6, x5)",          1'b1, 1'b0, 1'b0, W_ADD_RS1, 1'b1, 5'd4, 10'b0_11111_0000);
        fila("tabla 10.4: stall por load-use (lw x5; add x6, x5)", 1'b1, 1'b0, 1'b0, W_ADD_RS1, 1'b1, 5'd5, 10'b1_00111_0100);
        fila("tabla 10.4: salto tomado (add en ID, sin load)",  1'b1, 1'b1, 1'b0, W_ADD_RS1, 1'b0, 5'd5, 10'b0_11111_1100);
        fila("tabla 10.4: HALT en vuelo (add en ID, sin load)", 1'b1, 1'b0, 1'b1, W_ADD_RS1, 1'b0, 5'd5, 10'b0_11111_1000);
        fila("tabla 10.4: core detenido",                       1'b0, 1'b0, 1'b0, W_ADD_RS1, 1'b0, 5'd5, 10'b0_00000_0000);
        // en gana sobre flush: lw x1 y el HALT en ID (sw/halt_stall.s).
        // stop_fetch pide flush de IF/ID, pero en_if_id = 0 lo retiene
        fila("stall con HALT en ID: en gana sobre flush", 1'b1, 1'b0, 1'b1, W_HALT,    1'b1, 5'd1, 10'b1_00111_1100);
        // stall = load_use & ~redirect: el salto descarta a la que esperaba
        fila("stall y salto a la vez: gana el salto",     1'b1, 1'b1, 1'b0, W_ADD_RS1, 1'b1, 5'd5, 10'b0_11111_1100);
        // HALT en ID detrás de un salto tomado (halt_camino_equivocado)
        fila("salto con HALT en el camino equivocado",    1'b1, 1'b1, 1'b1, W_HALT,    1'b0, 5'd1, 10'b0_11111_1100);
        // con enable = 0 nada cambia, aunque haya stall o salto (§10.4)
        fila("core detenido en medio de un stall",        1'b0, 1'b0, 1'b0, W_ADD_RS1, 1'b1, 5'd5, 10'b1_00000_0100);
        fila("core detenido con un salto en EX",          1'b0, 1'b1, 1'b0, W_ADD_RS1, 1'b0, 5'd5, 10'b0_00000_1100);
        fila("core detenido con el HALT en ID y stall",   1'b0, 1'b0, 1'b1, W_HALT,    1'b1, 5'd1, 10'b1_00000_1100);

        // Exhaustivo: ctl = {enable, redirect, stop_fetch},
        // vm = {if_id_valid, id_ex_mem_read}
        for (ctl = 0; ctl < 8; ctl = ctl + 1)
            for (vm = 0; vm < 4; vm = vm + 1)
                for (rd = 0; rd < N_REGS; rd = rd + 1)
                    for (r1 = 0; r1 < N_REGS; r1 = r1 + 1)
                        for (r2 = 0; r2 < N_REGS; r2 = r2 + 1)
                            vec("exhaustivo", ctl[2], ctl[1], ctl[0],
                                vm[1], r1[NB_ADDR-1:0], r2[NB_ADDR-1:0],
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
