`timescale 1ns / 1ps

//======================================================================
// debug_run_tb
//
// Testbench autoverificante de debug_exec, la FSM de ejecución de la Debug
// Unit: los modos continuo y paso a paso, desde tramas UART y con el core
// real (docs/spec/verificacion.md §3.3, protocolo_debug.md §3.5 y §3.7,
// decisiones 006, 018 y 037).
//
// Montaje: el testbench hace de PC y le habla a la Debug Unit por la línea
// serie:
//   PC (testbench) --serie--> uart --> debug_unit --> debug_exec --> riscv_core
//                  <--serie-- uart <-- debug_unit <-- (bloque de estado)
//   debug_exec genera enable y core_rst; el core le devuelve halted. El
//   reloj no se toca: es el mismo para todos.
//
// Mientras no estén la I-46 y la I-48 (marcados "I-46" e "I-48" abajo):
//   - El testbench hace lo que hará la carga: después de la respuesta del
//     LOAD (y del RESET), con el core detenido, escribe imem (programa y el
//     resto HALT) y pone dmem en cero por el puerto B. La trama LOAD es
//     real: debug_unit la valida y debug_exec pasa a READY.
//   - dmem_used = 0 e i_pl_byte = 0: no se mandan lecturas. Los registros
//     se leen por el puerto de debug del banco y dmem por el puerto B.
//
// Oráculo, escrito aparte del RTL:
//   - Los .exp de sw/ copiados a mano (registros, dmem, ciclos); el PC
//     final es la dirección del HALT + 4 (pipeline.md §3.4).
//   - Las tramas de protocolo_debug.md §4, byte por byte.
//   - Un segundo core (u_ref) con el mismo programa y un enable que maneja
//     el testbench: después de cada STEP avanza un ciclo y se comparan PC,
//     halted, los 32 registros y los cuatro latches (todos sus bits si
//     valid = 1; en una burbuja, solo valid, porque los datos de una
//     burbuja no se resetean). Prueba que un STEP es un ciclo en todos los
//     ciclos, también los de stall y de flush.
//   - Un monitor que cuenta los ciclos con enable = 1 y cuenta como error
//     enable = 1 con halted = 1 o con core_rst = 1.
//   - Para las prioridades dentro de un ciclo, una segunda instancia de
//     debug_exec (u_solo) manejada directo por el testbench: por la línea
//     serie no se puede elegir el ciclo.
//
// Programas (palabras de rvasm, con el ensamblador en el comentario):
//   ejemplo (§4: addi x1, x0, 5; halt), halt_basico, loaduse_rs1_rs2,
//   mixto_lazo, un lazo de 2000 vueltas con HALT (lazo_n, 8005 ciclos según
//   tools/isasim) y un lazo sin HALT (lazo_inf).
//
// Casos:
//   - Después del reset: NO_PROG con core_rst; RUN y STEP -> ERR_STATE;
//     STOP y RESET responden OK sin cambiar nada
//   - Las tramas de §4 con el core real: LOAD, RUN, confirmación y
//     EVT_HALTED (PC = 0x08, 6 ciclos); STEP y RUN en HALTED -> ERR_STATE
//     sin enable
//   - RUN: la confirmación sale antes que el EVT_HALTED; estado final, PC y
//     cycles del .exp, y enable = 1 exactamente esos ciclos
//   - STEP repetido hasta HALTED: un ciclo de enable por STEP, cycles = k,
//     PAUSED (HALTED el último, sin EVT_HALTED), lockstep con u_ref
//   - STEP en medio de un stall: algún STEP sale de un estado con
//     stall = 1 (3 en loaduse_rs1_rs2, 5 en mixto_lazo) y el lockstep sigue
//   - RUN y STEP repetido dan el mismo estado final (y el del .exp)
//   - STOP en el medio de lazo_n: PAUSED, enable baja y cycles se congela;
//     el core queda como u_ref después de los mismos ciclos; STEP sigue y
//     RUN termina con los 8005 ciclos de una corrida sin cortes
//   - STOP en NO_PROG, READY, PAUSED y HALTED: OK sin cambios
//   - RESET y LOAD en RUNNING detienen y resetean el core, sin EVT_HALTED
//   - RESET con un EVT_HALTED pendiente (el HALT llega mientras entra la
//     trama): lo descarta
//   - u_solo: prioridades de la decisión 037 (LOAD/RESET > halt > STOP),
//     el pulso de STEP, el pulso de core_rst, i_load_start, i_mem_busy,
//     i_evt_done y los comandos ignorados fuera de su estado
// Sin aleatoriedad: no hace falta semilla.
//
// DUT: CLK_FREQ_HZ = 32 × 115200 (DVSR = 2, un byte serie = 320 ciclos) y
//      RX_TIMEOUT_CYCLES = 3000, como debug_cmd_fsm_tb, para simular rápido.
//======================================================================

module debug_run_tb;

    `include "riscv_defs.vh"

    localparam integer T_CLK     = 10;            // ns
    localparam integer BAUD      = 115200;
    localparam integer F_CLK     = 32 * BAUD;     // DVSR = 2
    localparam integer TOUT      = 3000;          // ciclos
    localparam integer BYTE_CYC  = 320;           // ciclos por byte serie
    localparam real    BIT_NS    = 320.0;         // 16 ticks × 2 ciclos × 10 ns
    localparam integer MAX_TIME  = 200_000_000;   // ns, watchdog
    localparam integer RESP_WAIT = 40 * BYTE_CYC; // ciclos máximos hasta un byte

    // Programas
    localparam integer P_EJEMPLO     = 0;
    localparam integer P_HALT_BASICO = 1;
    localparam integer P_LOADUSE     = 2;
    localparam integer P_MIXTO       = 3;
    localparam integer P_LAZO_N      = 4;
    localparam integer P_LAZO_INF    = 5;

    localparam integer LAZO_N_CICLOS = 8005;      // tools/isasim

    reg         tb_clk;
    reg         tb_rst;
    reg         tb_rx;           // línea PC -> FPGA
    wire        tb_o_tx;         // línea FPGA -> PC

    // uart <-> debug_unit
    wire [7:0]  r_data;
    wire        rx_empty;
    wire        rd;
    wire [7:0]  w_data;
    wire        wr;
    wire        tx_full;

    // debug_unit <-> debug_exec
    wire        cmd_valid;
    wire [7:0]  cmd;
    wire [31:0] arg_addr;
    wire [15:0] arg_count;
    wire [15:0] pl_idx;
    wire        evt_done;
    wire [2:0]  tb_o_state;
    wire        tb_o_prog_valid;
    wire [31:0] tb_o_cycles;
    wire        tb_o_evt_pending;

    // debug_exec <-> core
    wire        tb_o_enable;
    wire        tb_o_core_rst;
    wire        halted;
    wire        imem_fault;
    wire        dmem_oob;
    wire        dmem_mis;
    wire [31:0] pc;
    wire [64:0]  if_id;
    wire [160:0] id_ex;
    wire [108:0] ex_mem;
    wire [109:0] mem_wb;

    // Puerto B de las memorias (I-46) y puerto de debug del banco (I-48),
    // los maneja el testbench; los comparten los dos cores
    reg         tb_imem_b_en;
    reg         tb_imem_b_we;
    reg  [9:0]  tb_imem_b_addr;
    reg  [31:0] tb_imem_b_din;
    reg         tb_dmem_b_en;
    reg  [3:0]  tb_dmem_b_we;
    reg  [9:0]  tb_dmem_b_addr;
    reg  [31:0] tb_dmem_b_din;
    wire [31:0] dmem_b_dout;
    reg  [4:0]  tb_dbg_reg_addr;
    wire [31:0] dbg_reg_data;

    // Core de referencia
    reg          tb_ref_rst;
    reg          tb_ref_enable;
    wire         ref_halted;
    wire         ref_imem_fault;
    wire         ref_dmem_oob;
    wire         ref_dmem_mis;
    wire [31:0]  ref_pc;
    wire [64:0]  ref_if_id;
    wire [160:0] ref_id_ex;
    wire [108:0] ref_ex_mem;
    wire [109:0] ref_mem_wb;
    wire [31:0]  ref_dmem_b_dout;
    wire [31:0]  ref_dbg_reg_data;

    uart #(
        .CLK_FREQ_HZ (F_CLK),
        .BAUD        (BAUD)
    ) u_uart (
        .i_clk      (tb_clk),
        .i_rst      (tb_rst),
        .i_rx       (tb_rx),
        .o_tx       (tb_o_tx),
        .o_r_data   (r_data),
        .o_rx_empty (rx_empty),
        .i_rd       (rd),
        .i_w_data   (w_data),
        .i_wr       (wr),
        .o_tx_full  (tx_full)
    );

    debug_unit #(
        .CLK_FREQ_HZ       (F_CLK),
        .RX_TIMEOUT_CYCLES (TOUT)
    ) u_du (
        .i_clk             (tb_clk),
        .i_rst             (tb_rst),
        .i_r_data          (r_data),
        .i_rx_empty        (rx_empty),
        .o_rd              (rd),
        .o_w_data          (w_data),
        .o_wr              (wr),
        .i_tx_full         (tx_full),
        .i_state           (tb_o_state),
        .i_prog_valid      (tb_o_prog_valid),
        .i_halted          (halted),
        .i_imem_fault      (imem_fault),
        .i_dmem_oob        (dmem_oob),
        .i_dmem_misaligned (dmem_mis),
        .i_dmem_used       (16'd0),          // I-48
        .i_pc              (pc),
        .i_cycles          (tb_o_cycles),
        .i_evt_pending     (tb_o_evt_pending),
        .o_evt_done        (evt_done),
        .o_cmd_valid       (cmd_valid),
        .o_cmd             (cmd),
        .o_arg_addr        (arg_addr),
        .o_arg_count       (arg_count),
        .o_pl_idx          (pl_idx),
        .i_pl_byte         (8'h00)           // I-48
    );

    debug_exec u_dut (
        .i_clk         (tb_clk),
        .i_rst         (tb_rst),
        .i_cmd_valid   (cmd_valid),
        .i_cmd         (cmd),
        .i_load_start  (1'b0),               // I-46
        .i_mem_busy    (1'b0),               // I-46
        .i_evt_done    (evt_done),
        .o_state       (tb_o_state),
        .o_prog_valid  (tb_o_prog_valid),
        .o_cycles      (tb_o_cycles),
        .o_evt_pending (tb_o_evt_pending),
        .i_halted      (halted),
        .o_enable      (tb_o_enable),
        .o_core_rst    (tb_o_core_rst)
    );

    riscv_core u_core (
        .i_clk             (tb_clk),
        .i_rst             (tb_o_core_rst),
        .i_enable          (tb_o_enable),
        .i_imem_b_en       (tb_imem_b_en),
        .i_imem_b_we       (tb_imem_b_we),
        .i_imem_b_addr     (tb_imem_b_addr),
        .i_imem_b_din      (tb_imem_b_din),
        .i_dmem_b_en       (tb_dmem_b_en),
        .i_dmem_b_we       (tb_dmem_b_we),
        .i_dmem_b_addr     (tb_dmem_b_addr),
        .i_dmem_b_din      (tb_dmem_b_din),
        .o_dmem_b_dout     (dmem_b_dout),
        .i_dbg_reg_addr    (tb_dbg_reg_addr),
        .o_dbg_reg_data    (dbg_reg_data),
        .o_halted          (halted),
        .o_imem_fault      (imem_fault),
        .o_dmem_oob        (dmem_oob),
        .o_dmem_misaligned (dmem_mis),
        .o_pc              (pc),
        .o_if_id_latch     (if_id),
        .o_id_ex_latch     (id_ex),
        .o_ex_mem_latch    (ex_mem),
        .o_mem_wb_latch    (mem_wb)
    );

    riscv_core u_ref (
        .i_clk             (tb_clk),
        .i_rst             (tb_ref_rst),
        .i_enable          (tb_ref_enable),
        .i_imem_b_en       (tb_imem_b_en),
        .i_imem_b_we       (tb_imem_b_we),
        .i_imem_b_addr     (tb_imem_b_addr),
        .i_imem_b_din      (tb_imem_b_din),
        .i_dmem_b_en       (tb_dmem_b_en),
        .i_dmem_b_we       (tb_dmem_b_we),
        .i_dmem_b_addr     (tb_dmem_b_addr),
        .i_dmem_b_din      (tb_dmem_b_din),
        .o_dmem_b_dout     (ref_dmem_b_dout),
        .i_dbg_reg_addr    (tb_dbg_reg_addr),
        .o_dbg_reg_data    (ref_dbg_reg_data),
        .o_halted          (ref_halted),
        .o_imem_fault      (ref_imem_fault),
        .o_dmem_oob        (ref_dmem_oob),
        .o_dmem_misaligned (ref_dmem_mis),
        .o_pc              (ref_pc),
        .o_if_id_latch     (ref_if_id),
        .o_id_ex_latch     (ref_id_ex),
        .o_ex_mem_latch    (ref_ex_mem),
        .o_mem_wb_latch    (ref_mem_wb)
    );

    // debug_exec solo, manejado directo (prioridades dentro de un ciclo)
    reg         s_rst;
    reg         s_cmd_valid;
    reg  [7:0]  s_cmd;
    reg         s_load_start;
    reg         s_mem_busy;
    reg         s_evt_done;
    reg         s_halted;
    wire [2:0]  s_o_state;
    wire        s_o_prog_valid;
    wire [31:0] s_o_cycles;
    wire        s_o_evt_pending;
    wire        s_o_enable;
    wire        s_o_core_rst;

    debug_exec u_solo (
        .i_clk         (tb_clk),
        .i_rst         (s_rst),
        .i_cmd_valid   (s_cmd_valid),
        .i_cmd         (s_cmd),
        .i_load_start  (s_load_start),
        .i_mem_busy    (s_mem_busy),
        .i_evt_done    (s_evt_done),
        .o_state       (s_o_state),
        .o_prog_valid  (s_o_prog_valid),
        .o_cycles      (s_o_cycles),
        .o_evt_pending (s_o_evt_pending),
        .i_halted      (s_halted),
        .o_enable      (s_o_enable),
        .o_core_rst    (s_o_core_rst)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    integer errors;
    integer checks;

    task chk;
        input [8*48-1:0] name;
        input [31:0]     obtenido;
        input [31:0]     esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                if (errors <= 40)
                    $display("[%0t] ERROR %0s | dut=0x%0h esperado=0x%0h",
                             $time, name, obtenido, esperado);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Monitor de enable: ciclos con enable = 1, y enable con halted o con
    // core_rst (no tiene que pasar nunca)
    //------------------------------------------------------------------
    integer n_en;
    integer n_en_halted;
    integer n_en_rst;
    reg     evt_at_cmd;      // evt_pending en el último o_cmd_valid

    initial begin
        n_en = 0;  n_en_halted = 0;  n_en_rst = 0;  evt_at_cmd = 1'b0;
    end

    always @(posedge tb_clk) begin
        if (!tb_rst) begin
            if (tb_o_enable)                  n_en        = n_en + 1;
            if (tb_o_enable && halted)        n_en_halted = n_en_halted + 1;
            if (tb_o_enable && tb_o_core_rst) n_en_rst    = n_en_rst + 1;
        end
        if (cmd_valid)
            evt_at_cmd = tb_o_evt_pending;
    end

    //------------------------------------------------------------------
    // PC: transmisor serie
    //------------------------------------------------------------------
    task serie_tx;
        input [7:0] dato;
        integer     j;
        begin
            tb_rx = 1'b0;                                   // start
            #(BIT_NS);
            for (j = 0; j < 8; j = j + 1) begin             // LSB primero
                tb_rx = dato[j];
                #(BIT_NS);
            end
            tb_rx = 1'b1;                                   // stop
            #(BIT_NS);
        end
    endtask

    //------------------------------------------------------------------
    // PC: receptor serie, siempre activo, guarda los bytes en rx_q
    //------------------------------------------------------------------
    reg [7:0] rx_q [0:16383];
    integer   rx_n;          // bytes recibidos
    integer   rx_rd;         // bytes ya leídos por el testbench
    integer   rx_bad;        // tramas serie mal formadas
    reg [7:0] rx_b;
    integer   rx_j;

    initial begin
        rx_n = 0;  rx_rd = 0;  rx_bad = 0;
        forever begin
            @(negedge tb_o_tx);
            #(BIT_NS / 2.0);
            if (tb_o_tx === 1'b0) begin
                for (rx_j = 0; rx_j < 8; rx_j = rx_j + 1) begin
                    #(BIT_NS);
                    rx_b[rx_j] = tb_o_tx;
                end
                #(BIT_NS);
                if (tb_o_tx !== 1'b1) rx_bad = rx_bad + 1;
                rx_q[rx_n] = rx_b;
                rx_n = rx_n + 1;
            end
        end
    end

    // Siguiente byte de la cola; ok = 0 si no llega en RESP_WAIT ciclos
    task leer_byte;
        output reg [7:0] dato;
        output reg       ok;
        integer          c;
        begin
            ok = 1'b0;  dato = 8'hxx;
            for (c = 0; c < RESP_WAIT && rx_rd >= rx_n; c = c + 1)
                @(negedge tb_clk);
            if (rx_rd < rx_n) begin
                dato  = rx_q[rx_rd];
                rx_rd = rx_rd + 1;
                ok    = 1'b1;
            end
        end
    endtask

    //------------------------------------------------------------------
    // Peticiones
    //------------------------------------------------------------------
    reg [7:0] pl_buf [0:4199];

    // A5, cmd, LEN, len bytes de pl_buf y el CHK correcto
    task peticion;
        input [7:0]  c_cmd;
        input [15:0] len;
        reg   [7:0]  c;
        integer      i;
        begin
            c = c_cmd ^ len[7:0] ^ len[15:8];
            serie_tx(8'hA5);
            serie_tx(c_cmd);
            serie_tx(len[7:0]);
            serie_tx(len[15:8]);
            for (i = 0; i < len; i = i + 1) begin
                serie_tx(pl_buf[i]);
                c = c ^ pl_buf[i];
            end
            serie_tx(c);
        end
    endtask

    // Petición sin payload
    task comando;
        input [7:0] c_cmd;
        begin
            peticion(c_cmd, 16'd0);
        end
    endtask

    // Envía n bytes escritos a mano; f tiene el primero en los bits altos
    task enviar_hex;
        input integer    n;
        input [8*24-1:0] f;
        integer          i;
        begin
            for (i = n - 1; i >= 0; i = i - 1)
                serie_tx(f[8*i +: 8]);
        end
    endtask

    // Espera una trama exacta de n bytes escrita a mano
    task esperar_hex;
        input [8*40-1:0] name;
        input integer    n;
        input [8*24-1:0] f;
        integer          i;
        reg   [7:0]      b;
        reg              ok;
        begin
            for (i = n - 1; i >= 0; i = i - 1) begin
                leer_byte(b, ok);
                chk(name, ok ? b : 32'hDEAD, f[8*i +: 8]);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Respuestas: encabezado esperado, payload en resp_buf y CHK calculado
    // por el testbench
    //------------------------------------------------------------------
    reg [7:0] resp_buf [0:255];
    integer   resp_len;

    task esperar_resp;
        input [8*40-1:0] name;
        input [7:0]      c_cmd;
        input [7:0]      status;
        input [15:0]     len;
        reg   [7:0]      b;
        reg   [7:0]      c;
        reg              ok;
        integer          i;
        begin
            leer_byte(b, ok);  chk({name, " SOF"},    ok ? b : 32'hDEAD, 8'h5A);
            leer_byte(b, ok);  chk({name, " CMD"},    ok ? b : 32'hDEAD, c_cmd);   c = b;
            leer_byte(b, ok);  chk({name, " STATUS"}, ok ? b : 32'hDEAD, status);  c = c ^ b;
            leer_byte(b, ok);  resp_len = b;                                       c = c ^ b;
            leer_byte(b, ok);  resp_len = resp_len | (b << 8);                     c = c ^ b;
            chk({name, " LEN"}, resp_len, len);
            if (!ok || resp_len > 256) resp_len = 0;
            for (i = 0; i < resp_len; i = i + 1) begin
                leer_byte(b, ok);
                resp_buf[i] = b;
                c = c ^ b;
            end
            leer_byte(b, ok);  chk({name, " CHK"}, ok ? b : 32'hDEAD, c);
        end
    endtask

    // Palabra little-endian del payload, desde el byte off
    function [31:0] blk_word;
        input integer off;
        begin
            blk_word = {resp_buf[off+3], resp_buf[off+2], resp_buf[off+1], resp_buf[off]};
        end
    endfunction

    // Respuesta con bloque de estado (§3.1): state, flags y dmem_used = 0
    task esperar_bloque;
        input [8*40-1:0] name;
        input [7:0]      c_cmd;
        input [2:0]      st;
        input [7:0]      flags;
        begin
            esperar_resp(name, c_cmd, DBG_OK, 16'd12);
            chk({name, " state"}, resp_buf[0], st);
            chk({name, " flags"}, resp_buf[1], flags);
            chk({name, " used"},  {resp_buf[3], resp_buf[2]}, 16'd0);
        end
    endtask

    // Lo mismo, y además pc y cycles
    task esperar_bloque_pc;
        input [8*40-1:0] name;
        input [7:0]      c_cmd;
        input [2:0]      st;
        input [7:0]      flags;
        input [31:0]     e_pc;
        input [31:0]     e_cycles;
        begin
            esperar_bloque(name, c_cmd, st, flags);
            chk({name, " pc"},     blk_word(4), e_pc);
            chk({name, " cycles"}, blk_word(8), e_cycles);
        end
    endtask

    // Sin bytes de la FPGA durante n ciclos
    task sin_respuesta;
        input [8*40-1:0] name;
        input integer    n;
        begin
            repeat (n) @(negedge tb_clk);
            chk(name, rx_n - rx_rd, 0);
        end
    endtask

    //------------------------------------------------------------------
    // Programas y estado esperado (de los .exp de sw/)
    //------------------------------------------------------------------
    reg [31:0] prog     [0:31];
    integer    prog_n;
    reg [31:0] exp_reg  [0:31];
    reg [31:0] exp_dmem [0:1023];
    reg [31:0] exp_pc;
    integer    exp_ciclos;
    integer    exp_stalls;   // ciclos con stall = 1

    task elegir;
        input integer p;
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1) begin
                prog[i]    = INSTR_HALT;
                exp_reg[i] = 32'h0;
            end
            for (i = 0; i < 1024; i = i + 1)
                exp_dmem[i] = 32'h0;
            exp_stalls = 0;
            case (p)
                P_EJEMPLO: begin                    // protocolo_debug.md §4
                    prog[0] = 32'h00500093;         // addi x1, x0, 5
                    prog[1] = 32'h00100073;         // halt
                    prog_n  = 2;
                    exp_reg[1] = 32'h5;
                    exp_pc = 32'h08;  exp_ciclos = 6;
                end
                P_HALT_BASICO: begin                // sw/halt_basico.s
                    prog[0] = 32'h00100093;         // addi x1, x0, 1
                    prog[1] = 32'h00200113;         // addi x2, x0, 2
                    prog[2] = 32'h00100073;         // halt
                    prog[3] = 32'h00300193;         // addi x3, x0, 3   (no se ejecuta)
                    prog[4] = 32'h00400213;         // addi x4, x0, 4   (no se ejecuta)
                    prog[5] = 32'h00102023;         // sw   x1, 0(x0)   (no se ejecuta)
                    prog[6] = 32'h00100073;         // halt
                    prog_n  = 7;
                    exp_reg[1] = 32'h1;  exp_reg[2] = 32'h2;
                    exp_pc = 32'h0C;  exp_ciclos = 7;
                end
                P_LOADUSE: begin                    // sw/loaduse_rs1_rs2.s
                    prog[0]  = 32'h02a00093;        // addi x1, x0, 42
                    prog[1]  = 32'hffb00113;        // addi x2, x0, -5
                    prog[2]  = 32'h00300193;        // addi x3, x0, 3
                    prog[3]  = 32'h00102423;        // sw   x1, 8(x0)
                    prog[4]  = 32'h00202623;        // sw   x2, 12(x0)
                    prog[5]  = 32'h00802283;        // lw   x5, 8(x0)
                    prog[6]  = 32'h00028333;        // add  x6, x5, x0      stall
                    prog[7]  = 32'h00c02383;        // lw   x7, 12(x0)
                    prog[8]  = 32'h40700433;        // sub  x8, x0, x7      stall
                    prog[9]  = 32'h00802483;        // lw   x9, 8(x0)
                    prog[10] = 32'h00948533;        // add  x10, x9, x9     stall
                    prog[11] = 32'h00100073;        // halt
                    prog_n   = 12;
                    exp_reg[1]  = 32'h0000002A;  exp_reg[2]  = 32'hFFFFFFFB;
                    exp_reg[3]  = 32'h00000003;  exp_reg[5]  = 32'h0000002A;
                    exp_reg[6]  = 32'h0000002A;  exp_reg[7]  = 32'hFFFFFFFB;
                    exp_reg[8]  = 32'h00000005;  exp_reg[9]  = 32'h0000002A;
                    exp_reg[10] = 32'h00000054;
                    exp_dmem[2] = 32'h0000002A;     // 0x008
                    exp_dmem[3] = 32'hFFFFFFFB;     // 0x00C
                    exp_pc = 32'h30;  exp_ciclos = 19;  exp_stalls = 3;
                end
                P_MIXTO: begin                      // sw/mixto_lazo.s
                    prog[0]  = 32'h10000093;        //         addi x1, x0, 0x100
                    prog[1]  = 32'h00100113;        //         addi x2, x0, 1
                    prog[2]  = 32'h00500193;        //         addi x3, x0, 5
                    prog[3]  = 32'h0020a023;        // llenar: sw   x2, 0(x1)
                    prog[4]  = 32'h00310113;        //         addi x2, x2, 3
                    prog[5]  = 32'h00408093;        //         addi x1, x1, 4
                    prog[6]  = 32'hfff18193;        //         addi x3, x3, -1
                    prog[7]  = 32'hfe0198e3;        //         bne  x3, x0, llenar
                    prog[8]  = 32'h10000093;        //         addi x1, x0, 0x100
                    prog[9]  = 32'h00500193;        //         addi x3, x0, 5
                    prog[10] = 32'h00000513;        //         addi x10, x0, 0
                    prog[11] = 32'h0000a283;        // sumar:  lw   x5, 0(x1)
                    prog[12] = 32'h00550533;        //         add  x10, x10, x5   stall
                    prog[13] = 32'h00408093;        //         addi x1, x1, 4
                    prog[14] = 32'hfff18193;        //         addi x3, x3, -1
                    prog[15] = 32'hfe0198e3;        //         bne  x3, x0, sumar
                    prog[16] = 32'h20a02023;        //         sw   x10, 0x200(x0)
                    prog[17] = 32'h00100073;        //         halt
                    prog_n   = 18;
                    exp_reg[1]  = 32'h00000114;  exp_reg[2]  = 32'h00000010;
                    exp_reg[5]  = 32'h0000000D;  exp_reg[10] = 32'h00000023;
                    exp_dmem[64]  = 32'h00000001;   // 0x100
                    exp_dmem[65]  = 32'h00000004;   // 0x104
                    exp_dmem[66]  = 32'h00000007;   // 0x108
                    exp_dmem[67]  = 32'h0000000A;   // 0x10C
                    exp_dmem[68]  = 32'h0000000D;   // 0x110
                    exp_dmem[128] = 32'h00000023;   // 0x200
                    exp_pc = 32'h48;  exp_ciclos = 83;  exp_stalls = 5;
                end
                P_LAZO_N: begin                     // 2000 vueltas
                    prog[0] = 32'h00000093;         //       addi x1, x0, 0
                    prog[1] = 32'h7d000113;         //       addi x2, x0, 2000
                    prog[2] = 32'h00108093;         // lazo: addi x1, x1, 1
                    prog[3] = 32'hfe209ee3;         //       bne  x1, x2, lazo
                    prog[4] = 32'h00100073;         //       halt
                    prog_n  = 5;
                    exp_reg[1] = 32'h7D0;  exp_reg[2] = 32'h7D0;
                    exp_pc = 32'h14;  exp_ciclos = LAZO_N_CICLOS;
                end
                default: begin                      // P_LAZO_INF, sin HALT
                    prog[0] = 32'h00108093;         // lazo: addi x1, x1, 1
                    prog[1] = 32'hffdff06f;         //       jal  x0, lazo
                    prog_n  = 2;
                    exp_pc = 32'h0;  exp_ciclos = 0;
                end
            endcase
        end
    endtask

    //------------------------------------------------------------------
    // I-46: lo que hará la carga, con el core detenido. imem = programa y
    // el resto HALT; dmem en cero. Por el puerto B, en los dos cores
    //------------------------------------------------------------------
    task escribir_memorias;
        integer i;
        begin
            @(negedge tb_clk);
            for (i = 0; i < 1024; i = i + 1) begin
                tb_imem_b_en   = 1'b1;
                tb_imem_b_we   = 1'b1;
                tb_imem_b_addr = i;
                tb_imem_b_din  = (i < prog_n) ? prog[i] : INSTR_HALT;
                tb_dmem_b_en   = 1'b1;
                tb_dmem_b_we   = 4'b1111;
                tb_dmem_b_addr = i;
                tb_dmem_b_din  = 32'h0;
                @(negedge tb_clk);
            end
            tb_imem_b_en = 1'b0;  tb_imem_b_we = 1'b0;
            tb_dmem_b_en = 1'b0;  tb_dmem_b_we = 4'b0000;
        end
    endtask

    task reiniciar_ref;
        begin
            @(negedge tb_clk);
            tb_ref_rst = 1'b1;  tb_ref_enable = 1'b0;
            @(negedge tb_clk);
            tb_ref_rst = 1'b0;
        end
    endtask

    // LOAD real del programa p: READY, pc = 0, cycles = 0. Después, la parte
    // de la I-46 y el reset del core de referencia
    task cargar;
        input [8*40-1:0] name;
        input integer    p;
        integer          i;
        begin
            elegir(p);
            for (i = 0; i < prog_n; i = i + 1) begin
                pl_buf[4*i]   = prog[i][7:0];
                pl_buf[4*i+1] = prog[i][15:8];
                pl_buf[4*i+2] = prog[i][23:16];
                pl_buf[4*i+3] = prog[i][31:24];
            end
            peticion(DBG_CMD_LOAD, 4 * prog_n);
            esperar_bloque_pc(name, DBG_CMD_LOAD, DBG_ST_READY, 8'h01, 32'h0, 32'h0);
            escribir_memorias;
            reiniciar_ref;
        end
    endtask

    // RESET: READY, pc = 0, cycles = 0. dmem a cero (CLEAR de la I-46)
    task resetear;
        input [8*40-1:0] name;
        begin
            comando(DBG_CMD_RESET);
            esperar_bloque_pc(name, DBG_CMD_RESET, DBG_ST_READY, 8'h01, 32'h0, 32'h0);
            escribir_memorias;
            reiniciar_ref;
        end
    endtask

    //------------------------------------------------------------------
    // Estado del core
    //------------------------------------------------------------------
    reg [31:0]     cur_reg  [0:31];
    reg [31:0]     cur_dmem [0:1023];
    reg [31:0]     run_reg  [0:31];
    reg [31:0]     run_dmem [0:1023];
    reg [8*48-1:0] nombre;

    // Registros por el puerto de debug y dmem por el puerto B (I-48)
    task leer_estado;
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1) begin
                tb_dbg_reg_addr = i;
                #1;
                cur_reg[i] = dbg_reg_data;
            end
            @(negedge tb_clk);
            tb_dmem_b_en   = 1'b1;
            tb_dmem_b_we   = 4'b0000;
            tb_dmem_b_addr = 10'd0;
            @(negedge tb_clk);
            for (i = 0; i < 1024; i = i + 1) begin
                cur_dmem[i]    = dmem_b_dout;
                tb_dmem_b_addr = i + 1;
                @(negedge tb_clk);
            end
            tb_dmem_b_en = 1'b0;
        end
    endtask

    // Los cuatro valid en 0
    function vacio;
        input dummy;
        begin
            vacio = ~(if_id[64] | id_ex[160] | ex_mem[108] | mem_wb[109]);
        end
    endfunction

    // Estado final contra el .exp
    task chk_final;
        input [8*40-1:0] name;
        integer          i;
        integer          n_mal;
        begin
            leer_estado;
            chk({name, " pc final"}, pc, exp_pc);
            chk({name, " halted"}, halted, 1'b1);
            chk({name, " vacio"}, vacio(1'b0), 1'b1);
            chk({name, " avisos"}, {imem_fault, dmem_oob, dmem_mis}, 3'b000);
            for (i = 0; i < 32; i = i + 1) begin
                $sformat(nombre, "%0s x%0d", name, i);
                chk(nombre, cur_reg[i], exp_reg[i]);
            end
            n_mal = 0;
            for (i = 0; i < 1024; i = i + 1)
                if (cur_dmem[i] !== exp_dmem[i]) begin
                    if (n_mal < 4)
                        $display("    dmem[0x%03h] = 0x%08h, esperado 0x%08h",
                                 4 * i, cur_dmem[i], exp_dmem[i]);
                    n_mal = n_mal + 1;
                end
            chk({name, " dmem"}, n_mal, 0);
        end
    endtask

    // Guarda el estado leído (corrida con RUN)
    task guardar_run;
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1)   run_reg[i]  = cur_reg[i];
            for (i = 0; i < 1024; i = i + 1) run_dmem[i] = cur_dmem[i];
        end
    endtask

    // Mismo estado que la corrida con RUN
    task chk_igual_run;
        input [8*40-1:0] name;
        integer          i;
        integer          n_mal;
        begin
            n_mal = 0;
            for (i = 0; i < 32; i = i + 1)
                if (cur_reg[i] !== run_reg[i]) n_mal = n_mal + 1;
            for (i = 0; i < 1024; i = i + 1)
                if (cur_dmem[i] !== run_dmem[i]) n_mal = n_mal + 1;
            chk({name, " = RUN"}, n_mal, 0);
        end
    endtask

    // El core es igual a u_ref: PC, halted, avisos, registros y latches.
    // En una burbuja solo se compara valid: los datos no se resetean
    task chk_lockstep;
        input [8*48-1:0] name;
        integer          i;
        integer          n_mal;
        begin
            chk({name, " pc"}, pc, ref_pc);
            chk({name, " halted"}, {halted, imem_fault, dmem_oob, dmem_mis},
                {ref_halted, ref_imem_fault, ref_dmem_oob, ref_dmem_mis});
            chk({name, " IF/ID"},  (if_id[64]   === ref_if_id[64])   &&
                                   (!if_id[64]   || if_id   === ref_if_id),   1'b1);
            chk({name, " ID/EX"},  (id_ex[160]  === ref_id_ex[160])  &&
                                   (!id_ex[160]  || id_ex   === ref_id_ex),   1'b1);
            chk({name, " EX/MEM"}, (ex_mem[108] === ref_ex_mem[108]) &&
                                   (!ex_mem[108] || ex_mem  === ref_ex_mem),  1'b1);
            chk({name, " MEM/WB"}, (mem_wb[109] === ref_mem_wb[109]) &&
                                   (!mem_wb[109] || mem_wb  === ref_mem_wb),  1'b1);
            n_mal = 0;
            for (i = 0; i < 32; i = i + 1) begin
                tb_dbg_reg_addr = i;
                #1;
                if (dbg_reg_data !== ref_dbg_reg_data) n_mal = n_mal + 1;
            end
            chk({name, " regs"}, n_mal, 0);
        end
    endtask

    // u_ref avanza n ciclos con enable = 1
    task avanzar_ref;
        input integer n;
        begin
            if (n > 0) begin
                @(negedge tb_clk);
                tb_ref_enable = 1'b1;
                repeat (n) @(negedge tb_clk);
                tb_ref_enable = 1'b0;
            end
        end
    endtask

    //------------------------------------------------------------------
    // Modos
    //------------------------------------------------------------------
    // RUN: confirmación, después EVT_HALTED; enable = 1 exactamente
    // exp_ciclos ciclos; estado final del .exp
    task modo_continuo;
        input [8*40-1:0] name;
        integer          base;
        begin
            base = n_en;
            comando(DBG_CMD_RUN);
            esperar_resp({name, " RUN"}, DBG_CMD_RUN, DBG_OK, 16'd0);
            esperar_bloque_pc({name, " EVT"}, DBG_CMD_EVT_HALTED, DBG_ST_HALTED, 8'h03,
                              exp_pc, exp_ciclos);
            chk({name, " enable"}, n_en - base, exp_ciclos);
            chk_final(name);
            guardar_run;
        end
    endtask

    // STEP hasta HALTED: un ciclo de enable por STEP, cycles = k, lockstep
    // con u_ref; cuenta los STEP que salen de un estado con stall = 1
    task modo_paso;
        input [8*40-1:0] name;
        integer          k;
        integer          base;
        integer          n_stall;
        reg              fin;
        begin
            k = 0;  n_stall = 0;  fin = 1'b0;
            while (!fin && k < exp_ciclos + 2) begin
                if (u_core.stall === 1'b1) n_stall = n_stall + 1;
                base = n_en;
                comando(DBG_CMD_STEP);
                k = k + 1;
                $sformat(nombre, "%0s paso %0d", name, k);
                esperar_resp(nombre, DBG_CMD_STEP, DBG_OK, 16'd12);
                chk({nombre, " enable"}, n_en - base, 1);
                chk({nombre, " cycles"}, blk_word(8), k);
                chk({nombre, " pc"}, blk_word(4), pc);
                avanzar_ref(1);
                chk_lockstep(nombre);
                if (resp_buf[0] == DBG_ST_HALTED) begin
                    fin = 1'b1;
                    chk({nombre, " flags"}, resp_buf[1], 8'h03);
                end
                else begin
                    chk({nombre, " state"}, resp_buf[0], DBG_ST_PAUSED);
                    chk({nombre, " flags"}, resp_buf[1], 8'h01);
                end
            end
            chk({name, " pasos"}, k, exp_ciclos);
            chk({name, " STEP en stall"}, n_stall, exp_stalls);
            sin_respuesta({name, " sin EVT_HALTED"}, 8 * BYTE_CYC);
            chk_final({name, " STEP"});
            chk_igual_run(name);
        end
    endtask

    // STEP y RUN en HALTED: ERR_STATE sin enable; STOP: OK sin cambios
    task chk_halted_cerrado;
        input [8*40-1:0] name;
        integer          base;
        begin
            base = n_en;
            comando(DBG_CMD_STEP);
            esperar_resp({name, " STEP"}, DBG_CMD_STEP, DBG_ERR_STATE, 16'd0);
            comando(DBG_CMD_RUN);
            esperar_resp({name, " RUN"}, DBG_CMD_RUN, DBG_ERR_STATE, 16'd0);
            comando(DBG_CMD_STOP);
            esperar_bloque_pc({name, " STOP"}, DBG_CMD_STOP, DBG_ST_HALTED, 8'h03,
                              exp_pc, exp_ciclos);
            chk({name, " sin enable"}, n_en - base, 0);
        end
    endtask

    //------------------------------------------------------------------
    // u_solo: un comando en el ciclo siguiente (se toma en el flanco)
    //------------------------------------------------------------------
    task s_comando;
        input [7:0] c;
        begin
            s_cmd = c;  s_cmd_valid = 1'b1;
            @(negedge tb_clk);
            s_cmd_valid = 1'b0;
        end
    endtask

    task s_chk;
        input [8*40-1:0] name;
        input [2:0]      st;
        input            en;
        input            crst;
        input            evt;
        begin
            chk({name, " state"},    s_o_state, st);
            chk({name, " enable"},   s_o_enable, en);
            chk({name, " core_rst"}, s_o_core_rst, crst);
            chk({name, " evt"},      s_o_evt_pending, evt);
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    integer    base;
    integer    c1;
    integer    i;

    initial begin
        errors = 0;  checks = 0;
        tb_rst = 1'b1;  tb_rx = 1'b1;
        tb_imem_b_en = 1'b0;  tb_imem_b_we = 1'b0;  tb_imem_b_addr = 10'd0;  tb_imem_b_din = 32'h0;
        tb_dmem_b_en = 1'b0;  tb_dmem_b_we = 4'b0;  tb_dmem_b_addr = 10'd0;  tb_dmem_b_din = 32'h0;
        tb_dbg_reg_addr = 5'd0;
        tb_ref_rst = 1'b1;  tb_ref_enable = 1'b0;
        s_rst = 1'b1;  s_cmd_valid = 1'b0;  s_cmd = 8'h00;  s_load_start = 1'b0;
        s_mem_busy = 1'b0;  s_evt_done = 1'b0;  s_halted = 1'b0;
        repeat (4) @(negedge tb_clk);
        tb_rst = 1'b0;  tb_ref_rst = 1'b0;  s_rst = 1'b0;
        repeat (4) @(negedge tb_clk);

        //--------------------------------------------------------------
        // Después del reset: NO_PROG, core en reset; RUN y STEP no
        // arrancan; STOP y RESET responden sin cambiar nada
        //--------------------------------------------------------------
        chk("reset: NO_PROG",  tb_o_state, DBG_ST_NO_PROG);
        chk("reset: core_rst", tb_o_core_rst, 1'b1);
        chk("reset: enable",   tb_o_enable, 1'b0);
        comando(DBG_CMD_STATUS);
        esperar_bloque_pc("NO_PROG STATUS", DBG_CMD_STATUS, DBG_ST_NO_PROG, 8'h00, 32'h0, 32'h0);
        comando(DBG_CMD_RUN);
        esperar_resp("NO_PROG RUN", DBG_CMD_RUN, DBG_ERR_STATE, 16'd0);
        comando(DBG_CMD_STEP);
        esperar_resp("NO_PROG STEP", DBG_CMD_STEP, DBG_ERR_STATE, 16'd0);
        comando(DBG_CMD_STOP);
        esperar_bloque_pc("NO_PROG STOP", DBG_CMD_STOP, DBG_ST_NO_PROG, 8'h00, 32'h0, 32'h0);
        comando(DBG_CMD_RESET);
        esperar_bloque_pc("NO_PROG RESET", DBG_CMD_RESET, DBG_ST_NO_PROG, 8'h00, 32'h0, 32'h0);
        chk("NO_PROG: sin enable", n_en, 0);
        chk("NO_PROG: core_rst", tb_o_core_rst, 1'b1);

        //--------------------------------------------------------------
        // Las tramas de §4 con el core real: LOAD, RUN, confirmación y
        // EVT_HALTED (HALTED, PC = 0x08, 6 ciclos)
        //--------------------------------------------------------------
        enviar_hex(13, 104'hA5_10_08_00_93_00_50_00_73_00_10_00_B8);
        esperar_hex("ej4 LOAD", 18, 144'h5A_10_00_0C_00_01_01_00_00_00_00_00_00_00_00_00_00_1C);
        elegir(P_EJEMPLO);
        escribir_memorias;                                   // I-46
        chk("ej4 READY: core_rst", tb_o_core_rst, 1'b0);
        base = n_en;
        enviar_hex(5, 40'hA5_20_00_00_20);
        esperar_hex("ej4 RUN", 6, 48'h5A_20_00_00_00_20);
        esperar_hex("ej4 EVT_HALTED", 18,
                    144'h5A_E0_00_0C_00_04_03_00_00_08_00_00_00_06_00_00_00_E5);
        chk("ej4 enable", n_en - base, 6);
        chk_final("ej4");
        enviar_hex(5, 40'hA5_21_00_00_21);                   // STEP en HALTED
        esperar_hex("ej4 STEP en HALTED", 6, 48'h5A_21_04_00_00_25);
        chk_halted_cerrado("ej4 HALTED");

        //--------------------------------------------------------------
        // RUN y STEP repetido, con el mismo estado final
        //--------------------------------------------------------------
        cargar("halt_basico LOAD", P_HALT_BASICO);
        modo_continuo("halt_basico");
        chk_halted_cerrado("halt_basico HALTED");
        resetear("halt_basico RESET");
        comando(DBG_CMD_STOP);                               // STOP en READY
        esperar_bloque_pc("READY STOP", DBG_CMD_STOP, DBG_ST_READY, 8'h01, 32'h0, 32'h0);
        modo_paso("halt_basico");
        chk_halted_cerrado("halt_basico HALTED por STEP");

        cargar("loaduse LOAD", P_LOADUSE);
        modo_continuo("loaduse");
        resetear("loaduse RESET");
        modo_paso("loaduse");

        cargar("mixto LOAD", P_MIXTO);
        modo_continuo("mixto");
        resetear("mixto RESET");
        modo_paso("mixto");
        chk_halted_cerrado("mixto HALTED");

        // Después de RESET, RUN vuelve a dar el mismo resultado
        resetear("mixto RESET 2");
        modo_continuo("mixto otra vez");

        //--------------------------------------------------------------
        // STOP en el medio de lazo_n: se pausa sin perder estado
        //--------------------------------------------------------------
        cargar("lazo_n LOAD", P_LAZO_N);
        base = n_en;
        comando(DBG_CMD_RUN);
        comando(DBG_CMD_STOP);                // entra mientras sale la confirmación
        esperar_resp("lazo_n RUN", DBG_CMD_RUN, DBG_OK, 16'd0);
        esperar_bloque("lazo_n STOP", DBG_CMD_STOP, DBG_ST_PAUSED, 8'h01);
        c1 = blk_word(8);
        chk("lazo_n STOP en el medio", (c1 > 0) && (c1 < LAZO_N_CICLOS), 1'b1);
        chk("lazo_n STOP: enable = cycles", n_en - base, c1);
        chk("lazo_n STOP: pc", blk_word(4), pc);
        repeat (3000) @(negedge tb_clk);
        chk("lazo_n PAUSED: enable", n_en - base, c1);
        comando(DBG_CMD_STATUS);
        esperar_bloque("lazo_n STATUS", DBG_CMD_STATUS, DBG_ST_PAUSED, 8'h01);
        chk("lazo_n STATUS cycles", blk_word(8), c1);
        avanzar_ref(c1);                      // u_ref: c1 ciclos sin cortes
        chk_lockstep("lazo_n STOP = c1 ciclos");
        comando(DBG_CMD_STOP);                // STOP en PAUSED
        esperar_bloque("lazo_n STOP en PAUSED", DBG_CMD_STOP, DBG_ST_PAUSED, 8'h01);
        chk("lazo_n STOP en PAUSED cycles", blk_word(8), c1);
        for (i = 1; i <= 3; i = i + 1) begin
            comando(DBG_CMD_STEP);
            $sformat(nombre, "lazo_n STEP %0d", i);
            esperar_bloque(nombre, DBG_CMD_STEP, DBG_ST_PAUSED, 8'h01);
            chk({nombre, " cycles"}, blk_word(8), c1 + i);
            avanzar_ref(1);
            chk_lockstep(nombre);
        end
        comando(DBG_CMD_RUN);
        esperar_resp("lazo_n RUN 2", DBG_CMD_RUN, DBG_OK, 16'd0);
        esperar_bloque_pc("lazo_n EVT", DBG_CMD_EVT_HALTED, DBG_ST_HALTED, 8'h03,
                          exp_pc, exp_ciclos);
        chk("lazo_n enable total", n_en - base, LAZO_N_CICLOS);
        chk_final("lazo_n");
        chk_halted_cerrado("lazo_n HALTED");

        //--------------------------------------------------------------
        // RESET con un EVT_HALTED pendiente: el HALT llega mientras entra la
        // trama del RESET (en reposo saldría primero el evento)
        //--------------------------------------------------------------
        resetear("lazo_n RESET");
        base = n_en;
        comando(DBG_CMD_RUN);
        esperar_resp("carrera RUN", DBG_CMD_RUN, DBG_OK, 16'd0);
        wait (n_en - base >= LAZO_N_CICLOS - 800);
        comando(DBG_CMD_RESET);
        esperar_bloque_pc("carrera RESET", DBG_CMD_RESET, DBG_ST_READY, 8'h01, 32'h0, 32'h0);
        chk("carrera: el HALT llego antes", n_en - base, LAZO_N_CICLOS);
        chk("carrera: evento pendiente en el RESET", evt_at_cmd, 1'b1);
        chk("carrera: evento descartado", tb_o_evt_pending, 1'b0);
        sin_respuesta("carrera: sin EVT_HALTED", 10 * BYTE_CYC);
        escribir_memorias;                                   // I-46

        //--------------------------------------------------------------
        // RESET y LOAD en RUNNING (lazo sin HALT)
        //--------------------------------------------------------------
        cargar("lazo_inf LOAD", P_LAZO_INF);
        comando(DBG_CMD_RUN);
        esperar_resp("lazo_inf RUN", DBG_CMD_RUN, DBG_OK, 16'd0);
        repeat (2000) @(negedge tb_clk);
        comando(DBG_CMD_STATUS);
        esperar_bloque("lazo_inf STATUS", DBG_CMD_STATUS, DBG_ST_RUNNING, 8'h01);
        chk("lazo_inf corre", blk_word(8) > 2000, 1'b1);
        comando(DBG_CMD_RESET);
        esperar_bloque_pc("RESET en RUNNING", DBG_CMD_RESET, DBG_ST_READY, 8'h01, 32'h0, 32'h0);
        base = n_en;
        repeat (2000) @(negedge tb_clk);
        chk("RESET en RUNNING: detenido", n_en - base, 0);
        chk("RESET en RUNNING: pc", pc, 32'h0);
        chk("RESET en RUNNING: vacio", vacio(1'b0), 1'b1);
        chk("RESET en RUNNING: x1", u_core.u_id_stage.u_regfile.regs[1], 32'h0);
        sin_respuesta("RESET en RUNNING: sin evento", 4 * BYTE_CYC);
        comando(DBG_CMD_RUN);
        esperar_resp("lazo_inf RUN 2", DBG_CMD_RUN, DBG_OK, 16'd0);
        repeat (2000) @(negedge tb_clk);
        cargar("LOAD en RUNNING", P_EJEMPLO);
        base = n_en;
        repeat (2000) @(negedge tb_clk);
        chk("LOAD en RUNNING: detenido", n_en - base, 0);
        chk("LOAD en RUNNING: pc", pc, 32'h0);
        chk("LOAD en RUNNING: vacio", vacio(1'b0), 1'b1);
        sin_respuesta("LOAD en RUNNING: sin evento", 4 * BYTE_CYC);
        modo_continuo("ejemplo despues del LOAD");

        //--------------------------------------------------------------
        // debug_exec solo: prioridades y pulsos, ciclo a ciclo
        //--------------------------------------------------------------
        s_chk("solo reset", DBG_ST_NO_PROG, 1'b0, 1'b1, 1'b0);
        chk("solo reset prog", s_o_prog_valid, 1'b0);
        chk("solo reset cycles", s_o_cycles, 32'd0);
        s_comando(DBG_CMD_RUN);
        s_chk("solo RUN en NO_PROG", DBG_ST_NO_PROG, 1'b0, 1'b1, 1'b0);
        s_comando(DBG_CMD_STEP);
        s_chk("solo STEP en NO_PROG", DBG_ST_NO_PROG, 1'b0, 1'b1, 1'b0);
        @(negedge tb_clk);
        s_chk("solo STEP en NO_PROG +1", DBG_ST_NO_PROG, 1'b0, 1'b1, 1'b0);
        s_comando(DBG_CMD_RESET);
        s_chk("solo RESET sin programa", DBG_ST_NO_PROG, 1'b0, 1'b1, 1'b0);

        // LOAD: READY y un ciclo de core_rst
        s_comando(DBG_CMD_LOAD);
        s_chk("solo LOAD", DBG_ST_READY, 1'b0, 1'b1, 1'b0);
        chk("solo LOAD prog", s_o_prog_valid, 1'b1);
        @(negedge tb_clk);
        s_chk("solo LOAD +1", DBG_ST_READY, 1'b0, 1'b0, 1'b0);
        s_mem_busy = 1'b1;  #1;
        chk("solo mem_busy: core_rst", s_o_core_rst, 1'b1);
        s_mem_busy = 1'b0;  #1;
        chk("solo sin mem_busy", s_o_core_rst, 1'b0);
        s_comando(DBG_CMD_STOP);
        s_chk("solo STOP en READY", DBG_ST_READY, 1'b0, 1'b0, 1'b0);

        // STEP: enable = 1 exactamente en el ciclo siguiente
        s_comando(DBG_CMD_STEP);
        s_chk("solo STEP", DBG_ST_PAUSED, 1'b1, 1'b0, 1'b0);
        chk("solo STEP cycles antes", s_o_cycles, 32'd0);
        @(negedge tb_clk);
        s_chk("solo STEP +1", DBG_ST_PAUSED, 1'b0, 1'b0, 1'b0);
        chk("solo STEP cycles", s_o_cycles, 32'd1);
        repeat (3) @(negedge tb_clk);
        chk("solo STEP +4 cycles", s_o_cycles, 32'd1);
        chk("solo STEP +4 enable", s_o_enable, 1'b0);

        // STEP que lleva el HALT a WB: HALTED sin evento
        s_comando(DBG_CMD_STEP);
        s_chk("solo STEP 2", DBG_ST_PAUSED, 1'b1, 1'b0, 1'b0);
        @(posedge tb_clk);                                 // el flanco del ciclo del STEP
        #1  s_halted = 1'b1;
        @(negedge tb_clk);
        s_chk("solo STEP 2 +1", DBG_ST_PAUSED, 1'b0, 1'b0, 1'b0);
        chk("solo STEP 2 cycles", s_o_cycles, 32'd2);
        @(negedge tb_clk);
        s_chk("solo STEP con halt", DBG_ST_HALTED, 1'b0, 1'b0, 1'b0);
        chk("solo STEP con halt cycles", s_o_cycles, 32'd2);
        s_comando(DBG_CMD_RUN);
        s_chk("solo RUN en HALTED", DBG_ST_HALTED, 1'b0, 1'b0, 1'b0);
        s_comando(DBG_CMD_STEP);
        s_chk("solo STEP en HALTED", DBG_ST_HALTED, 1'b0, 1'b0, 1'b0);
        @(negedge tb_clk);
        s_chk("solo STEP en HALTED +1", DBG_ST_HALTED, 1'b0, 1'b0, 1'b0);
        s_comando(DBG_CMD_STOP);
        s_chk("solo STOP en HALTED", DBG_ST_HALTED, 1'b0, 1'b0, 1'b0);
        chk("solo HALTED cycles", s_o_cycles, 32'd2);

        // RESET en HALTED: READY, cycles = 0 y un ciclo de core_rst
        s_comando(DBG_CMD_RESET);
        s_chk("solo RESET en HALTED", DBG_ST_READY, 1'b0, 1'b1, 1'b0);
        chk("solo RESET cycles", s_o_cycles, 32'd0);
        s_halted = 1'b0;                                   // el core se resetea
        @(negedge tb_clk);
        s_chk("solo RESET +1", DBG_ST_READY, 1'b0, 1'b0, 1'b0);

        // RUN: enable desde el ciclo siguiente, cycles cuenta
        s_comando(DBG_CMD_RUN);
        s_chk("solo RUN", DBG_ST_RUNNING, 1'b1, 1'b0, 1'b0);
        repeat (5) @(negedge tb_clk);
        chk("solo RUN cycles", s_o_cycles, 32'd5);

        // STOP y halt en el mismo ciclo: gana halt (HALTED con evento);
        // enable ya es 0 en ese ciclo y cycles no lo cuenta
        s_halted = 1'b1;  #1;
        chk("solo halt: enable baja en el ciclo", s_o_enable, 1'b0);
        s_comando(DBG_CMD_STOP);
        s_chk("solo STOP con halt", DBG_ST_HALTED, 1'b0, 1'b0, 1'b1);
        chk("solo STOP con halt cycles", s_o_cycles, 32'd5);
        s_evt_done = 1'b1;
        @(negedge tb_clk);
        s_evt_done = 1'b0;
        s_chk("solo evt_done", DBG_ST_HALTED, 1'b0, 1'b0, 1'b0);

        // RESET y halt en el mismo ciclo: gana RESET, sin evento
        s_comando(DBG_CMD_RESET);
        s_halted = 1'b0;
        s_comando(DBG_CMD_RUN);
        s_chk("solo RUN 2", DBG_ST_RUNNING, 1'b1, 1'b0, 1'b0);
        s_halted = 1'b1;
        s_comando(DBG_CMD_RESET);
        s_chk("solo RESET con halt", DBG_ST_READY, 1'b0, 1'b1, 1'b0);
        chk("solo RESET con halt cycles", s_o_cycles, 32'd0);
        s_halted = 1'b0;

        // LOAD y halt en el mismo ciclo: gana LOAD, sin evento
        s_comando(DBG_CMD_RUN);
        s_halted = 1'b1;
        s_comando(DBG_CMD_LOAD);
        s_chk("solo LOAD con halt", DBG_ST_READY, 1'b0, 1'b1, 1'b0);
        s_halted = 1'b0;

        // RESET con el evento pendiente: lo descarta
        s_comando(DBG_CMD_RUN);
        s_halted = 1'b1;
        @(negedge tb_clk);
        s_chk("solo halt en RUNNING", DBG_ST_HALTED, 1'b0, 1'b0, 1'b1);
        s_comando(DBG_CMD_RESET);
        s_chk("solo RESET descarta el evento", DBG_ST_READY, 1'b0, 1'b1, 1'b0);
        s_halted = 1'b0;

        // STOP y halt en el ciclo siguiente: PAUSED -> HALTED sin evento
        s_comando(DBG_CMD_RUN);
        s_comando(DBG_CMD_STOP);
        s_chk("solo STOP", DBG_ST_PAUSED, 1'b0, 1'b0, 1'b0);
        s_halted = 1'b1;
        @(negedge tb_clk);
        s_chk("solo halt en PAUSED", DBG_ST_HALTED, 1'b0, 1'b0, 1'b0);
        s_comando(DBG_CMD_RESET);
        s_halted = 1'b0;

        // STOP en RUNNING: cycles se congela; RUN sigue desde PAUSED
        s_comando(DBG_CMD_RUN);
        repeat (3) @(negedge tb_clk);
        s_comando(DBG_CMD_STOP);
        s_chk("solo STOP en RUNNING", DBG_ST_PAUSED, 1'b0, 1'b0, 1'b0);
        base = s_o_cycles;
        repeat (3) @(negedge tb_clk);
        chk("solo PAUSED cycles", s_o_cycles, base);
        s_comando(DBG_CMD_STOP);
        s_chk("solo STOP en PAUSED", DBG_ST_PAUSED, 1'b0, 1'b0, 1'b0);
        s_comando(DBG_CMD_RUN);
        s_chk("solo RUN desde PAUSED", DBG_ST_RUNNING, 1'b1, 1'b0, 1'b0);

        // load_start (I-46) en RUNNING con evento pendiente: NO_PROG, sin
        // programa, core en reset y sin evento
        s_halted = 1'b1;
        @(negedge tb_clk);
        s_chk("solo halt 2", DBG_ST_HALTED, 1'b0, 1'b0, 1'b1);
        s_halted = 1'b0;
        s_load_start = 1'b1;
        @(negedge tb_clk);
        s_load_start = 1'b0;
        s_chk("solo load_start", DBG_ST_NO_PROG, 1'b0, 1'b1, 1'b0);
        chk("solo load_start prog", s_o_prog_valid, 1'b0);
        s_comando(DBG_CMD_RESET);
        s_chk("solo RESET sin programa 2", DBG_ST_NO_PROG, 1'b0, 1'b1, 1'b0);
        s_comando(DBG_CMD_LOAD);
        s_comando(DBG_CMD_RUN);
        s_load_start = 1'b1;
        @(negedge tb_clk);
        s_load_start = 1'b0;
        s_chk("solo load_start en RUNNING", DBG_ST_NO_PROG, 1'b0, 1'b1, 1'b0);

        //--------------------------------------------------------------
        // Durante todo el testbench
        //--------------------------------------------------------------
        chk("enable con halted", n_en_halted, 0);
        chk("enable con core_rst", n_en_rst, 0);
        chk("tramas serie bien formadas", rx_bad, 0);

        if (errors == 0)
            $display("TEST PASSED: %0d chequeos, 0 errores", checks);
        else
            $display("TEST FAILED: %0d errores sobre %0d chequeos", errors, checks);
        $finish;
    end

    initial begin
        #(MAX_TIME);
        $display("TEST FAILED: timeout de %0d ns", MAX_TIME);
        $finish;
    end

endmodule
