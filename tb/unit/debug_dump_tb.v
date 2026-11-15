`timescale 1ns / 1ps

//======================================================================
// debug_dump_tb
//
// Testbench autoverificante del volcado de estado de la Debug Unit (I-48:
// debug_dump y debug_used_map; docs/spec/verificacion.md §3.3,
// protocolo_debug.md §3.6 y §7, memoria.md §7, decisiones 005, 038 y 039).
//
// Dos montajes:
//
// A. Sistema, por la línea serie (corre en xsim: usa las BRAM del core):
//      PC (testbench) --serie--> uart <--> debug_unit <--> debug_exec
//      debug_unit <--> debug_dump <--puerto B, banco, latches, dmem_we--> riscv_core
//    Programas de sw/ con su .exp copiado a mano (mem_byte_media,
//    mem_avisos) y tres escritos acá, con un comentario por instrucción:
//    usadas_orden, solo_1023 y paso_riesgos. Oráculo:
//      - Registros y dmem: los .exp y los comentarios de los programas.
//      - Latches: la concatenación de los campos del core por jerarquía, en
//        el orden de pipeline.md §8, partida en palabras de 32 bits (§3.6);
//        no usa los buses o_*_latch.
//      - Mapa de usadas: las palabras de cada programa, escritas a mano. En
//        el paso a paso, una copia que marca ex_mem_result[11:2] con
//        enable & ex_mem_mem_write por jerarquía (decisión 027).
//      - Las respuestas: encabezado, LEN y checksum calculados acá.
//    Con DVSR = 2 el encabezado tapa la búsqueda de la primera palabra
//    usada (5 bytes = 1600 ciclos > 1024), pero la de cada par siguiente
//    empieza cuando el envío llega a ese par: en usadas_orden el tercer par
//    (la palabra 1023) espera con i_pl_ready = 0 y i_tx_full = 0. El peor
//    caso sin la UART lo prueba el montaje B.
//
// B. debug_unit y debug_dump sin la UART: el testbench entrega los bytes de
//    la petición de a uno por ciclo y toma cada o_wr con i_tx_full = 0, así
//    debug_unit transmite tan rápido como lo deja i_pl_ready. dmem (con
//    lectura de un ciclo y READ_FIRST), el banco y los latches son modelos
//    del testbench; las marcas del mapa (i_dmem_we) las da el testbench.
//    Prueba la latencia de cada fuente (hasta 2 ciclos por byte), el peor
//    caso de la búsqueda (~1024 ciclos esperando con i_pl_ready = 0), las
//    1024 palabras marcadas (LEN = 8192 y 8400 en READ_ALL), el contador
//    con marcas repetidas, el reset y el borrado de CLEAR.
//
// Monitores, en los dos montajes: debug_unit nunca escribe un byte de una
// lectura con i_pl_ready = 0 (ni uno distinto de o_pl_byte); en A, el
// puerto B de dmem solo se lee con el core detenido.
//
// UART: CLK_FREQ_HZ = 32 × 115200 (DVSR = 2, un byte serie = 320 ciclos)
// y RX_TIMEOUT_CYCLES = 3000, para simular rápido.
//
// Aleatoriedad: el orden de las 1024 marcas y los latches del montaje B,
// con semilla fija (SEED).
//======================================================================

module debug_dump_tb;

    `include "riscv_defs.vh"

    localparam integer T_CLK     = 10;            // ns
    localparam integer BAUD      = 115200;
    localparam integer F_CLK     = 32 * BAUD;     // DVSR = 2
    localparam integer TOUT      = 3000;          // ciclos
    localparam integer BYTE_CYC  = 320;           // ciclos por byte serie
    localparam real    BIT_NS    = 320.0;         // 16 ticks × 2 ciclos × 10 ns
    localparam integer MAX_TIME  = 300_000_000;   // ns, watchdog
    localparam integer RESP_WAIT = 2000 + 40 * BYTE_CYC;   // ciclos hasta un byte (CLEAR incluido)
    localparam integer B_WAIT    = 5000;          // ciclos hasta un byte en B
    localparam integer WORDS     = 1024;
    localparam integer SEED      = 48;

    // Offsets de READ_ALL (§3.6): estado, registros, latches y pares
    localparam integer OFF_REGS  = 12;
    localparam integer OFF_LAT   = 12 + 128;
    localparam integer OFF_PARES = 12 + 128 + 68;
    localparam integer LEN_LAT   = 68;

    reg tb_clk;
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

    function is_lectura;
        input [7:0] c;
        begin
            is_lectura = (c == DBG_CMD_READ_REGS) | (c == DBG_CMD_READ_LATCHES) |
                         (c == DBG_CMD_READ_DMEM) | (c == DBG_CMD_READ_DMEM_USED) |
                         (c == DBG_CMD_READ_ALL);
        end
    endfunction

    //==================================================================
    // A. Sistema por la línea serie
    //==================================================================
    reg         tb_rst;
    reg         tb_rx;
    wire        tb_o_tx;

    // uart <-> debug_unit
    wire [7:0]  r_data;
    wire        rx_empty;
    wire        rd;
    wire [7:0]  w_data;
    wire        wr;
    wire        tx_full;

    // debug_unit
    wire        du_evt_done;
    wire        du_cmd_valid;
    wire [7:0]  du_cmd;
    wire [31:0] du_arg_addr;
    wire [15:0] du_arg_count;
    wire [15:0] du_pl_idx;
    wire        du_load_start;
    wire        du_clearing;
    wire        du_imem_b_en;
    wire        du_imem_b_we;
    wire [9:0]  du_imem_b_addr;
    wire [31:0] du_imem_b_din;
    wire        du_dmem_b_en;
    wire [3:0]  du_dmem_b_we;
    wire [9:0]  du_dmem_b_addr;
    wire [31:0] du_dmem_b_din;
    wire        du_used_clr;

    // debug_dump
    wire [7:0]  dd_pl_byte;
    wire        dd_pl_ready;
    wire [15:0] dd_dmem_used;
    wire        dd_dmem_b_en;
    wire [3:0]  dd_dmem_b_we;
    wire [9:0]  dd_dmem_b_addr;
    wire [31:0] dd_dmem_b_din;
    wire [4:0]  dd_reg_addr;

    // debug_exec
    wire [2:0]  ex_state;
    wire        ex_prog_valid;
    wire [31:0] ex_cycles;
    wire        ex_evt_pending;
    wire        core_rst;
    wire        core_en;

    // Core
    wire         core_halted;
    wire         core_imem_fault;
    wire         core_dmem_oob;
    wire         core_dmem_mis;
    wire [31:0]  core_pc;
    wire [31:0]  core_dmem_b_dout;
    wire [31:0]  core_reg_data;
    wire         core_dmem_we;
    wire [9:0]   core_dmem_addr;
    wire [64:0]  core_if_id;
    wire [160:0] core_id_ex;
    wire [108:0] core_ex_mem;
    wire [109:0] core_mem_wb;

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
    ) u_dut (
        .i_clk             (tb_clk),
        .i_rst             (tb_rst),
        .i_r_data          (r_data),
        .i_rx_empty        (rx_empty),
        .o_rd              (rd),
        .o_w_data          (w_data),
        .o_wr              (wr),
        .i_tx_full         (tx_full),
        .i_state           (ex_state),
        .i_prog_valid      (ex_prog_valid),
        .i_halted          (core_halted),
        .i_imem_fault      (core_imem_fault),
        .i_dmem_oob        (core_dmem_oob),
        .i_dmem_misaligned (core_dmem_mis),
        .i_dmem_used       (dd_dmem_used),
        .i_pc              (core_pc),
        .i_cycles          (ex_cycles),
        .i_evt_pending     (ex_evt_pending),
        .o_evt_done        (du_evt_done),
        .o_cmd_valid       (du_cmd_valid),
        .o_cmd             (du_cmd),
        .o_arg_addr        (du_arg_addr),
        .o_arg_count       (du_arg_count),
        .o_load_start      (du_load_start),
        .o_clearing        (du_clearing),
        .o_imem_b_en       (du_imem_b_en),
        .o_imem_b_we       (du_imem_b_we),
        .o_imem_b_addr     (du_imem_b_addr),
        .o_imem_b_din      (du_imem_b_din),
        .o_dmem_b_en       (du_dmem_b_en),
        .o_dmem_b_we       (du_dmem_b_we),
        .o_dmem_b_addr     (du_dmem_b_addr),
        .o_dmem_b_din      (du_dmem_b_din),
        .o_used_clr        (du_used_clr),
        .o_pl_idx          (du_pl_idx),
        .i_pl_byte         (dd_pl_byte),
        .i_pl_ready        (dd_pl_ready)
    );

    debug_exec u_exec (
        .i_clk         (tb_clk),
        .i_rst         (tb_rst),
        .i_cmd_valid   (du_cmd_valid),
        .i_cmd         (du_cmd),
        .i_load_start  (du_load_start),
        .i_mem_busy    (du_clearing),
        .i_evt_done    (du_evt_done),
        .o_state       (ex_state),
        .o_prog_valid  (ex_prog_valid),
        .o_cycles      (ex_cycles),
        .o_evt_pending (ex_evt_pending),
        .i_halted      (core_halted),
        .o_enable      (core_en),
        .o_core_rst    (core_rst)
    );

    debug_dump u_dump (
        .i_clk            (tb_clk),
        .i_rst            (tb_rst),
        .i_cmd_valid      (du_cmd_valid),
        .i_cmd            (du_cmd),
        .i_arg_addr       (du_arg_addr),
        .i_pl_idx         (du_pl_idx),
        .o_pl_byte        (dd_pl_byte),
        .o_pl_ready       (dd_pl_ready),
        .o_dmem_used      (dd_dmem_used),
        .i_du_dmem_b_en   (du_dmem_b_en),
        .i_du_dmem_b_we   (du_dmem_b_we),
        .i_du_dmem_b_addr (du_dmem_b_addr),
        .i_du_dmem_b_din  (du_dmem_b_din),
        .i_used_clr       (du_used_clr),
        .o_dmem_b_en      (dd_dmem_b_en),
        .o_dmem_b_we      (dd_dmem_b_we),
        .o_dmem_b_addr    (dd_dmem_b_addr),
        .o_dmem_b_din     (dd_dmem_b_din),
        .i_dmem_b_dout    (core_dmem_b_dout),
        .i_dmem_we        (core_dmem_we),
        .i_dmem_addr      (core_dmem_addr),
        .o_dbg_reg_addr   (dd_reg_addr),
        .i_dbg_reg_data   (core_reg_data),
        .i_if_id_latch    (core_if_id),
        .i_id_ex_latch    (core_id_ex),
        .i_ex_mem_latch   (core_ex_mem),
        .i_mem_wb_latch   (core_mem_wb)
    );

    riscv_core u_core (
        .i_clk             (tb_clk),
        .i_rst             (core_rst),
        .i_enable          (core_en),
        .i_imem_b_en       (du_imem_b_en),
        .i_imem_b_we       (du_imem_b_we),
        .i_imem_b_addr     (du_imem_b_addr),
        .i_imem_b_din      (du_imem_b_din),
        .i_dmem_b_en       (dd_dmem_b_en),
        .i_dmem_b_we       (dd_dmem_b_we),
        .i_dmem_b_addr     (dd_dmem_b_addr),
        .i_dmem_b_din      (dd_dmem_b_din),
        .o_dmem_b_dout     (core_dmem_b_dout),
        .i_dbg_reg_addr    (dd_reg_addr),
        .o_dbg_reg_data    (core_reg_data),
        .o_halted          (core_halted),
        .o_imem_fault      (core_imem_fault),
        .o_dmem_oob        (core_dmem_oob),
        .o_dmem_misaligned (core_dmem_mis),
        .o_dmem_we         (core_dmem_we),
        .o_dmem_addr       (core_dmem_addr),
        .o_pc              (core_pc),
        .o_if_id_latch     (core_if_id),
        .o_id_ex_latch     (core_id_ex),
        .o_ex_mem_latch    (core_ex_mem),
        .o_mem_wb_latch    (core_mem_wb)
    );

    //------------------------------------------------------------------
    // Latches por jerarquía, en el orden de pipeline.md §8, y partidos en
    // palabras de 32 bits con relleno en 0 (protocolo_debug.md §3.6)
    //------------------------------------------------------------------
    wire [64:0] h_if_id = {u_core.if_id_valid, u_core.if_id_pc, u_core.if_id_instr};
    wire [160:0] h_id_ex = {u_core.id_ex_valid, u_core.id_ex_pc, u_core.id_ex_rs1_data,
                            u_core.id_ex_rs2_data, u_core.id_ex_imm, u_core.id_ex_rs1,
                            u_core.id_ex_rs2, u_core.id_ex_rd, u_core.id_ex_funct3,
                            u_core.id_ex_alu_ctrl, u_core.id_ex_alu_src_a,
                            u_core.id_ex_alu_src_b, u_core.id_ex_branch, u_core.id_ex_jal,
                            u_core.id_ex_jalr, u_core.id_ex_mem_read, u_core.id_ex_mem_write,
                            u_core.id_ex_reg_write, u_core.id_ex_mem_to_reg, u_core.id_ex_halt};
    wire [108:0] h_ex_mem = {u_core.ex_mem_valid, u_core.ex_mem_pc, u_core.ex_mem_result,
                             u_core.ex_mem_store_data, u_core.ex_mem_rd, u_core.ex_mem_funct3,
                             u_core.ex_mem_mem_write, u_core.ex_mem_reg_write,
                             u_core.ex_mem_mem_to_reg, u_core.ex_mem_halt};
    wire [109:0] h_mem_wb = {u_core.mem_wb_valid, u_core.mem_wb_pc, u_core.mem_wb_result,
                             u_core.mem_wb_read_data, u_core.mem_wb_rd, u_core.mem_wb_funct3,
                             u_core.mem_wb_offset, u_core.mem_wb_reg_write,
                             u_core.mem_wb_mem_to_reg, u_core.mem_wb_halt};
    wire [8*LEN_LAT-1:0] h_lat = {{(128-110){1'b0}}, h_mem_wb,      // palabras 13 a 16
                                  {(128-109){1'b0}}, h_ex_mem,      // palabras 9 a 12
                                  {(192-161){1'b0}}, h_id_ex,       // palabras 3 a 8
                                  {(96-65){1'b0}},   h_if_id};      // palabras 0 a 2

    //------------------------------------------------------------------
    // Copia del mapa de usadas para el paso a paso (decisión 027)
    //------------------------------------------------------------------
    reg sh_used [0:WORDS-1];
    integer m;

    always @(posedge tb_clk) begin
        if (core_en && u_core.ex_mem_mem_write)
            sh_used[u_core.ex_mem_result[11:2]] = 1'b1;
        if (du_used_clr)
            sh_used[du_dmem_b_addr] = 1'b0;
    end

    //------------------------------------------------------------------
    // Monitores
    //------------------------------------------------------------------
    integer a_tx_sin_ready;    // byte de una lectura con i_pl_ready = 0 o distinto
    integer a_b_con_core;      // lectura del puerto B con el core habilitado
    integer a_espera;          // ciclos en que solo i_pl_ready frena un byte

    wire a_externo = (u_dut.state_reg == 4'd10) & is_lectura(du_cmd) &
                     ~((du_cmd == DBG_CMD_READ_ALL) & (du_pl_idx < 16'd12));

    always @(posedge tb_clk) begin
        if (wr && a_externo && (!dd_pl_ready || w_data !== dd_pl_byte))
            a_tx_sin_ready = a_tx_sin_ready + 1;
        if (dd_dmem_b_en && !du_dmem_b_en && core_en)
            a_b_con_core = a_b_con_core + 1;
        if (a_externo && !tx_full && !dd_pl_ready)
            a_espera = a_espera + 1;
    end

    //------------------------------------------------------------------
    // PC: transmisor y receptor serie
    //------------------------------------------------------------------
    task serie_tx;
        input [7:0] dato;
        integer     j;
        begin
            tb_rx = 1'b0;
            #(BIT_NS);
            for (j = 0; j < 8; j = j + 1) begin
                tb_rx = dato[j];
                #(BIT_NS);
            end
            tb_rx = 1'b1;
            #(BIT_NS);
        end
    endtask

    reg [7:0] rx_q [0:65535];           // circular: rx_n y rx_rd con [15:0]
    integer   rx_n;
    integer   rx_rd;
    integer   rx_bad;
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
                rx_q[rx_n[15:0]] = rx_b;
                rx_n = rx_n + 1;
            end
        end
    end

    task leer_byte;
        output reg [7:0] dato;
        output reg       ok;
        integer          c;
        begin
            ok = 1'b0;  dato = 8'hxx;
            for (c = 0; c < RESP_WAIT && rx_rd >= rx_n; c = c + 1)
                @(negedge tb_clk);
            if (rx_rd < rx_n) begin
                dato  = rx_q[rx_rd[15:0]];
                rx_rd = rx_rd + 1;
                ok    = 1'b1;
            end
        end
    endtask

    // Petición: A5, cmd, LEN, los primeros npl bytes de pl_buf y el CHK
    reg [7:0] pl_buf [0:4199];

    task peticion;
        input [7:0]   cmd;
        input [15:0]  len;
        input integer npl;
        reg   [7:0]   c;
        integer       i;
        begin
            c = cmd ^ len[7:0] ^ len[15:8];
            serie_tx(8'hA5);
            serie_tx(cmd);
            serie_tx(len[7:0]);
            serie_tx(len[15:8]);
            for (i = 0; i < npl; i = i + 1) begin
                serie_tx(pl_buf[i]);
                c = c ^ pl_buf[i];
            end
            serie_tx(c);
        end
    endtask

    task cmd0;
        input [7:0] cmd;
        begin
            peticion(cmd, 16'd0, 0);
        end
    endtask

    // LOAD de los primeros n words de prog (little-endian)
    reg [31:0] prog [0:WORDS-1];

    task load;
        input integer n;
        integer       i;
        begin
            for (i = 0; i < n; i = i + 1)
                {pl_buf[4*i+3], pl_buf[4*i+2], pl_buf[4*i+1], pl_buf[4*i]} = prog[i];
            peticion(DBG_CMD_LOAD, 4 * n, 4 * n);
        end
    endtask

    // READ_DMEM de count palabras desde addr
    task read_dmem;
        input [31:0] addr;
        input [15:0] count;
        begin
            {pl_buf[3], pl_buf[2], pl_buf[1], pl_buf[0]} = addr;
            {pl_buf[5], pl_buf[4]} = count;
            peticion(DBG_CMD_READ_DMEM, 16'd6, 6);
        end
    endtask

    reg [7:0] resp_buf [0:8447];        // READ_ALL con 1024 palabras usadas: 8400 B
    integer   resp_len;

    task esperar_resp;
        input [8*40-1:0] name;
        input [7:0]      cmd;
        input [7:0]      status;
        input [15:0]     len;
        reg   [7:0]      b;
        reg   [7:0]      c;
        reg              ok;
        integer          i;
        begin
            leer_byte(b, ok);  chk({name, " SOF"},    ok ? b : 32'hDEAD, 8'h5A);
            leer_byte(b, ok);  chk({name, " CMD"},    ok ? b : 32'hDEAD, cmd);     c = b;
            leer_byte(b, ok);  chk({name, " STATUS"}, ok ? b : 32'hDEAD, status);  c = c ^ b;
            leer_byte(b, ok);  resp_len = b;                                       c = c ^ b;
            leer_byte(b, ok);  resp_len = resp_len | (b << 8);                     c = c ^ b;
            chk({name, " LEN"}, resp_len, len);
            if (!ok) resp_len = 0;
            for (i = 0; i < resp_len; i = i + 1) begin
                leer_byte(b, ok);
                resp_buf[i] = b;
                c = c ^ b;
            end
            leer_byte(b, ok);  chk({name, " CHK"}, ok ? b : 32'hDEAD, c);
        end
    endtask

    function [31:0] palabra;            // little-endian desde resp_buf[off]
        input integer off;
        begin
            palabra = {resp_buf[off+3], resp_buf[off+2], resp_buf[off+1], resp_buf[off]};
        end
    endfunction

    // Bloque de estado completo (§3.1) en resp_buf[0 … 11]
    task chk_bloque;
        input [8*40-1:0] name;
        input [2:0]      st;
        input [7:0]      flags;
        input [15:0]     used;
        input [31:0]     pc;
        input [31:0]     cyc;
        begin
            chk({name, ": state"},     resp_buf[0], {5'b0, st});
            chk({name, ": flags"},     resp_buf[1], flags);
            chk({name, ": dmem_used"}, {resp_buf[3], resp_buf[2]}, used);
            chk({name, ": pc"},        palabra(4), pc);
            chk({name, ": cycles"},    palabra(8), cyc);
        end
    endtask

    // RUN hasta HALTED y el EVT_HALTED con su bloque de estado
    task correr;
        input [8*40-1:0] name;
        input [7:0]      flags;
        input [15:0]     used;
        input [31:0]     pc;
        input [31:0]     cyc;
        integer          c;
        begin
            cmd0(DBG_CMD_RUN);
            esperar_resp({name, " RUN"}, DBG_CMD_RUN, DBG_OK, 16'd0);
            for (c = 0; c < 400 && ex_state != DBG_ST_HALTED; c = c + 1)
                @(negedge tb_clk);
            esperar_resp({name, " EVT_HALTED"}, DBG_CMD_EVT_HALTED, DBG_OK, 16'd12);
            chk_bloque({name, " EVT"}, DBG_ST_HALTED, flags, used, pc, cyc);
        end
    endtask

    // Valores esperados: registros y pares (addr, valor) de la memoria usada
    reg [31:0] exp_reg   [0:31];
    reg [31:0] exp_par_a [0:15];
    reg [31:0] exp_par_v [0:15];
    integer    exp_pares;

    task exp_borrar;
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1) exp_reg[i] = 32'h0;
            exp_pares = 0;
        end
    endtask

    task exp_par;
        input [31:0] a;
        input [31:0] v;
        begin
            exp_par_a[exp_pares] = a;
            exp_par_v[exp_pares] = v;
            exp_pares = exp_pares + 1;
        end
    endtask

    // Registros en resp_buf[off …]: del .exp (jer = 0) o del banco por jerarquía
    task chk_regs;
        input [8*40-1:0] name;
        input integer    off;
        input            jer;
        integer          r;
        reg              bien;
        reg [31:0]       e;
        begin
            bien = 1'b1;
            for (r = 0; r < 32; r = r + 1) begin
                if (jer)
                    e = (r == 0) ? 32'h0 : u_core.u_id_stage.u_regfile.regs[r];
                else
                    e = exp_reg[r];
                if (palabra(off + 4*r) !== e) begin
                    bien = 1'b0;
                    if (errors < 40)
                        $display("[%0t]   %0s: x%0d = 0x%0h, esperado 0x%0h",
                                 $time, name, r, palabra(off + 4*r), e);
                end
            end
            chk({name, ": registros"}, bien, 1'b1);
        end
    endtask

    // Latches en resp_buf[off … off+67], contra los campos por jerarquía
    task chk_lat;
        input [8*40-1:0] name;
        input integer    off;
        integer          k;
        reg              bien;
        begin
            bien = 1'b1;
            for (k = 0; k < LEN_LAT; k = k + 1)
                if (resp_buf[off + k] !== h_lat[8*k +: 8]) begin
                    bien = 1'b0;
                    if (errors < 40)
                        $display("[%0t]   %0s: byte %0d = 0x%0h, esperado 0x%0h",
                                 $time, name, k, resp_buf[off + k], h_lat[8*k +: 8]);
                end
            chk({name, ": latches"}, bien, 1'b1);
        end
    endtask

    // Pares en resp_buf[off …], contra exp_par_*
    task chk_pares;
        input [8*40-1:0] name;
        input integer    off;
        integer          p;
        begin
            for (p = 0; p < exp_pares; p = p + 1) begin
                chk({name, ": par addr"},  palabra(off + 8*p),     exp_par_a[p]);
                chk({name, ": par valor"}, palabra(off + 8*p + 4), exp_par_v[p]);
            end
        end
    endtask

    // READ_REGS, READ_DMEM_USED y READ_ALL contra los valores esperados
    task chk_volcado;
        input [8*40-1:0] name;
        input [7:0]      flags;
        input [31:0]     pc;
        input [31:0]     cyc;
        begin
            cmd0(DBG_CMD_READ_REGS);
            esperar_resp({name, " READ_REGS"}, DBG_CMD_READ_REGS, DBG_OK, 16'd128);
            chk_regs({name, " READ_REGS"}, 0, 1'b0);
            cmd0(DBG_CMD_READ_DMEM_USED);
            esperar_resp({name, " READ_DMEM_USED"}, DBG_CMD_READ_DMEM_USED, DBG_OK, 8 * exp_pares);
            chk_pares({name, " READ_DMEM_USED"}, 0);
            cmd0(DBG_CMD_READ_LATCHES);
            esperar_resp({name, " READ_LATCHES"}, DBG_CMD_READ_LATCHES, DBG_OK, LEN_LAT);
            chk_lat({name, " READ_LATCHES"}, 0);
            cmd0(DBG_CMD_READ_ALL);
            esperar_resp({name, " READ_ALL"}, DBG_CMD_READ_ALL, DBG_OK, OFF_PARES + 8 * exp_pares);
            chk_bloque({name, " READ_ALL"}, DBG_ST_HALTED, flags, exp_pares, pc, cyc);
            chk_regs({name, " READ_ALL"}, OFF_REGS, 1'b0);
            chk_lat({name, " READ_ALL"}, OFF_LAT);
            chk_pares({name, " READ_ALL"}, OFF_PARES);
        end
    endtask

    // El mapa vacío después de LOAD o RESET (lo borra o_used_clr)
    task chk_mapa_vacio;
        input [8*40-1:0] name;
        begin
            cmd0(DBG_CMD_READ_DMEM_USED);
            esperar_resp({name, " READ_DMEM_USED"}, DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd0);
            cmd0(DBG_CMD_STATUS);
            esperar_resp({name, " STATUS"}, DBG_CMD_STATUS, DBG_OK, 16'd12);
            chk({name, ": dmem_used = 0"}, {resp_buf[3], resp_buf[2]}, 16'd0);
        end
    endtask

    //==================================================================
    // B. debug_unit y debug_dump sin la UART
    //==================================================================
    reg          b_rst;
    reg  [2:0]   b_state;

    // Bytes de la petición: una cola que debug_unit consume con o_rd
    reg  [7:0]   b_req_q [0:255];       // circular: b_req_n y b_req_rd con [7:0]
    integer      b_req_n;
    integer      b_req_rd;
    wire [7:0]   b_r_data   = b_req_q[b_req_rd[7:0]];
    wire         b_rx_empty = (b_req_rd >= b_req_n);
    wire         b_rd;
    wire [7:0]   b_w_data;
    wire         b_wr;

    always @(posedge tb_clk)
        if (b_rd) b_req_rd = b_req_rd + 1;

    // Bytes de la respuesta: cada o_wr, con i_tx_full = 0
    reg  [7:0]   b_rsp_q [0:16383];     // circular: b_rsp_n y b_rsp_rd con [13:0]
    integer      b_rsp_n;
    integer      b_rsp_rd;

    always @(posedge tb_clk)
        if (b_wr) begin
            b_rsp_q[b_rsp_n[13:0]] = b_w_data;
            b_rsp_n = b_rsp_n + 1;
        end

    wire         b_cmd_valid;
    wire [7:0]   b_cmd;
    wire [31:0]  b_arg_addr;
    wire [15:0]  b_pl_idx;
    wire         b_du_dmem_b_en;
    wire [3:0]   b_du_dmem_b_we;
    wire [9:0]   b_du_dmem_b_addr;
    wire [31:0]  b_du_dmem_b_din;
    wire         b_used_clr;
    wire [7:0]   b_pl_byte;
    wire         b_pl_ready;
    wire [15:0]  b_dmem_used;
    wire         b_dmem_b_en;
    wire [3:0]   b_dmem_b_we;
    wire [9:0]   b_dmem_b_addr;
    wire [31:0]  b_dmem_b_din;
    reg  [31:0]  b_dmem_b_dout;
    wire [4:0]   b_reg_addr;

    // Modelos: dmem (puerto B, lectura de un ciclo, READ_FIRST), banco y latches
    reg  [31:0]  b_dmem [0:WORDS-1];
    reg  [31:0]  b_regs [0:31];
    reg  [64:0]  b_if_id;
    reg  [160:0] b_id_ex;
    reg  [108:0] b_ex_mem;
    reg  [109:0] b_mem_wb;
    reg          b_mark;
    reg  [9:0]   b_mark_addr;
    wire [31:0]  b_reg_data = (b_reg_addr == 5'd0) ? 32'h0 : b_regs[b_reg_addr];

    always @(posedge tb_clk)
        if (b_dmem_b_en) begin
            b_dmem_b_dout <= b_dmem[b_dmem_b_addr];
            if (b_dmem_b_we[0]) b_dmem[b_dmem_b_addr][7:0]   <= b_dmem_b_din[7:0];
            if (b_dmem_b_we[1]) b_dmem[b_dmem_b_addr][15:8]  <= b_dmem_b_din[15:8];
            if (b_dmem_b_we[2]) b_dmem[b_dmem_b_addr][23:16] <= b_dmem_b_din[23:16];
            if (b_dmem_b_we[3]) b_dmem[b_dmem_b_addr][31:24] <= b_dmem_b_din[31:24];
        end

    debug_unit #(
        .CLK_FREQ_HZ       (F_CLK),
        .RX_TIMEOUT_CYCLES (TOUT)
    ) u_du2 (
        .i_clk             (tb_clk),
        .i_rst             (b_rst),
        .i_r_data          (b_r_data),
        .i_rx_empty        (b_rx_empty),
        .o_rd              (b_rd),
        .o_w_data          (b_w_data),
        .o_wr              (b_wr),
        .i_tx_full         (1'b0),
        .i_state           (b_state),
        .i_prog_valid      (1'b1),
        .i_halted          (1'b0),
        .i_imem_fault      (1'b0),
        .i_dmem_oob        (1'b0),
        .i_dmem_misaligned (1'b0),
        .i_dmem_used       (b_dmem_used),
        .i_pc              (32'h0000_0040),
        .i_cycles          (32'd7),
        .i_evt_pending     (1'b0),
        .o_evt_done        (),
        .o_cmd_valid       (b_cmd_valid),
        .o_cmd             (b_cmd),
        .o_arg_addr        (b_arg_addr),
        .o_arg_count       (),
        .o_load_start      (),
        .o_clearing        (),
        .o_imem_b_en       (),
        .o_imem_b_we       (),
        .o_imem_b_addr     (),
        .o_imem_b_din      (),
        .o_dmem_b_en       (b_du_dmem_b_en),
        .o_dmem_b_we       (b_du_dmem_b_we),
        .o_dmem_b_addr     (b_du_dmem_b_addr),
        .o_dmem_b_din      (b_du_dmem_b_din),
        .o_used_clr        (b_used_clr),
        .o_pl_idx          (b_pl_idx),
        .i_pl_byte         (b_pl_byte),
        .i_pl_ready        (b_pl_ready)
    );

    debug_dump u_dump2 (
        .i_clk            (tb_clk),
        .i_rst            (b_rst),
        .i_cmd_valid      (b_cmd_valid),
        .i_cmd            (b_cmd),
        .i_arg_addr       (b_arg_addr),
        .i_pl_idx         (b_pl_idx),
        .o_pl_byte        (b_pl_byte),
        .o_pl_ready       (b_pl_ready),
        .o_dmem_used      (b_dmem_used),
        .i_du_dmem_b_en   (b_du_dmem_b_en),
        .i_du_dmem_b_we   (b_du_dmem_b_we),
        .i_du_dmem_b_addr (b_du_dmem_b_addr),
        .i_du_dmem_b_din  (b_du_dmem_b_din),
        .i_used_clr       (b_used_clr),
        .o_dmem_b_en      (b_dmem_b_en),
        .o_dmem_b_we      (b_dmem_b_we),
        .o_dmem_b_addr    (b_dmem_b_addr),
        .o_dmem_b_din     (b_dmem_b_din),
        .i_dmem_b_dout    (b_dmem_b_dout),
        .i_dmem_we        (b_mark),
        .i_dmem_addr      (b_mark_addr),
        .o_dbg_reg_addr   (b_reg_addr),
        .i_dbg_reg_data   (b_reg_data),
        .i_if_id_latch    (b_if_id),
        .i_id_ex_latch    (b_id_ex),
        .i_ex_mem_latch   (b_ex_mem),
        .i_mem_wb_latch   (b_mem_wb)
    );

    wire [8*LEN_LAT-1:0] b_lat = {{(128-110){1'b0}}, b_mem_wb,
                                  {(128-109){1'b0}}, b_ex_mem,
                                  {(192-161){1'b0}}, b_id_ex,
                                  {(96-65){1'b0}},   b_if_id};

    // Monitor: ningún byte de una lectura sale con i_pl_ready = 0, y los
    // ciclos de TX_PAYLOAD de una lectura que espera a i_pl_ready
    integer b_tx_sin_ready;
    integer b_espera;

    wire b_externo = (u_du2.state_reg == 4'd10) & is_lectura(b_cmd) &
                     ~((b_cmd == DBG_CMD_READ_ALL) & (b_pl_idx < 16'd12));

    always @(posedge tb_clk) begin
        if (b_wr && b_externo && (!b_pl_ready || b_w_data !== b_pl_byte))
            b_tx_sin_ready = b_tx_sin_ready + 1;
        if (b_externo && !b_pl_ready)
            b_espera = b_espera + 1;
    end

    // Petición: SOF, cmd, LEN, los primeros npl bytes de pl_buf y el CHK
    task b_peticion;
        input [7:0]   cmd;
        input [15:0]  len;
        input integer npl;
        reg   [7:0]   c;
        integer       i;
        begin
            @(negedge tb_clk);
            c = cmd ^ len[7:0] ^ len[15:8];
            b_req_q[b_req_n[7:0]] = 8'hA5;      b_req_n = b_req_n + 1;
            b_req_q[b_req_n[7:0]] = cmd;        b_req_n = b_req_n + 1;
            b_req_q[b_req_n[7:0]] = len[7:0];   b_req_n = b_req_n + 1;
            b_req_q[b_req_n[7:0]] = len[15:8];  b_req_n = b_req_n + 1;
            for (i = 0; i < npl; i = i + 1) begin
                b_req_q[b_req_n[7:0]] = pl_buf[i];  b_req_n = b_req_n + 1;
                c = c ^ pl_buf[i];
            end
            b_req_q[b_req_n[7:0]] = c;          b_req_n = b_req_n + 1;
        end
    endtask

    task b_leer_byte;
        output reg [7:0] dato;
        output reg       ok;
        integer          c;
        begin
            ok = 1'b0;  dato = 8'hxx;
            for (c = 0; c < B_WAIT && b_rsp_rd >= b_rsp_n; c = c + 1)
                @(negedge tb_clk);
            if (b_rsp_rd < b_rsp_n) begin
                dato     = b_rsp_q[b_rsp_rd[13:0]];
                b_rsp_rd = b_rsp_rd + 1;
                ok       = 1'b1;
            end
        end
    endtask

    // Respuesta en resp_buf, como esperar_resp; b_espera cuenta desde acá
    task b_resp;
        input [8*40-1:0] name;
        input [7:0]      cmd;
        input [7:0]      status;
        input [15:0]     len;
        reg   [7:0]      b;
        reg   [7:0]      c;
        reg              ok;
        integer          i;
        begin
            b_leer_byte(b, ok);  chk({name, " SOF"},    ok ? b : 32'hDEAD, 8'h5A);
            b_leer_byte(b, ok);  chk({name, " CMD"},    ok ? b : 32'hDEAD, cmd);     c = b;
            b_leer_byte(b, ok);  chk({name, " STATUS"}, ok ? b : 32'hDEAD, status);  c = c ^ b;
            b_leer_byte(b, ok);  resp_len = b;                                       c = c ^ b;
            b_leer_byte(b, ok);  resp_len = resp_len | (b << 8);                     c = c ^ b;
            chk({name, " LEN"}, resp_len, len);
            if (!ok) resp_len = 0;
            for (i = 0; i < resp_len; i = i + 1) begin
                b_leer_byte(b, ok);
                resp_buf[i] = b;
                c = c ^ b;
            end
            b_leer_byte(b, ok);  chk({name, " CHK"}, ok ? b : 32'hDEAD, c);
        end
    endtask

    task b_cmd0;
        input [7:0] cmd;
        begin
            b_espera = 0;
            b_peticion(cmd, 16'd0, 0);
        end
    endtask

    task b_read_dmem;
        input [31:0] addr;
        input [15:0] count;
        begin
            b_espera = 0;
            {pl_buf[3], pl_buf[2], pl_buf[1], pl_buf[0]} = addr;
            {pl_buf[5], pl_buf[4]} = count;
            b_peticion(DBG_CMD_READ_DMEM, 16'd6, 6);
        end
    endtask

    // Marca la palabra a en el mapa: un ciclo con i_dmem_we = 1
    task b_marcar;
        input [9:0] a;
        begin
            @(negedge tb_clk);
            b_mark = 1'b1;  b_mark_addr = a;
            @(negedge tb_clk);
            b_mark = 1'b0;
        end
    endtask

    // Pares (4a, b_dmem[a]) de las palabras con b_used[a] = 1, en orden
    reg     b_used [0:WORDS-1];
    integer b_n_used;

    task b_chk_pares;
        input [8*40-1:0] name;
        input integer    off;
        integer          a, p;
        reg              bien;
        begin
            bien = 1'b1;  p = 0;
            for (a = 0; a < WORDS; a = a + 1)
                if (b_used[a]) begin
                    if (palabra(off + 8*p) !== 4*a || palabra(off + 8*p + 4) !== b_dmem[a]) begin
                        bien = 1'b0;
                        if (errors < 40)
                            $display("[%0t]   %0s: par %0d = (0x%0h, 0x%0h), esperado (0x%0h, 0x%0h)",
                                     $time, name, p, palabra(off + 8*p), palabra(off + 8*p + 4),
                                     4*a, b_dmem[a]);
                    end
                    p = p + 1;
                end
            chk({name, ": pares"}, bien, 1'b1);
        end
    endtask

    task b_chk_regs;
        input [8*40-1:0] name;
        input integer    off;
        integer          r;
        reg              bien;
        begin
            bien = 1'b1;
            for (r = 0; r < 32; r = r + 1)
                if (palabra(off + 4*r) !== ((r == 0) ? 32'h0 : b_regs[r])) bien = 1'b0;
            chk({name, ": registros"}, bien, 1'b1);
        end
    endtask

    task b_chk_lat;
        input [8*40-1:0] name;
        input integer    off;
        integer          k;
        reg              bien;
        begin
            bien = 1'b1;
            for (k = 0; k < LEN_LAT; k = k + 1)
                if (resp_buf[off + k] !== b_lat[8*k +: 8]) bien = 1'b0;
            chk({name, ": latches"}, bien, 1'b1);
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    integer    i, k, s, n0, seed, tmp;
    integer    perm [0:WORDS-1];
    reg [31:0] v;
    reg        bien, vio_stall, vio_redirect, vio_valid;
    reg [7:0]  all_buf [0:1023];
    integer    all_len;

    initial begin
        errors = 0;  checks = 0;  seed = SEED;
        a_tx_sin_ready = 0;  a_b_con_core = 0;  a_espera = 0;  b_tx_sin_ready = 0;  b_espera = 0;
        tb_rst = 1'b1;  tb_rx = 1'b1;
        b_rst = 1'b1;  b_state = DBG_ST_PAUSED;  b_mark = 1'b0;  b_mark_addr = 10'd0;
        b_req_n = 0;  b_req_rd = 0;  b_rsp_n = 0;  b_rsp_rd = 0;
        for (i = 0; i < WORDS; i = i + 1) begin
            sh_used[i] = 1'b0;
            b_used[i]  = 1'b0;
            b_dmem[i]  = 32'hxxxx_xxxx;
        end
        for (i = 0; i < 32; i = i + 1)
            b_regs[i] = (32'h0101_0101 * i) ^ 32'hA5C3_0000;
        b_if_id  = {$random(seed), $random(seed), $random(seed)};
        b_id_ex  = {$random(seed), $random(seed), $random(seed), $random(seed),
                    $random(seed), $random(seed)};
        b_ex_mem = {$random(seed), $random(seed), $random(seed), $random(seed)};
        b_mem_wb = {$random(seed), $random(seed), $random(seed), $random(seed)};
        repeat (4) @(negedge tb_clk);
        tb_rst = 1'b0;  b_rst = 1'b0;
        repeat (4) @(negedge tb_clk);

        //==============================================================
        // B. Sin la UART
        //==============================================================
        // Después del reset dmem_used = 0, aunque el mapa no se resetea
        chk("B reset: dmem_used", b_dmem_used, 16'd0);
        b_cmd0(DBG_CMD_READ_DMEM_USED);
        b_resp("B reset READ_DMEM_USED", DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd0);

        // RESET: CLEAR pone dmem en 0 por el multiplexor del puerto B
        b_cmd0(DBG_CMD_RESET);
        b_resp("B RESET", DBG_CMD_RESET, DBG_OK, 16'd12);
        bien = 1'b1;
        for (i = 0; i < WORDS; i = i + 1) if (b_dmem[i] !== 32'h0) bien = 1'b0;
        chk("B RESET: dmem en 0", bien, 1'b1);
        chk("B RESET: dmem_used", b_dmem_used, 16'd0);
        @(negedge tb_clk);
        for (i = 0; i < WORDS; i = i + 1)
            b_dmem[i] = {i[9:0], 6'b10_1101, ~i[7:0], 8'h3C} ^ (32'h0001_0001 * i);

        // READ_REGS, READ_LATCHES y READ_DMEM: hasta 2 ciclos por byte
        b_cmd0(DBG_CMD_READ_REGS);
        b_resp("B READ_REGS", DBG_CMD_READ_REGS, DBG_OK, 16'd128);
        b_chk_regs("B READ_REGS", 0);
        chk("B READ_REGS: <= 2 ciclos por byte", b_espera <= 2 * 128, 1'b1);
        b_cmd0(DBG_CMD_READ_LATCHES);
        b_resp("B READ_LATCHES", DBG_CMD_READ_LATCHES, DBG_OK, LEN_LAT);
        b_chk_lat("B READ_LATCHES", 0);
        chk("B READ_LATCHES: <= 2 ciclos por byte", b_espera <= 2 * LEN_LAT, 1'b1);
        b_read_dmem(32'h0, 16'd1024);
        b_resp("B READ_DMEM 1024", DBG_CMD_READ_DMEM, DBG_OK, 16'd4096);
        bien = 1'b1;
        for (i = 0; i < WORDS; i = i + 1) if (palabra(4*i) !== b_dmem[i]) bien = 1'b0;
        chk("B READ_DMEM 1024: contenido", bien, 1'b1);
        chk("B READ_DMEM 1024: <= 2 ciclos por byte", b_espera <= 2 * 4096, 1'b1);
        b_read_dmem(32'hFFC, 16'd1);
        b_resp("B READ_DMEM ultima", DBG_CMD_READ_DMEM, DBG_OK, 16'd4);
        chk("B READ_DMEM ultima: valor", palabra(0), b_dmem[1023]);
        b_read_dmem(32'h10, 16'd3);
        b_resp("B READ_DMEM 0x10", DBG_CMD_READ_DMEM, DBG_OK, 16'd12);
        chk("B READ_DMEM 0x10: palabra 4", palabra(0), b_dmem[4]);
        chk("B READ_DMEM 0x10: palabra 5", palabra(4), b_dmem[5]);
        chk("B READ_DMEM 0x10: palabra 6", palabra(8), b_dmem[6]);

        // Peor caso de la búsqueda: solo la palabra 1023
        b_marcar(10'd1023);  b_used[1023] = 1'b1;
        chk("B 1023: dmem_used", b_dmem_used, 16'd1);
        b_cmd0(DBG_CMD_READ_DMEM_USED);
        b_resp("B 1023 READ_DMEM_USED", DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd8);
        b_chk_pares("B 1023", 0);
        chk("B 1023: espera la busqueda", b_espera >= 1000, 1'b1);

        // Las palabras 0 y 1023: el segundo par espera la búsqueda; marcar
        // otra vez una palabra no cuenta
        b_marcar(10'd0);  b_used[0] = 1'b1;
        b_marcar(10'd1023);
        b_marcar(10'd0);
        chk("B 0 y 1023: dmem_used", b_dmem_used, 16'd2);
        b_cmd0(DBG_CMD_READ_DMEM_USED);
        b_resp("B 0 y 1023 READ_DMEM_USED", DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd16);
        b_chk_pares("B 0 y 1023", 0);
        chk("B 0 y 1023: espera la busqueda", b_espera >= 1000, 1'b1);
        b_cmd0(DBG_CMD_READ_ALL);
        b_resp("B 0 y 1023 READ_ALL", DBG_CMD_READ_ALL, DBG_OK, OFF_PARES + 16);
        chk("B 0 y 1023 READ_ALL: dmem_used", {resp_buf[3], resp_buf[2]}, 16'd2);
        b_chk_regs("B 0 y 1023 READ_ALL", OFF_REGS);
        b_chk_lat("B 0 y 1023 READ_ALL", OFF_LAT);
        b_chk_pares("B 0 y 1023 READ_ALL", OFF_PARES);

        // Las 1024 palabras, marcadas en orden aleatorio (semilla fija)
        for (i = 0; i < WORDS; i = i + 1) perm[i] = i;
        for (i = WORDS - 1; i > 0; i = i - 1) begin
            k = {$random(seed)} % (i + 1);
            tmp = perm[i];  perm[i] = perm[k];  perm[k] = tmp;
        end
        for (i = 0; i < WORDS; i = i + 1) begin
            b_marcar(perm[i]);  b_used[perm[i]] = 1'b1;
        end
        chk("B 1024: dmem_used", b_dmem_used, 16'd1024);
        b_cmd0(DBG_CMD_STATUS);
        b_resp("B 1024 STATUS", DBG_CMD_STATUS, DBG_OK, 16'd12);
        chk("B 1024 STATUS: dmem_used", {resp_buf[3], resp_buf[2]}, 16'd1024);
        b_cmd0(DBG_CMD_READ_DMEM_USED);
        b_resp("B 1024 READ_DMEM_USED", DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd8192);
        b_chk_pares("B 1024", 0);
        b_cmd0(DBG_CMD_READ_ALL);
        b_resp("B 1024 READ_ALL", DBG_CMD_READ_ALL, DBG_OK, 16'd8400);
        b_chk_regs("B 1024 READ_ALL", OFF_REGS);
        b_chk_lat("B 1024 READ_ALL", OFF_LAT);
        b_chk_pares("B 1024 READ_ALL", OFF_PARES);

        // RESET: CLEAR borra el mapa y dmem
        b_cmd0(DBG_CMD_RESET);
        b_resp("B RESET 2", DBG_CMD_RESET, DBG_OK, 16'd12);
        chk("B RESET 2: dmem_used", b_dmem_used, 16'd0);
        for (i = 0; i < WORDS; i = i + 1) b_used[i] = 1'b0;
        b_cmd0(DBG_CMD_READ_DMEM_USED);
        b_resp("B RESET 2 READ_DMEM_USED", DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd0);
        b_marcar(10'd77);  b_used[77] = 1'b1;
        chk("B RESET 2: una marca", b_dmem_used, 16'd1);
        b_cmd0(DBG_CMD_READ_DMEM_USED);
        b_resp("B RESET 2 una marca", DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd8);
        b_chk_pares("B RESET 2 una marca", 0);

        // i_rst pone dmem_used en 0
        @(negedge tb_clk);
        b_rst = 1'b1;
        repeat (2) @(negedge tb_clk);
        b_rst = 1'b0;
        @(negedge tb_clk);
        chk("B i_rst: dmem_used", b_dmem_used, 16'd0);
        b_cmd0(DBG_CMD_READ_DMEM_USED);
        b_resp("B i_rst READ_DMEM_USED", DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd0);

        chk("B: bytes con i_pl_ready = 0", b_tx_sin_ready, 0);

        //==============================================================
        // A. Sistema por la línea serie
        //==============================================================
        chk("A reset: NO_PROG", ex_state, DBG_ST_NO_PROG);
        // dmem_used = 0 antes del primer CLEAR, aunque el mapa no se resetea
        chk_mapa_vacio("A NO_PROG");

        //--------------------------------------------------------------
        // mem_byte_media (sw/mem_byte_media.exp): sb y sh marcan la palabra
        //--------------------------------------------------------------
        prog[0]  = 32'hf8100093;     // addi x1, x0, -127
        prog[1]  = 32'h07e00113;     // addi x2, x0, 0x7E
        prog[2]  = 32'h5f000193;     // addi x3, x0, 0x5F0
        prog[3]  = 32'h70500213;     // addi x4, x0, 0x705
        prog[4]  = 32'h00f00293;     // addi x5, x0, 0x0F
        prog[5]  = 32'hffa00313;     // addi x6, x0, -6
        prog[6]  = 32'h112233b7;     // lui  x7, 0x11223
        prog[7]  = 32'hffff8437;     // lui  x8, 0xFFFF8
        prog[8]  = 32'h000084b7;     // lui  x9, 8
        prog[9]  = 32'h34438393;     // addi x7, x7, 0x344
        prog[10] = 32'h00140413;     // addi x8, x8, 1
        prog[11] = 32'hffe48493;     // addi x9, x9, -2
        prog[12] = 32'h10100023;     // sb   x1, 0x100(x0)
        prog[13] = 32'h102000a3;     // sb   x2, 0x101(x0)
        prog[14] = 32'h10300123;     // sb   x3, 0x102(x0)
        prog[15] = 32'h104001a3;     // sb   x4, 0x103(x0)
        prog[16] = 32'h10200223;     // sb   x2, 0x104(x0)
        prog[17] = 32'h101002a3;     // sb   x1, 0x105(x0)
        prog[18] = 32'h10500323;     // sb   x5, 0x106(x0)
        prog[19] = 32'h106003a3;     // sb   x6, 0x107(x0)
        prog[20] = 32'h10801423;     // sh   x8, 0x108(x0)
        prog[21] = 32'h10901523;     // sh   x9, 0x10A(x0)
        prog[22] = 32'h10702623;     // sw   x7, 0x10C(x0)
        prog[23] = 32'h101006a3;     // sb   x1, 0x10D(x0)
        prog[24] = 32'h10c02503;     // lw   x10, 0x10C(x0)
        prog[25] = 32'h10901723;     // sh   x9, 0x10E(x0)
        prog[26] = 32'h10000583;     // lb   x11, 0x100(x0)
        prog[27] = 32'h10100603;     // lb   x12, 0x101(x0)
        prog[28] = 32'h10200683;     // lb   x13, 0x102(x0)
        prog[29] = 32'h10300703;     // lb   x14, 0x103(x0)
        prog[30] = 32'h10400783;     // lb   x15, 0x104(x0)
        prog[31] = 32'h10500803;     // lb   x16, 0x105(x0)
        prog[32] = 32'h10600883;     // lb   x17, 0x106(x0)
        prog[33] = 32'h10700903;     // lb   x18, 0x107(x0)
        prog[34] = 32'h10004983;     // lbu  x19, 0x100(x0)
        prog[35] = 32'h10104a03;     // lbu  x20, 0x101(x0)
        prog[36] = 32'h10204a83;     // lbu  x21, 0x102(x0)
        prog[37] = 32'h10304b03;     // lbu  x22, 0x103(x0)
        prog[38] = 32'h10404b83;     // lbu  x23, 0x104(x0)
        prog[39] = 32'h10504c03;     // lbu  x24, 0x105(x0)
        prog[40] = 32'h10604c83;     // lbu  x25, 0x106(x0)
        prog[41] = 32'h10704d03;     // lbu  x26, 0x107(x0)
        prog[42] = 32'h10001d83;     // lh   x27, 0x100(x0)
        prog[43] = 32'h10201e03;     // lh   x28, 0x102(x0)
        prog[44] = 32'h10401e83;     // lh   x29, 0x104(x0)
        prog[45] = 32'h10601f03;     // lh   x30, 0x106(x0)
        prog[46] = 32'h10801f83;     // lh   x31, 0x108(x0)
        prog[47] = 32'h10a01083;     // lh   x1, 0x10A(x0)
        prog[48] = 32'h10005103;     // lhu  x2, 0x100(x0)
        prog[49] = 32'h10405183;     // lhu  x3, 0x104(x0)
        prog[50] = 32'h10605203;     // lhu  x4, 0x106(x0)
        prog[51] = 32'h10805283;     // lhu  x5, 0x108(x0)
        prog[52] = 32'h10205303;     // lhu  x6, 0x102(x0)
        prog[53] = 32'h00100073;     // halt
        load(54);
        esperar_resp("mem_byte_media LOAD", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_bloque("mem_byte_media LOAD", DBG_ST_READY, 8'h01, 16'd0, 32'h0, 32'h0);
        exp_borrar;
        exp_reg[1]  = 32'h00007FFE;  exp_reg[2]  = 32'h00007E81;  exp_reg[3]  = 32'h0000817E;
        exp_reg[4]  = 32'h0000FA0F;  exp_reg[5]  = 32'h00008001;  exp_reg[6]  = 32'h000005F0;
        exp_reg[7]  = 32'h11223344;  exp_reg[8]  = 32'hFFFF8001;  exp_reg[9]  = 32'h00007FFE;
        exp_reg[10] = 32'h11228144;  exp_reg[11] = 32'hFFFFFF81;  exp_reg[12] = 32'h0000007E;
        exp_reg[13] = 32'hFFFFFFF0;  exp_reg[14] = 32'h00000005;  exp_reg[15] = 32'h0000007E;
        exp_reg[16] = 32'hFFFFFF81;  exp_reg[17] = 32'h0000000F;  exp_reg[18] = 32'hFFFFFFFA;
        exp_reg[19] = 32'h00000081;  exp_reg[20] = 32'h0000007E;  exp_reg[21] = 32'h000000F0;
        exp_reg[22] = 32'h00000005;  exp_reg[23] = 32'h0000007E;  exp_reg[24] = 32'h00000081;
        exp_reg[25] = 32'h0000000F;  exp_reg[26] = 32'h000000FA;  exp_reg[27] = 32'h00007E81;
        exp_reg[28] = 32'h000005F0;  exp_reg[29] = 32'hFFFF817E;  exp_reg[30] = 32'hFFFFFA0F;
        exp_reg[31] = 32'hFFFF8001;
        exp_par(32'h100, 32'h05F07E81);
        exp_par(32'h104, 32'hFA0F817E);
        exp_par(32'h108, 32'h7FFE8001);
        exp_par(32'h10C, 32'h7FFE8144);
        // HALT en 0xD4: PC = 0xD8, 54 + 4 = 58 ciclos
        correr("mem_byte_media", 8'h03, 16'd4, 32'hD8, 32'd58);
        chk_volcado("mem_byte_media", 8'h03, 32'hD8, 32'd58);

        //--------------------------------------------------------------
        // mem_avisos (sw/mem_avisos.exp): el store fuera de rango marca su
        // alias, y los pares salen en orden aunque se escriban desordenados
        //--------------------------------------------------------------
        prog[0]  = 32'h123451b7;     // lui  x3, 0x12345
        prog[1]  = 32'h05500093;     // addi x1, x0, 0x55
        prog[2]  = 32'h00001137;     // lui  x2, 1
        prog[3]  = 32'h00302023;     // sw   x3, 0(x0)      dmem[0x000]
        prog[4]  = 32'h001015a3;     // sh   x1, 0xB(x0)    0x00A: dmem[0x008] (desalineado)
        prog[5]  = 32'h00112223;     // sw   x1, 4(x2)      0x1004: dmem[0x004] (alias)
        prog[6]  = 32'h00302503;     // lw   x10, 3(x0)
        prog[7]  = 32'h00412583;     // lw   x11, 4(x2)
        prog[8]  = 32'h00101603;     // lh   x12, 1(x0)
        prog[9]  = 32'h03010067;     // jalr x0, 0x30(x2)   a 0x1030 (alias de 0x030)
        prog[10] = 32'h00000013;     // nop
        prog[11] = 32'h00000013;     // nop
        prog[12] = 32'h00100073;     // halt                0x030
        load(13);
        esperar_resp("mem_avisos LOAD", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_mapa_vacio("mem_avisos LOAD");
        exp_borrar;
        exp_reg[1]  = 32'h00000055;  exp_reg[2]  = 32'h00001000;  exp_reg[3]  = 32'h12345000;
        exp_reg[10] = 32'h12345000;  exp_reg[11] = 32'h00000055;  exp_reg[12] = 32'h00005000;
        exp_par(32'h000, 32'h12345000);
        exp_par(32'h004, 32'h00000055);
        exp_par(32'h008, 32'h00550000);
        // HALT buscado en 0x1030: PC = 0x1034; 11 + 4 + 2 = 17 ciclos; los
        // tres avisos (flags = 0x1F)
        correr("mem_avisos", 8'h1F, 16'd3, 32'h1034, 32'd17);
        chk_volcado("mem_avisos", 8'h1F, 32'h1034, 32'd17);

        // READ_DMEM: el ejemplo de §4, la memoria entera y ERR_ADDR
        read_dmem(32'h10, 16'd4);
        esperar_resp("READ_DMEM 0x10", DBG_CMD_READ_DMEM, DBG_OK, 16'd16);
        for (i = 0; i < 4; i = i + 1)
            chk("READ_DMEM 0x10: en 0", palabra(4*i), 32'h0);
        read_dmem(32'h0, 16'd1024);
        esperar_resp("READ_DMEM 1024", DBG_CMD_READ_DMEM, DBG_OK, 16'd4096);
        bien = 1'b1;
        for (i = 3; i < WORDS; i = i + 1) if (palabra(4*i) !== 32'h0) bien = 1'b0;
        chk("READ_DMEM 1024: dmem[0x000]", palabra(0), 32'h12345000);
        chk("READ_DMEM 1024: dmem[0x004]", palabra(4), 32'h00000055);
        chk("READ_DMEM 1024: dmem[0x008]", palabra(8), 32'h00550000);
        chk("READ_DMEM 1024: el resto en 0", bien, 1'b1);
        read_dmem(32'h2, 16'd1);
        esperar_resp("READ_DMEM desalineada", DBG_CMD_READ_DMEM, DBG_ERR_ADDR, 16'd0);
        read_dmem(32'h0, 16'd0);
        esperar_resp("READ_DMEM count 0", DBG_CMD_READ_DMEM, DBG_ERR_ADDR, 16'd0);
        read_dmem(32'hFFC, 16'd2);
        esperar_resp("READ_DMEM se sale", DBG_CMD_READ_DMEM, DBG_ERR_ADDR, 16'd0);
        read_dmem(32'hFFFF_FFFC, 16'd2);
        esperar_resp("READ_DMEM da la vuelta", DBG_CMD_READ_DMEM, DBG_ERR_ADDR, 16'd0);

        //--------------------------------------------------------------
        // usadas_orden: dos escrituras cuentan una, un cero escrito aparece,
        // un load no marca, y las palabras 0 y 1023
        //--------------------------------------------------------------
        prog[0] = 32'h00001137;      // lui  x2, 1           x2 = 0x1000
        prog[1] = 32'h00700093;      // addi x1, x0, 7       x1 = 7
        prog[2] = 32'hfe112e23;      // sw   x1, -4(x2)      dmem[0xFFC] = 7
        prog[3] = 32'h02002023;      // sw   x0, 0x20(x0)    dmem[0x020] = 0
        prog[4] = 32'h00102023;      // sw   x1, 0(x0)       dmem[0x000] = 7
        prog[5] = 32'h021000a3;      // sb   x1, 0x21(x0)    dmem[0x020] = 0x00000700
        prog[6] = 32'h04002183;      // lw   x3, 0x40(x0)    x3 = 0, sin marca
        prog[7] = 32'h00101123;      // sh   x1, 2(x0)       dmem[0x000] = 0x00070007
        prog[8] = 32'h00100073;      // halt
        load(9);
        esperar_resp("usadas_orden LOAD", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_mapa_vacio("usadas_orden LOAD");
        exp_borrar;
        exp_reg[1] = 32'd7;  exp_reg[2] = 32'h1000;
        exp_par(32'h000, 32'h00070007);
        exp_par(32'h020, 32'h00000700);
        exp_par(32'hFFC, 32'h00000007);
        // HALT en 0x20: PC = 0x24, 9 + 4 = 13 ciclos
        correr("usadas_orden", 8'h03, 16'd3, 32'h24, 32'd13);
        // El tercer par busca de la palabra 9 a la 1023 (~1015 ciclos) con
        // un byte serie de tiempo (320): i_pl_ready frena el envío
        a_espera = 0;
        cmd0(DBG_CMD_READ_DMEM_USED);
        esperar_resp("usadas_orden espera", DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd24);
        chk_pares("usadas_orden espera", 0);
        $display("[%0t] usadas_orden: %0d ciclos esperando i_pl_ready", $time, a_espera);
        chk("usadas_orden: espera la busqueda", a_espera >= 500, 1'b1);
        chk_volcado("usadas_orden", 8'h03, 32'h24, 32'd13);
        read_dmem(32'hFFC, 16'd1);
        esperar_resp("READ_DMEM ultima", DBG_CMD_READ_DMEM, DBG_OK, 16'd4);
        chk("READ_DMEM ultima: dmem[0xFFC]", palabra(0), 32'd7);

        // RESET después de un volcado: CLEAR limpia dmem y el mapa, y el
        // programa vuelve a dejar los mismos pares
        cmd0(DBG_CMD_RESET);
        esperar_resp("usadas_orden RESET", DBG_CMD_RESET, DBG_OK, 16'd12);
        chk_mapa_vacio("usadas_orden RESET");
        read_dmem(32'h0, 16'd1024);
        esperar_resp("RESET READ_DMEM 1024", DBG_CMD_READ_DMEM, DBG_OK, 16'd4096);
        bien = 1'b1;
        for (i = 0; i < WORDS; i = i + 1) if (palabra(4*i) !== 32'h0) bien = 1'b0;
        chk("RESET READ_DMEM 1024: todo en 0", bien, 1'b1);
        correr("usadas_orden otra vez", 8'h03, 16'd3, 32'h24, 32'd13);
        chk_volcado("usadas_orden otra vez", 8'h03, 32'h24, 32'd13);

        //--------------------------------------------------------------
        // solo_1023: el peor caso de la búsqueda por la línea serie
        //--------------------------------------------------------------
        prog[0] = 32'h02a00093;      // addi x1, x0, 42      x1 = 42
        prog[1] = 32'h00001137;      // lui  x2, 1           x2 = 0x1000
        prog[2] = 32'hfe112e23;      // sw   x1, -4(x2)      dmem[0xFFC] = 42
        prog[3] = 32'h00100073;      // halt
        load(4);
        esperar_resp("solo_1023 LOAD", DBG_CMD_LOAD, DBG_OK, 16'd12);
        exp_borrar;
        exp_reg[1] = 32'd42;  exp_reg[2] = 32'h1000;
        exp_par(32'hFFC, 32'd42);
        correr("solo_1023", 8'h03, 16'd1, 32'h10, 32'd8);
        chk_volcado("solo_1023", 8'h03, 32'h10, 32'd8);

        //--------------------------------------------------------------
        // paso_riesgos: READ_ALL después de cada STEP, con un stall de
        // carga-uso y un salto tomado; latches bit a bit por jerarquía
        //--------------------------------------------------------------
        prog[0] = 32'h00500093;      // addi x1, x0, 5       x1 = 5
        prog[1] = 32'h00102823;      // sw   x1, 0x10(x0)    dmem[0x010] = 5
        prog[2] = 32'h01002103;      // lw   x2, 0x10(x0)    x2 = 5
        prog[3] = 32'h001101b3;      // add  x3, x2, x1      carga-uso: x3 = 10
        prog[4] = 32'h00318663;      // beq  x3, x3, salto   tomado
        prog[5] = 32'hfff00f93;      // addi x31, x0, -1     camino equivocado
        prog[6] = 32'hfff00f93;      // addi x31, x0, -1     camino equivocado
        prog[7] = 32'h00302a23;      // salto: sw x3, 0x14(x0)  dmem[0x014] = 10
        prog[8] = 32'h00100073;      // halt
        load(9);
        esperar_resp("paso_riesgos LOAD", DBG_CMD_LOAD, DBG_OK, 16'd12);
        vio_stall = 1'b0;  vio_redirect = 1'b0;  vio_valid = 1'b0;
        // 7 instrucciones + 4 + 1 de stall + 2 del salto = 14 ciclos
        for (s = 1; s <= 14; s = s + 1) begin
            cmd0(DBG_CMD_STEP);
            esperar_resp("paso_riesgos STEP", DBG_CMD_STEP, DBG_OK, 16'd12);
            chk("paso_riesgos STEP: cycles", palabra(8), s);
            chk("paso_riesgos STEP: state", resp_buf[0],
                (s == 14) ? {5'b0, DBG_ST_HALTED} : {5'b0, DBG_ST_PAUSED});
            vio_stall    = vio_stall    | u_core.stall;
            vio_redirect = vio_redirect | u_core.redirect;
            vio_valid    = vio_valid    | u_core.if_id_valid | u_core.id_ex_valid |
                                          u_core.ex_mem_valid | u_core.mem_wb_valid;
            // Pares esperados: la copia del mapa; dmem[4] = 5 y dmem[5] = 10
            exp_pares = 0;
            for (i = 0; i < WORDS; i = i + 1)
                if (sh_used[i]) exp_par(4*i, (i == 4) ? 32'd5 : (i == 5) ? 32'd10 : 32'hBAD);
            cmd0(DBG_CMD_READ_ALL);
            esperar_resp("paso_riesgos READ_ALL", DBG_CMD_READ_ALL, DBG_OK, OFF_PARES + 8 * exp_pares);
            chk_bloque("paso_riesgos READ_ALL", (s == 14) ? DBG_ST_HALTED : DBG_ST_PAUSED,
                       (s == 14) ? 8'h03 : 8'h01, exp_pares, core_pc, s);
            chk_regs("paso_riesgos READ_ALL", OFF_REGS, 1'b1);
            chk_lat("paso_riesgos READ_ALL", OFF_LAT);
            chk_pares("paso_riesgos READ_ALL", OFF_PARES);
            // En el paso 7, READ_ALL es la concatenación de las lecturas sueltas
            if (s == 7) begin
                all_len = resp_len;
                for (i = 0; i < resp_len; i = i + 1) all_buf[i] = resp_buf[i];
                cmd0(DBG_CMD_STATUS);
                esperar_resp("paso 7 STATUS", DBG_CMD_STATUS, DBG_OK, 16'd12);
                bien = 1'b1;
                for (i = 0; i < 12; i = i + 1) if (resp_buf[i] !== all_buf[i]) bien = 1'b0;
                chk("paso 7: estado = READ_ALL", bien, 1'b1);
                cmd0(DBG_CMD_READ_REGS);
                esperar_resp("paso 7 READ_REGS", DBG_CMD_READ_REGS, DBG_OK, 16'd128);
                bien = 1'b1;
                for (i = 0; i < 128; i = i + 1) if (resp_buf[i] !== all_buf[OFF_REGS + i]) bien = 1'b0;
                chk("paso 7: READ_REGS = READ_ALL", bien, 1'b1);
                cmd0(DBG_CMD_READ_LATCHES);
                esperar_resp("paso 7 READ_LATCHES", DBG_CMD_READ_LATCHES, DBG_OK, LEN_LAT);
                bien = 1'b1;
                for (i = 0; i < LEN_LAT; i = i + 1) if (resp_buf[i] !== all_buf[OFF_LAT + i]) bien = 1'b0;
                chk("paso 7: READ_LATCHES = READ_ALL", bien, 1'b1);
                cmd0(DBG_CMD_READ_DMEM_USED);
                esperar_resp("paso 7 READ_DMEM_USED", DBG_CMD_READ_DMEM_USED, DBG_OK, all_len - OFF_PARES);
                bien = 1'b1;
                for (i = 0; i < all_len - OFF_PARES; i = i + 1)
                    if (resp_buf[i] !== all_buf[OFF_PARES + i]) bien = 1'b0;
                chk("paso 7: READ_DMEM_USED = READ_ALL", bien, 1'b1);
            end
        end
        chk("paso_riesgos: hubo stall", vio_stall, 1'b1);
        chk("paso_riesgos: hubo salto tomado", vio_redirect, 1'b1);
        chk("paso_riesgos: latches con instrucciones", vio_valid, 1'b1);
        chk("paso_riesgos: x3", u_core.u_id_stage.u_regfile.regs[3], 32'd10);
        chk("paso_riesgos: x31 sin camino equivocado", u_core.u_id_stage.u_regfile.regs[31], 32'd0);
        chk("paso_riesgos: dos palabras usadas", exp_pares, 2);

        //--------------------------------------------------------------
        // Lecturas en RUNNING: ERR_STATE; después de STOP, OK
        //--------------------------------------------------------------
        prog[0] = 32'h0000_006F;     // jal x0, 0           bucle infinito
        load(1);
        esperar_resp("bucle LOAD", DBG_CMD_LOAD, DBG_OK, 16'd12);
        cmd0(DBG_CMD_RUN);
        esperar_resp("bucle RUN", DBG_CMD_RUN, DBG_OK, 16'd0);
        cmd0(DBG_CMD_READ_ALL);
        esperar_resp("READ_ALL en RUNNING", DBG_CMD_READ_ALL, DBG_ERR_STATE, 16'd0);
        read_dmem(32'h0, 16'd1);
        esperar_resp("READ_DMEM en RUNNING", DBG_CMD_READ_DMEM, DBG_ERR_STATE, 16'd0);
        cmd0(DBG_CMD_STOP);
        esperar_resp("bucle STOP", DBG_CMD_STOP, DBG_OK, 16'd12);
        cmd0(DBG_CMD_READ_LATCHES);
        esperar_resp("bucle READ_LATCHES", DBG_CMD_READ_LATCHES, DBG_OK, LEN_LAT);
        chk_lat("bucle READ_LATCHES", 0);

        //--------------------------------------------------------------
        chk("A: bytes con i_pl_ready = 0", a_tx_sin_ready, 0);
        chk("A: puerto B con el core habilitado", a_b_con_core, 0);
        chk("A: tramas serie bien formadas", rx_bad, 0);

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
