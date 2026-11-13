`timescale 1ns / 1ps

//======================================================================
// debug_load_tb
//
// Testbench autoverificante de la carga de programa de la Debug Unit
// (I-46: LOAD y RESET en debug_unit; docs/spec/verificacion.md §3.3,
// memoria.md §4, protocolo_debug.md §3.3 y §3.4, decisiones 004 y 037).
//
// Montaje: el testbench hace de PC y le habla a debug_unit por la línea
// serie, a través de uart; debug_unit escribe imem y limpia dmem por el
// puerto B del core real (riscv_core con imem_bram y dmem_bram), así que
// corre en xsim dentro del proyecto de Vivado:
//   PC (testbench) --serie--> uart <--> debug_unit --puerto B--> riscv_core
//
// Oráculo, escrito aparte del RTL:
//   - Los programas, escritos a mano con un comentario por instrucción.
//   - Un monitor de los puertos B: arma una copia de imem con cada
//     escritura y cuenta las escrituras de cada dirección de imem, de dmem
//     y del mapa de usadas (o_used_clr). Toda escritura tiene que llegar
//     con el core en reset y sin enable (memoria.md §4.1).
//   - Lo que se ve en el core: el campo IF/ID por jerarquía (if_id_valid,
//     if_id_pc, if_id_instr), el banco de registros por el puerto de debug
//     y dmem leída por el puerto B cuando debug_unit no lo usa.
//   - Las respuestas: encabezado, checksum calculado por el testbench y
//     el bloque de estado de §3.1 con los valores esperados.
//   - Un modelo de la FSM de ejecución (I-47) con el contrato de la
//     decisión 037: o_load_start lleva a NO_PROG con prog_valid = 0;
//     LOAD aceptado a READY con prog_valid = 1 y cycles = 0; RESET a
//     READY o NO_PROG según prog_valid; core_rst = NO_PROG | o_clearing;
//     enable = RUNNING | pulso de STEP. RUN corre hasta o_halted.
//
// UART: CLK_FREQ_HZ = 32 × 115200 (DVSR = 2, un byte serie = 320 ciclos)
// y RX_TIMEOUT_CYCLES = 3000, para simular rápido.
//
// Casos:
//   - LOAD desde NO_PROG: imem[0 … N−1] con el programa y imem[N … 1023]
//     con HALT, cada dirección una vez; dmem y el mapa de usadas limpios
//     en las 1024 palabras; respuesta READY; el programa aparece en IF/ID
//   - Reprogramar en HALTED: registros, dmem y pipeline del programa
//     anterior en cero; el nuevo programa aparece en IF/ID
//   - Reprogramar en RUNNING (bucle infinito), en READY y en PAUSED: el
//     core se detiene antes de la primera escritura
//   - N = 1024: sin relleno con HALT
//   - Errores (memoria.md §4.3): ERR_LENGTH sin efectos; ERR_CHECKSUM y
//     ERR_TIMEOUT a mitad del payload dejan imem a medio escribir, sin
//     CLEAR, en NO_PROG con el core en reset (RUN responde ERR_STATE)
//   - RESET con programa: dmem y registros en cero, imem intacta (el
//     programa vuelve a correr igual); RESET sin programa: queda NO_PROG
// Sin aleatoriedad: no hace falta semilla.
//======================================================================

module debug_load_tb;

    `include "riscv_defs.vh"

    localparam integer T_CLK     = 10;            // ns
    localparam integer BAUD      = 115200;
    localparam integer F_CLK     = 32 * BAUD;     // DVSR = 2
    localparam integer TOUT      = 3000;          // ciclos
    localparam integer BYTE_CYC  = 320;           // ciclos por byte serie
    localparam real    BIT_NS    = 320.0;         // 16 ticks × 2 ciclos × 10 ns
    localparam integer MAX_TIME  = 100_000_000;   // ns, watchdog
    localparam integer RESP_WAIT = 2000 + 40 * BYTE_CYC;   // ciclos hasta un byte (CLEAR incluido)
    localparam integer WORDS     = 1024;

    reg         tb_clk;
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

    // Modelo de la FSM de ejecución
    reg  [2:0]  ex_state;
    reg         ex_prog_valid;
    reg  [31:0] ex_cycles;
    reg         ex_step;
    wire        core_rst = (ex_state == DBG_ST_NO_PROG) | du_clearing;
    wire        core_en  = (ex_state == DBG_ST_RUNNING) | ex_step;

    // Core
    wire        core_halted;
    wire        core_imem_fault;
    wire        core_dmem_oob;
    wire        core_dmem_mis;
    wire [31:0] core_pc;
    wire [31:0] core_dmem_b_dout;
    reg  [4:0]  tb_reg_addr;
    wire [31:0] core_reg_data;

    // Puerto B de dmem: debug_unit en CLEAR, el testbench para leer
    reg         tb_dmem_b_en;
    reg  [9:0]  tb_dmem_b_addr;
    wire        dmem_b_en   = du_dmem_b_en | tb_dmem_b_en;
    wire [3:0]  dmem_b_we   = du_dmem_b_en ? du_dmem_b_we   : 4'b0000;
    wire [9:0]  dmem_b_addr = du_dmem_b_en ? du_dmem_b_addr : tb_dmem_b_addr;

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
        .i_dmem_used       (16'd0),                // mapa de usadas: I-48
        .i_pc              (core_pc),
        .i_cycles          (ex_cycles),
        .i_evt_pending     (1'b0),
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
        .i_pl_byte         (8'h00)                 // lecturas: I-48
    );

    riscv_core u_core (
        .i_clk             (tb_clk),
        .i_rst             (core_rst),
        .i_enable          (core_en),
        .i_imem_b_en       (du_imem_b_en),
        .i_imem_b_we       (du_imem_b_we),
        .i_imem_b_addr     (du_imem_b_addr),
        .i_imem_b_din      (du_imem_b_din),
        .i_dmem_b_en       (dmem_b_en),
        .i_dmem_b_we       (dmem_b_we),
        .i_dmem_b_addr     (dmem_b_addr),
        .i_dmem_b_din      (du_dmem_b_din),
        .o_dmem_b_dout     (core_dmem_b_dout),
        .i_dbg_reg_addr    (tb_reg_addr),
        .o_dbg_reg_data    (core_reg_data),
        .o_halted          (core_halted),
        .o_imem_fault      (core_imem_fault),
        .o_dmem_oob        (core_dmem_oob),
        .o_dmem_misaligned (core_dmem_mis),
        .o_pc              (core_pc),
        .o_if_id_latch     (),
        .o_id_ex_latch     (),
        .o_ex_mem_latch    (),
        .o_mem_wb_latch    ()
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
    // Modelo de la FSM de ejecución (contrato de la decisión 037)
    //------------------------------------------------------------------
    always @(posedge tb_clk) begin
        if (tb_rst) begin
            ex_state      <= DBG_ST_NO_PROG;
            ex_prog_valid <= 1'b0;
            ex_cycles     <= 32'd0;
            ex_step       <= 1'b0;
        end
        else begin
            ex_step <= 1'b0;
            if (core_en)
                ex_cycles <= ex_cycles + 1;
            if (ex_state == DBG_ST_RUNNING && core_halted)
                ex_state <= DBG_ST_HALTED;
            if (du_load_start) begin
                ex_prog_valid <= 1'b0;
                ex_state      <= DBG_ST_NO_PROG;
            end
            else if (du_cmd_valid) begin
                case (du_cmd)
                    DBG_CMD_LOAD: begin
                        ex_prog_valid <= 1'b1;
                        ex_state      <= DBG_ST_READY;
                        ex_cycles     <= 32'd0;
                    end
                    DBG_CMD_RESET: begin
                        ex_state  <= ex_prog_valid ? DBG_ST_READY : DBG_ST_NO_PROG;
                        ex_cycles <= 32'd0;
                    end
                    DBG_CMD_RUN:  ex_state <= DBG_ST_RUNNING;
                    DBG_CMD_STEP: begin
                        ex_step  <= 1'b1;
                        ex_state <= DBG_ST_PAUSED;
                    end
                    DBG_CMD_STOP:
                        if (ex_state == DBG_ST_RUNNING) ex_state <= DBG_ST_PAUSED;
                    default: ;
                endcase
            end
        end
    end

    //------------------------------------------------------------------
    // Monitor de los puertos B
    //------------------------------------------------------------------
    reg  [31:0] sh_imem   [0:WORDS-1];   // copia de imem
    integer     n_imem_wr [0:WORDS-1];   // escrituras por dirección
    integer     n_dmem_wr [0:WORDS-1];
    integer     n_used    [0:WORDS-1];
    integer     wr_fuera_de_reset;       // escrituras sin core_rst o con enable
    integer     dmem_mal;                // escrituras de dmem que no son 0 en 1111
    integer     used_sin_dmem;           // o_used_clr sin la escritura de dmem
    integer     m;

    always @(posedge tb_clk) begin
        if (du_imem_b_en && du_imem_b_we) begin
            sh_imem[du_imem_b_addr]   <= du_imem_b_din;
            n_imem_wr[du_imem_b_addr]  = n_imem_wr[du_imem_b_addr] + 1;
            if (!core_rst || core_en) wr_fuera_de_reset = wr_fuera_de_reset + 1;
        end
        if (du_dmem_b_en) begin
            n_dmem_wr[du_dmem_b_addr] = n_dmem_wr[du_dmem_b_addr] + 1;
            if (du_dmem_b_we !== 4'b1111 || du_dmem_b_din !== 32'h0) dmem_mal = dmem_mal + 1;
            if (!core_rst || core_en) wr_fuera_de_reset = wr_fuera_de_reset + 1;
        end
        if (du_used_clr) begin
            n_used[du_dmem_b_addr] = n_used[du_dmem_b_addr] + 1;
            if (!du_dmem_b_en) used_sin_dmem = used_sin_dmem + 1;
        end
    end

    task borrar_cuentas;
        begin
            @(negedge tb_clk);
            for (m = 0; m < WORDS; m = m + 1) begin
                n_imem_wr[m] = 0;  n_dmem_wr[m] = 0;  n_used[m] = 0;
            end
        end
    endtask

    // imem[0 … n-1] = prog y, si relleno, imem[n … 1023] = HALT, cada
    // dirección escrita una vez; o, sin relleno, nada escrito desde n
    reg [31:0] prog [0:WORDS-1];

    task chk_imem;
        input [8*40-1:0] name;
        input integer    n;
        input            relleno;
        integer          a;
        reg              bien_val, bien_cnt;
        begin
            bien_val = 1'b1;  bien_cnt = 1'b1;
            for (a = 0; a < WORDS; a = a + 1) begin
                if (a < n) begin
                    if (sh_imem[a] !== prog[a]) bien_val = 1'b0;
                    if (n_imem_wr[a] != 1)      bien_cnt = 1'b0;
                end
                else if (relleno) begin
                    if (sh_imem[a] !== INSTR_HALT) bien_val = 1'b0;
                    if (n_imem_wr[a] != 1)         bien_cnt = 1'b0;
                end
                else if (n_imem_wr[a] != 0)
                    bien_cnt = 1'b0;
            end
            chk({name, ": imem contenido"},  bien_val, 1'b1);
            chk({name, ": imem escrituras"}, bien_cnt, 1'b1);
        end
    endtask

    // dmem y mapa de usadas: n_esp escrituras en cada dirección
    task chk_clear;
        input [8*40-1:0] name;
        input integer    n_esp;
        integer          a;
        reg              bien_d, bien_u;
        begin
            bien_d = 1'b1;  bien_u = 1'b1;
            for (a = 0; a < WORDS; a = a + 1) begin
                if (n_dmem_wr[a] != n_esp) bien_d = 1'b0;
                if (n_used[a] != n_esp)    bien_u = 1'b0;
            end
            chk({name, ": dmem limpia"},  bien_d, 1'b1);
            chk({name, ": usadas limpias"}, bien_u, 1'b1);
        end
    endtask

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

    reg [7:0] rx_q [0:16383];
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
                rx_q[rx_n] = rx_b;
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
                dato  = rx_q[rx_rd];
                rx_rd = rx_rd + 1;
                ok    = 1'b1;
            end
        end
    endtask

    // Petición: A5, cmd, LEN, los primeros npl bytes de pl_buf y, si
    // con_chk, el CHK correcto XOR chk_xor
    reg [7:0] pl_buf [0:4199];

    task peticion;
        input [7:0]   cmd;
        input [15:0]  len;
        input integer npl;
        input         con_chk;
        input [7:0]   chk_xor;
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
            if (con_chk)
                serie_tx(c ^ chk_xor);
        end
    endtask

    // LOAD de los primeros n words de prog (little-endian)
    task load;
        input integer n;
        input [7:0]   chk_xor;
        integer       i;
        begin
            for (i = 0; i < n; i = i + 1)
                {pl_buf[4*i+3], pl_buf[4*i+2], pl_buf[4*i+1], pl_buf[4*i]} = prog[i];
            peticion(DBG_CMD_LOAD, 4 * n, 4 * n, 1'b1, chk_xor);
        end
    endtask

    reg [7:0] resp_buf [0:8191];
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

    // Bloque de estado: state, flags (prog_valid, halted), pc y cycles
    task chk_bloque;
        input [8*40-1:0] name;
        input [2:0]      st;
        input            pv;
        input [31:0]     pc;
        input [31:0]     cyc;
        begin
            chk({name, ": state"}, resp_buf[0], {5'b0, st});
            chk({name, ": flags"}, resp_buf[1] & 8'h03, {6'b0, 1'b0, pv});
            chk({name, ": dmem_used"}, {resp_buf[3], resp_buf[2]}, 16'd0);
            chk({name, ": pc"}, {resp_buf[7], resp_buf[6], resp_buf[5], resp_buf[4]}, pc);
            chk({name, ": cycles"}, {resp_buf[11], resp_buf[10], resp_buf[9], resp_buf[8]}, cyc);
        end
    endtask

    // Comando sin payload
    task cmd0;
        input [7:0] cmd;
        begin
            peticion(cmd, 16'd0, 0, 1'b1, 8'h00);
        end
    endtask

    // Lee dmem[a] por el puerto B (debug_unit no lo usa fuera de CLEAR)
    task leer_dmem;
        input  [9:0]      a;
        output reg [31:0] dato;
        begin
            @(negedge tb_clk);
            tb_dmem_b_en = 1'b1;  tb_dmem_b_addr = a;
            @(negedge tb_clk);
            tb_dmem_b_en = 1'b0;
            dato = core_dmem_b_dout;
        end
    endtask

    task leer_reg;
        input  [4:0]      r;
        output reg [31:0] dato;
        begin
            @(negedge tb_clk);
            tb_reg_addr = r;
            #1;
            dato = core_reg_data;
        end
    endtask

    // STEP: un ciclo del core; después mira IF/ID
    task step_if_id;
        input [8*40-1:0] name;
        input [31:0]     pc;
        input [31:0]     instr;
        begin
            cmd0(DBG_CMD_STEP);
            esperar_resp({name, " STEP"}, DBG_CMD_STEP, DBG_OK, 16'd12);
            chk({name, ": if_id_valid"}, u_core.if_id_valid, 1'b1);
            chk({name, ": if_id_pc"},    u_core.if_id_pc, pc);
            chk({name, ": if_id_instr"}, u_core.if_id_instr, instr);
        end
    endtask

    // RUN hasta HALTED (la confirmación sale enseguida)
    task correr;
        input [8*40-1:0] name;
        integer          c;
        begin
            cmd0(DBG_CMD_RUN);
            esperar_resp({name, " RUN"}, DBG_CMD_RUN, DBG_OK, 16'd0);
            for (c = 0; c < 200 && ex_state != DBG_ST_HALTED; c = c + 1)
                @(negedge tb_clk);
            chk({name, ": HALTED"}, ex_state, DBG_ST_HALTED);
        end
    endtask

    //------------------------------------------------------------------
    // Detención del core al empezar un LOAD: ciclos desde o_load_start
    // hasta core_rst = 1 y enable = 0
    //------------------------------------------------------------------
    integer stop_lat;
    integer stop_cnt;
    reg     stop_mide;

    always @(posedge tb_clk) begin
        if (du_load_start) begin
            stop_mide = 1'b1;  stop_cnt = 0;
        end
        else if (stop_mide) begin
            stop_cnt = stop_cnt + 1;
            if (core_rst && !core_en) begin
                stop_lat  = stop_cnt;
                stop_mide = 1'b0;
            end
        end
    end

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    integer    i, n0;
    reg [31:0] v;

    initial begin
        errors = 0;  checks = 0;
        wr_fuera_de_reset = 0;  dmem_mal = 0;  used_sin_dmem = 0;
        stop_mide = 1'b0;  stop_lat = -1;  stop_cnt = 0;
        tb_rst = 1'b1;  tb_rx = 1'b1;
        tb_dmem_b_en = 1'b0;  tb_dmem_b_addr = 10'd0;  tb_reg_addr = 5'd0;
        for (i = 0; i < WORDS; i = i + 1) sh_imem[i] = 32'hxxxx_xxxx;
        borrar_cuentas;
        repeat (4) @(negedge tb_clk);
        tb_rst = 1'b0;
        repeat (4) @(negedge tb_clk);
        chk("reset: NO_PROG", ex_state, DBG_ST_NO_PROG);
        chk("reset: core en reset", core_rst, 1'b1);

        //--------------------------------------------------------------
        // LOAD desde NO_PROG (protocolo_debug.md §4)
        //--------------------------------------------------------------
        prog[0] = 32'h07B0_0293;     // addi x5, x0, 123   x5 = 123
        prog[1] = 32'h0050_2823;     // sw   x5, 16(x0)    dmem[4] = 123
        prog[2] = 32'h0010_0073;     // halt
        load(3, 8'h00);
        esperar_resp("LOAD 1", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_bloque("LOAD 1", DBG_ST_READY, 1'b1, 32'h0, 32'h0);
        chk_imem("LOAD 1", 3, 1'b1);
        chk_clear("LOAD 1", 1);
        chk("LOAD 1: core fuera de reset", core_rst, 1'b0);
        chk("LOAD 1: core detenido", core_en, 1'b0);
        chk("LOAD 1: IF/ID burbuja", u_core.if_id_valid, 1'b0);
        step_if_id("LOAD 1 paso 1", 32'h0, prog[0]);
        step_if_id("LOAD 1 paso 2", 32'h4, prog[1]);

        //--------------------------------------------------------------
        // Corre hasta el HALT y reprograma en HALTED
        //--------------------------------------------------------------
        correr("programa 1");
        leer_reg(5'd5, v);    chk("programa 1: x5", v, 32'd123);
        leer_dmem(10'd4, v);  chk("programa 1: dmem[4]", v, 32'd123);
        borrar_cuentas;
        prog[0] = 32'h0010_0313;     // addi x6, x0, 1     x6 = 1
        prog[1] = 32'h0010_0073;     // halt
        load(2, 8'h00);
        esperar_resp("LOAD en HALTED", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_bloque("LOAD en HALTED", DBG_ST_READY, 1'b1, 32'h0, 32'h0);
        chk_imem("LOAD en HALTED", 2, 1'b1);
        chk_clear("LOAD en HALTED", 1);
        chk("LOAD en HALTED: halted", core_halted, 1'b0);
        leer_reg(5'd5, v);    chk("LOAD en HALTED: x5 en 0", v, 32'd0);
        leer_dmem(10'd4, v);  chk("LOAD en HALTED: dmem[4] en 0", v, 32'd0);
        chk("LOAD en HALTED: IF/ID burbuja", u_core.if_id_valid, 1'b0);
        chk("LOAD en HALTED: ID/EX burbuja", u_core.id_ex_valid, 1'b0);
        chk("LOAD en HALTED: EX/MEM burbuja", u_core.ex_mem_valid, 1'b0);
        chk("LOAD en HALTED: MEM/WB burbuja", u_core.mem_wb_valid, 1'b0);
        step_if_id("LOAD en HALTED paso 1", 32'h0, prog[0]);

        //--------------------------------------------------------------
        // Reprograma en RUNNING (bucle infinito)
        //--------------------------------------------------------------
        prog[0] = 32'h0000_006F;     // jal x0, 0          bucle infinito
        load(1, 8'h00);
        esperar_resp("LOAD bucle", DBG_CMD_LOAD, DBG_OK, 16'd12);
        cmd0(DBG_CMD_RUN);
        esperar_resp("bucle RUN", DBG_CMD_RUN, DBG_OK, 16'd0);
        repeat (50) @(negedge tb_clk);
        chk("bucle: RUNNING", ex_state, DBG_ST_RUNNING);
        chk("bucle: enable", core_en, 1'b1);
        borrar_cuentas;
        stop_lat = -1;
        prog[0] = 32'h07B0_0293;     // addi x5, x0, 123
        prog[1] = 32'h0050_2823;     // sw   x5, 16(x0)
        prog[2] = 32'h0010_0073;     // halt
        load(3, 8'h00);
        esperar_resp("LOAD en RUNNING", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_bloque("LOAD en RUNNING", DBG_ST_READY, 1'b1, 32'h0, 32'h0);
        chk("LOAD en RUNNING: se detiene en 1 ciclo", stop_lat, 1);
        chk_imem("LOAD en RUNNING", 3, 1'b1);
        chk_clear("LOAD en RUNNING", 1);
        step_if_id("LOAD en RUNNING paso 1", 32'h0, prog[0]);

        //--------------------------------------------------------------
        // Reprograma en PAUSED (después de un STEP) y en READY
        //--------------------------------------------------------------
        chk("antes: PAUSED", ex_state, DBG_ST_PAUSED);
        borrar_cuentas;
        load(3, 8'h00);
        esperar_resp("LOAD en PAUSED", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_imem("LOAD en PAUSED", 3, 1'b1);
        chk_clear("LOAD en PAUSED", 1);
        chk("LOAD en PAUSED: IF/ID burbuja", u_core.if_id_valid, 1'b0);
        chk("antes: READY", ex_state, DBG_ST_READY);
        borrar_cuentas;
        load(3, 8'h00);
        esperar_resp("LOAD en READY", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_imem("LOAD en READY", 3, 1'b1);
        chk_clear("LOAD en READY", 1);
        correr("LOAD en READY");
        leer_reg(5'd5, v);    chk("LOAD en READY: x5", v, 32'd123);

        //--------------------------------------------------------------
        // RESET con programa: dmem y registros en 0, imem intacta
        //--------------------------------------------------------------
        borrar_cuentas;
        cmd0(DBG_CMD_RESET);
        esperar_resp("RESET", DBG_CMD_RESET, DBG_OK, 16'd12);
        chk_bloque("RESET", DBG_ST_READY, 1'b1, 32'h0, 32'h0);
        chk_imem("RESET", 0, 1'b0);
        chk_clear("RESET", 1);
        leer_reg(5'd5, v);    chk("RESET: x5 en 0", v, 32'd0);
        leer_dmem(10'd4, v);  chk("RESET: dmem[4] en 0", v, 32'd0);
        correr("RESET: el programa vuelve a correr");
        leer_reg(5'd5, v);    chk("RESET: x5 otra vez", v, 32'd123);
        leer_dmem(10'd4, v);  chk("RESET: dmem[4] otra vez", v, 32'd123);

        //--------------------------------------------------------------
        // Errores (memoria.md §4.3)
        //--------------------------------------------------------------
        // ERR_LENGTH: sin efectos
        borrar_cuentas;
        for (i = 0; i < 6; i = i + 1) pl_buf[i] = 8'h00;
        n0 = rx_n;
        peticion(DBG_CMD_LOAD, 16'd6, 6, 1'b1, 8'h00);
        esperar_resp("LOAD LEN 6", DBG_CMD_LOAD, DBG_ERR_LENGTH, 16'd0);
        chk_imem("LOAD LEN 6", 0, 1'b0);
        chk_clear("LOAD LEN 6", 0);
        chk("LOAD LEN 6: sigue HALTED", ex_state, DBG_ST_HALTED);
        chk("LOAD LEN 6: prog_valid", ex_prog_valid, 1'b1);
        leer_reg(5'd5, v);    chk("LOAD LEN 6: x5 intacto", v, 32'd123);

        // ERR_CHECKSUM: imem escrita sin relleno, sin CLEAR, NO_PROG
        borrar_cuentas;
        prog[0] = 32'h0010_0313;     // addi x6, x0, 1
        prog[1] = 32'h0010_0073;     // halt
        load(2, 8'h01);
        esperar_resp("LOAD checksum mal", DBG_CMD_LOAD, DBG_ERR_CHECKSUM, 16'd0);
        chk_imem("LOAD checksum mal", 2, 1'b0);
        chk_clear("LOAD checksum mal", 0);
        chk("LOAD checksum mal: NO_PROG", ex_state, DBG_ST_NO_PROG);
        chk("LOAD checksum mal: prog_valid", ex_prog_valid, 1'b0);
        chk("LOAD checksum mal: core en reset", core_rst, 1'b1);
        leer_dmem(10'd4, v);  chk("LOAD checksum mal: dmem intacta", v, 32'd123);
        cmd0(DBG_CMD_RUN);
        esperar_resp("RUN en NO_PROG", DBG_CMD_RUN, DBG_ERR_STATE, 16'd0);

        // RESET sin programa: limpia dmem y queda NO_PROG
        borrar_cuentas;
        cmd0(DBG_CMD_RESET);
        esperar_resp("RESET sin programa", DBG_CMD_RESET, DBG_OK, 16'd12);
        chk_bloque("RESET sin programa", DBG_ST_NO_PROG, 1'b0, 32'h0, 32'h0);
        chk_clear("RESET sin programa", 1);
        chk_imem("RESET sin programa", 0, 1'b0);
        chk("RESET sin programa: core en reset", core_rst, 1'b1);

        // ERR_TIMEOUT a mitad del payload: la palabra completa se escribe
        borrar_cuentas;
        prog[0] = 32'h1122_3344;
        prog[1] = 32'h5566_7788;
        {pl_buf[3], pl_buf[2], pl_buf[1], pl_buf[0]} = prog[0];
        {pl_buf[7], pl_buf[6], pl_buf[5], pl_buf[4]} = prog[1];
        peticion(DBG_CMD_LOAD, 16'd8, 5, 1'b0, 8'h00);
        esperar_resp("LOAD timeout", DBG_CMD_LOAD, DBG_ERR_TIMEOUT, 16'd0);
        chk_imem("LOAD timeout", 1, 1'b0);
        chk_clear("LOAD timeout", 0);
        chk("LOAD timeout: NO_PROG", ex_state, DBG_ST_NO_PROG);
        chk("LOAD timeout: core en reset", core_rst, 1'b1);

        //--------------------------------------------------------------
        // N = 1024: sin relleno con HALT
        //--------------------------------------------------------------
        borrar_cuentas;
        for (i = 0; i < WORDS; i = i + 1)
            prog[i] = {i[11:0], 20'h00013};     // addi x0, x0, i
        load(WORDS, 8'h00);
        esperar_resp("LOAD N 1024", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_bloque("LOAD N 1024", DBG_ST_READY, 1'b1, 32'h0, 32'h0);
        chk_imem("LOAD N 1024", WORDS, 1'b0);
        chk_clear("LOAD N 1024", 1);
        step_if_id("LOAD N 1024 paso 1", 32'h0, prog[0]);

        //--------------------------------------------------------------
        chk("escrituras con el core en reset", wr_fuera_de_reset, 0);
        chk("dmem: solo ceros en 1111", dmem_mal, 0);
        chk("usadas: con la escritura de dmem", used_sin_dmem, 0);
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
