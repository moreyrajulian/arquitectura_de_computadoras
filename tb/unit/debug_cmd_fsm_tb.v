`timescale 1ns / 1ps

//======================================================================
// debug_cmd_fsm_tb
//
// Testbench autoverificante de debug_unit, la FSM de protocolo de la Debug
// Unit (docs/spec/verificacion.md §3.3, protocolo_debug.md §2 a §5,
// decisión 036).
//
// Montaje: el testbench hace de PC y le habla a debug_unit por la línea
// serie, a través de uart (decisión 035):
//   PC (testbench) --serie--> uart --bytes--> debug_unit --bytes--> uart --serie--> PC
//
// Oráculo, escrito aparte del RTL:
//   - Un transmisor y un receptor serie (start, 8 datos LSB primero, stop).
//     El receptor corre siempre y guarda cada byte en una cola, así se ve
//     el orden entre una respuesta y un EVT_HALTED.
//   - Las tramas de protocolo_debug.md §4 y las respuestas con error,
//     escritas a mano byte por byte.
//   - Para el resto: el encabezado esperado, el checksum calculado por el
//     testbench (XOR desde CMD), el bloque de estado de §3.1 armado con
//     los valores que pone el testbench, el bloque de INFO de §3.2 escrito
//     a mano y, en las lecturas, los bytes que entrega el testbench por
//     i_pl_byte (una función del CMD y del índice, con 2 ciclos de latencia
//     como una BRAM).
//   - La tabla de §3.7 y los LEN de cada comando, escritos aparte.
//   - Un modelo chico del resto de la Debug Unit (FSM de ejecución,
//     carga): reacciona a o_cmd_valid cuando model_on = 1 y baja
//     i_evt_pending con o_evt_done. "Sin efectos" = sin pulso de
//     o_cmd_valid.
//
// DUT: CLK_FREQ_HZ = 32 × 115200 (DVSR = 2, un bit = 32 ciclos, un byte =
//      320) y RX_TIMEOUT_CYCLES = 3000, para simular rápido. La lógica de
//      protocolo no depende del baudrate (uart_tb prueba la UART a 100 MHz).
//
// Casos:
//   - INFO de punta a punta (bloque de §3.2 con los parámetros)
//   - Las tramas de §4: LOAD y su respuesta, RUN y su confirmación,
//     EVT_HALTED, STEP en HALTED, READ_REGS en RUNNING, READ_DMEM y LOAD
//     con checksum mal
//   - Comando desconocido (también 0xE0 como petición y con payload) y
//     checksum incorrecto
//   - Los 12 comandos en los 5 estados: OK o ERR_STATE según §3.7, con el
//     LEN y el payload de cada uno
//   - ERR_LENGTH: LOAD con LEN 0, no múltiplo de 4 y N = 1025 (N = 1024
//     pasa); LEN de comandos sin payload y de READ_DMEM. Orden entre
//     errores y error de encabezado con CHK mal
//   - ERR_ADDR de READ_DMEM: desalineada, count = 0, fuera de rango y
//     que da la vuelta; el borde que sí entra
//   - ERR_TIMEOUT en cada estado de recepción (con CMD 0x00 si no llegó),
//     también en DISCARD; una pausa corta no lo dispara; en reposo no hay
//   - Basura antes del SOF; sincronía después de cada error
//   - EVT_HALTED: después de la confirmación de RUN, después de una
//     respuesta en curso y antes de una petición que llega mientras sale
//   - Bloque de estado tomado de una vez aunque pc cambie mientras sale
//   - Reset en medio de una trama
// Sin aleatoriedad: no hace falta semilla.
//======================================================================

module debug_cmd_fsm_tb;

    `include "riscv_defs.vh"

    localparam integer T_CLK     = 10;            // ns
    localparam integer BAUD      = 115200;
    localparam integer F_CLK     = 32 * BAUD;     // DVSR = 2
    localparam integer TOUT      = 3000;          // ciclos
    localparam integer BYTE_CYC  = 320;           // ciclos por byte serie
    localparam real    BIT_NS    = 320.0;         // 16 ticks × 2 ciclos × 10 ns
    localparam integer MAX_TIME  = 120_000_000;   // ns, watchdog
    localparam integer RESP_WAIT = 40 * BYTE_CYC; // ciclos máximos hasta un byte

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

    // Lo que maneja el modelo del resto de la Debug Unit
    reg  [2:0]  tb_state;
    reg         tb_prog_valid;
    reg         tb_halted;
    reg         tb_imem_fault;
    reg         tb_dmem_oob;
    reg         tb_dmem_mis;
    reg  [15:0] tb_used;
    reg  [31:0] tb_pc;
    reg  [31:0] tb_cycles;
    reg         tb_evt_pending;
    reg  [7:0]  tb_pl_byte;
    reg  [7:0]  pl_pipe;

    wire        tb_o_evt_done;
    wire        tb_o_cmd_valid;
    wire [7:0]  tb_o_cmd;
    wire [31:0] tb_o_arg_addr;
    wire [15:0] tb_o_arg_count;
    wire [15:0] tb_o_pl_idx;

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
        .i_state           (tb_state),
        .i_prog_valid      (tb_prog_valid),
        .i_halted          (tb_halted),
        .i_imem_fault      (tb_imem_fault),
        .i_dmem_oob        (tb_dmem_oob),
        .i_dmem_misaligned (tb_dmem_mis),
        .i_dmem_used       (tb_used),
        .i_pc              (tb_pc),
        .i_cycles          (tb_cycles),
        .i_evt_pending     (tb_evt_pending),
        .o_evt_done        (tb_o_evt_done),
        .o_cmd_valid       (tb_o_cmd_valid),
        .o_cmd             (tb_o_cmd),
        .o_arg_addr        (tb_o_arg_addr),
        .o_arg_count       (tb_o_arg_count),
        .o_pl_idx          (tb_o_pl_idx),
        .i_pl_byte         (tb_pl_byte)
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
    // Bytes de las lecturas: función del CMD y del índice, con 2 ciclos de
    // latencia (como una BRAM con registro de dirección)
    //------------------------------------------------------------------
    function [7:0] pl_fn;
        input [7:0]  cmd;
        input [15:0] idx;
        begin
            pl_fn = cmd ^ idx[7:0] ^ {idx[11:8], idx[15:12]} ^ 8'h5C;
        end
    endfunction

    always @(posedge tb_clk) begin
        pl_pipe    <= pl_fn(tb_o_cmd, tb_o_pl_idx);
        tb_pl_byte <= pl_pipe;
    end

    //------------------------------------------------------------------
    // Pulsos de o_cmd_valid
    //------------------------------------------------------------------
    integer    n_cmd;
    reg [7:0]  last_cmd;
    reg [31:0] last_addr;
    reg [15:0] last_count;

    always @(posedge tb_clk) begin
        if (tb_o_cmd_valid) begin
            n_cmd      = n_cmd + 1;
            last_cmd   = tb_o_cmd;
            last_addr  = tb_o_arg_addr;
            last_count = tb_o_arg_count;
        end
    end

    //------------------------------------------------------------------
    // Modelo del resto de la Debug Unit (solo con model_on = 1): lo que
    // harán la FSM de ejecución (I-47) y la carga (I-46) al aceptar un
    // comando. halt_delay > 0: tantos ciclos después de RUN, el core llega
    // al HALT (HALTED, pc = 8, cycles = 6, evt_pending)
    //------------------------------------------------------------------
    reg     model_on;
    integer halt_delay;
    integer halt_cnt;

    always @(posedge tb_clk) begin
        if (tb_o_evt_done)
            tb_evt_pending <= 1'b0;
        if (model_on && tb_o_cmd_valid) begin
            case (tb_o_cmd)
                DBG_CMD_LOAD: begin
                    tb_state <= DBG_ST_READY;  tb_prog_valid <= 1'b1;  tb_halted <= 1'b0;
                    tb_pc <= 32'h0;  tb_cycles <= 32'h0;  tb_used <= 16'h0;
                end
                DBG_CMD_RUN: begin
                    tb_state <= DBG_ST_RUNNING;
                    halt_cnt  = halt_delay;
                end
                DBG_CMD_STEP: begin
                    tb_state  <= DBG_ST_PAUSED;
                    tb_cycles <= tb_cycles + 1;
                end
                DBG_CMD_STOP:
                    if (tb_state == DBG_ST_RUNNING) tb_state <= DBG_ST_PAUSED;
                default: ;
            endcase
        end
        if (halt_cnt > 0) begin
            halt_cnt = halt_cnt - 1;
            if (halt_cnt == 0) begin
                tb_state <= DBG_ST_HALTED;  tb_halted <= 1'b1;
                tb_pc <= 32'h8;  tb_cycles <= 32'h6;  tb_evt_pending <= 1'b1;
            end
        end
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
    reg       rx_on;         // 0 durante un reset en medio de una transmisión
    reg [7:0] rx_b;
    integer   rx_j;

    initial begin
        rx_n = 0;  rx_rd = 0;  rx_bad = 0;  rx_on = 1'b1;
        forever begin
            @(negedge tb_o_tx);
            #(BIT_NS / 2.0);
            if (tb_o_tx === 1'b0) begin
                for (rx_j = 0; rx_j < 8; rx_j = rx_j + 1) begin
                    #(BIT_NS);
                    rx_b[rx_j] = tb_o_tx;
                end
                #(BIT_NS);
                if (rx_on) begin
                    if (tb_o_tx !== 1'b1) rx_bad = rx_bad + 1;
                    rx_q[rx_n] = rx_b;
                    rx_n = rx_n + 1;
                end
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
    // Petición genérica: A5, cmd, LEN, los primeros npl bytes de pl_buf y,
    // si con_chk = 1, el CHK correcto XOR chk_xor. Con npl < len o sin CHK
    // queda cortada (timeouts)
    //------------------------------------------------------------------
    reg [7:0] pl_buf [0:4199];

    task peticion;
        input [7:0]  cmd;
        input [15:0] len;
        input integer npl;
        input        con_chk;
        input [7:0]  chk_xor;
        reg   [7:0]  c;
        integer      i;
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

    // Envía n bytes escritos a mano; f tiene el primero en los bits altos
    task enviar_hex;
        input integer   n;
        input [8*24-1:0] f;
        integer         i;
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
    // Respuesta genérica: encabezado esperado, payload en resp_buf y CHK
    // calculado por el testbench
    //------------------------------------------------------------------
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

    // Respuesta con error: LEN = 0
    task esperar_err;
        input [8*40-1:0] name;
        input [7:0]      cmd;
        input [7:0]      status;
        begin
            esperar_resp(name, cmd, status, 16'd0);
        end
    endtask

    // Bloque de estado de §3.1 con los valores actuales del testbench
    function [7:0] status_byte;
        input integer i;
        begin
            case (i)
                0:  status_byte = {5'b0, tb_state};
                1:  status_byte = {3'b0, tb_dmem_mis, tb_dmem_oob, tb_imem_fault,
                                   tb_halted, tb_prog_valid};
                2:  status_byte = tb_used[7:0];
                3:  status_byte = tb_used[15:8];
                4:  status_byte = tb_pc[7:0];
                5:  status_byte = tb_pc[15:8];
                6:  status_byte = tb_pc[23:16];
                7:  status_byte = tb_pc[31:24];
                8:  status_byte = tb_cycles[7:0];
                9:  status_byte = tb_cycles[15:8];
                10: status_byte = tb_cycles[23:16];
                default: status_byte = tb_cycles[31:24];
            endcase
        end
    endfunction

    task chk_status_block;
        input [8*40-1:0] name;
        input integer    base;
        integer          i;
        begin
            for (i = 0; i < 12; i = i + 1)
                chk(name, resp_buf[base + i], status_byte(i));
        end
    endtask

    // Bytes de una lectura entregados por i_pl_byte, desde el índice desde
    task chk_pl_bytes;
        input [8*40-1:0] name;
        input [7:0]      cmd;
        input integer    desde;
        input integer    hasta;
        integer          i;
        reg              bien;
        begin
            bien = 1'b1;
            for (i = desde; i < hasta; i = i + 1)
                if (resp_buf[i] !== pl_fn(cmd, i[15:0])) bien = 1'b0;
            chk(name, bien, 1'b1);
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
    // Oráculo de §3.7 y de los LEN de §3
    //------------------------------------------------------------------
    function permitido;
        input [7:0] cmd;
        input [2:0] st;
        begin
            case (cmd)
                DBG_CMD_RUN, DBG_CMD_STEP:
                    permitido = (st == DBG_ST_READY) || (st == DBG_ST_PAUSED);
                DBG_CMD_READ_REGS, DBG_CMD_READ_LATCHES, DBG_CMD_READ_DMEM,
                DBG_CMD_READ_DMEM_USED, DBG_CMD_READ_ALL:
                    permitido = (st != DBG_ST_RUNNING);
                default:
                    permitido = 1'b1;
            endcase
        end
    endfunction

    function [15:0] len_ok;           // LEN de la respuesta OK
        input [7:0] cmd;
        begin
            case (cmd)
                DBG_CMD_INFO:           len_ok = 13;
                DBG_CMD_STATUS, DBG_CMD_LOAD, DBG_CMD_RESET, DBG_CMD_STEP,
                DBG_CMD_STOP:           len_ok = 12;
                DBG_CMD_RUN:            len_ok = 0;
                DBG_CMD_READ_REGS:      len_ok = 128;
                DBG_CMD_READ_LATCHES:   len_ok = 4 * (3 + 6 + 4 + 4);   // 65, 161, 109, 110 bits
                DBG_CMD_READ_DMEM:      len_ok = 4;                     // count = 1
                DBG_CMD_READ_DMEM_USED: len_ok = 8 * tb_used;
                default:                len_ok = 12 + 128 + 68 + 8 * tb_used;  // READ_ALL
            endcase
        end
    endfunction

    function [15:0] len_peticion;     // LEN válido de la petición
        input [7:0] cmd;
        begin
            case (cmd)
                DBG_CMD_LOAD:      len_peticion = 4;   // una palabra
                DBG_CMD_READ_DMEM: len_peticion = 6;   // addr 0, count 1
                default:           len_peticion = 0;
            endcase
        end
    endfunction

    reg [7:0] cmds [0:11];

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    integer    s, k, i, n0;
    reg [7:0]  b;
    reg        ok;
    reg [31:0] v;

    task fijar_estado;
        input [2:0] st;
        begin
            @(negedge tb_clk);
            tb_state = st;
            tb_prog_valid = (st != DBG_ST_NO_PROG);
            tb_halted     = (st == DBG_ST_HALTED);
        end
    endtask

    initial begin
        errors = 0;  checks = 0;  n_cmd = 0;
        model_on = 1'b0;  halt_delay = 0;  halt_cnt = 0;
        tb_rst = 1'b1;  tb_rx = 1'b1;
        tb_state = DBG_ST_NO_PROG;  tb_prog_valid = 1'b0;  tb_halted = 1'b0;
        tb_imem_fault = 1'b0;  tb_dmem_oob = 1'b0;  tb_dmem_mis = 1'b0;
        tb_used = 16'd0;  tb_pc = 32'd0;  tb_cycles = 32'd0;  tb_evt_pending = 1'b0;
        cmds[0]  = DBG_CMD_INFO;       cmds[1]  = DBG_CMD_STATUS;
        cmds[2]  = DBG_CMD_LOAD;       cmds[3]  = DBG_CMD_RESET;
        cmds[4]  = DBG_CMD_RUN;        cmds[5]  = DBG_CMD_STEP;
        cmds[6]  = DBG_CMD_STOP;       cmds[7]  = DBG_CMD_READ_REGS;
        cmds[8]  = DBG_CMD_READ_LATCHES;  cmds[9]  = DBG_CMD_READ_DMEM;
        cmds[10] = DBG_CMD_READ_DMEM_USED; cmds[11] = DBG_CMD_READ_ALL;
        repeat (4) @(negedge tb_clk);
        tb_rst = 1'b0;
        repeat (4) @(negedge tb_clk);

        //--------------------------------------------------------------
        // INFO de punta a punta: versión 1, 1024 y 1024 palabras, latches
        // de 3, 6, 4 y 4 palabras, clk_khz = 3686 (0x0E66)
        //--------------------------------------------------------------
        n0 = n_cmd;
        enviar_hex(5, 40'hA5_01_00_00_01);
        esperar_hex("INFO", 19, 152'h5A_01_00_0D_00_01_00_04_00_04_03_06_04_04_66_0E_00_00_60);
        chk("INFO: un pulso", n_cmd - n0, 1);
        chk("INFO: o_cmd", last_cmd, DBG_CMD_INFO);

        //--------------------------------------------------------------
        // Tramas de protocolo_debug.md §4
        //--------------------------------------------------------------
        model_on = 1'b1;
        n0 = n_cmd;
        enviar_hex(13, 104'hA5_10_08_00_93_00_50_00_73_00_10_00_B8);
        esperar_hex("4: LOAD OK", 18, 144'h5A_10_00_0C_00_01_01_00_00_00_00_00_00_00_00_00_00_1C);
        chk("4: LOAD un pulso", n_cmd - n0, 1);

        halt_delay = 0;
        enviar_hex(5, 40'hA5_20_00_00_20);
        esperar_hex("4: RUN", 6, 48'h5A_20_00_00_00_20);
        chk("4: RUN en RUNNING", tb_state, DBG_ST_RUNNING);

        @(negedge tb_clk);
        tb_state = DBG_ST_HALTED;  tb_halted = 1'b1;  tb_pc = 32'h8;  tb_cycles = 32'h6;
        tb_evt_pending = 1'b1;
        esperar_hex("4: EVT_HALTED", 18, 144'h5A_E0_00_0C_00_04_03_00_00_08_00_00_00_06_00_00_00_E5);
        repeat (4) @(negedge tb_clk);
        chk("4: evt_pending bajo", tb_evt_pending, 1'b0);
        sin_respuesta("4: un solo evento", 30 * BYTE_CYC);

        n0 = n_cmd;
        enviar_hex(5, 40'hA5_21_00_00_21);
        esperar_hex("4: STEP en HALTED", 6, 48'h5A_21_04_00_00_25);
        @(negedge tb_clk);
        tb_state = DBG_ST_RUNNING;
        enviar_hex(5, 40'hA5_30_00_00_30);
        esperar_hex("4: READ_REGS en RUNNING", 6, 48'h5A_30_04_00_00_34);
        chk("4: errores sin pulso", n_cmd - n0, 0);

        fijar_estado(DBG_ST_PAUSED);
        enviar_hex(11, 88'hA5_32_06_00_10_00_00_00_04_00_20);
        esperar_resp("4: READ_DMEM", DBG_CMD_READ_DMEM, DBG_OK, 16'd16);
        chk_pl_bytes("4: READ_DMEM payload", DBG_CMD_READ_DMEM, 0, 16);
        chk("4: READ_DMEM addr", last_addr, 32'h10);
        chk("4: READ_DMEM count", last_count, 16'd4);

        n0 = n_cmd;
        enviar_hex(13, 104'hA5_10_08_00_93_00_50_00_73_00_10_00_B9);
        esperar_hex("4: LOAD checksum mal", 6, 48'h5A_10_02_00_00_12);
        chk("4: LOAD mal sin pulso", n_cmd - n0, 0);
        model_on = 1'b0;

        //--------------------------------------------------------------
        // Comando desconocido y checksum incorrecto
        //--------------------------------------------------------------
        n0 = n_cmd;
        enviar_hex(5, 40'hA5_40_00_00_40);
        esperar_hex("desconocido 0x40", 6, 48'h5A_40_01_00_00_41);
        enviar_hex(5, 40'hA5_E0_00_00_E0);
        esperar_hex("0xE0 como peticion", 6, 48'h5A_E0_01_00_00_E1);
        // con payload: lo consume y la petición siguiente se entiende
        enviar_hex(8, 64'hA5_7F_03_00_A5_01_00_7D);
        enviar_hex(5, 40'hA5_02_00_00_02);
        esperar_hex("desconocido con payload", 6, 48'h5A_7F_01_00_00_7E);
        esperar_resp("STATUS despues", DBG_CMD_STATUS, DBG_OK, 16'd12);
        chk_status_block("STATUS despues: bloque", 0);
        n0 = n0 + 1;                                       // el STATUS
        enviar_hex(5, 40'hA5_02_00_00_03);
        esperar_hex("STATUS checksum mal", 6, 48'h5A_02_02_00_00_00);
        chk("errores sin pulso", n_cmd - n0, 0);

        //--------------------------------------------------------------
        // §3.7: los 12 comandos en los 5 estados
        //--------------------------------------------------------------
        tb_used = 16'd2;  tb_pc = 32'h0000_0124;  tb_cycles = 32'h0001_0203;
        tb_imem_fault = 1'b1;  tb_dmem_mis = 1'b1;
        for (i = 0; i < 6; i = i + 1) pl_buf[i] = 8'h00;
        pl_buf[4] = 8'h01;                                 // READ_DMEM addr 0, count 1;
                                                           // LOAD: 0x00000000
        for (s = 0; s < 5; s = s + 1) begin
            fijar_estado(s);
            for (k = 0; k < 12; k = k + 1) begin
                n0 = n_cmd;
                peticion(cmds[k], len_peticion(cmds[k]), len_peticion(cmds[k]), 1'b1, 8'h00);
                if (permitido(cmds[k], s)) begin
                    esperar_resp("3.7 OK", cmds[k], DBG_OK, len_ok(cmds[k]));
                    chk("3.7 OK: un pulso", n_cmd - n0, 1);
                    chk("3.7 OK: o_cmd", last_cmd, cmds[k]);
                    case (cmds[k])
                        DBG_CMD_INFO:
                            chk("3.7 INFO: version", resp_buf[0], 8'h01);
                        DBG_CMD_STATUS, DBG_CMD_LOAD, DBG_CMD_RESET, DBG_CMD_STEP,
                        DBG_CMD_STOP:
                            chk_status_block("3.7 bloque de estado", 0);
                        DBG_CMD_RUN: ;
                        DBG_CMD_READ_ALL: begin
                            chk_status_block("3.7 READ_ALL: bloque", 0);
                            chk_pl_bytes("3.7 READ_ALL: resto", cmds[k], 12, resp_len);
                        end
                        default:
                            chk_pl_bytes("3.7 lectura: payload", cmds[k], 0, resp_len);
                    endcase
                end
                else begin
                    esperar_err("3.7 ERR_STATE", cmds[k], DBG_ERR_STATE);
                    chk("3.7 ERR_STATE: sin pulso", n_cmd - n0, 0);
                end
            end
        end
        tb_imem_fault = 1'b0;  tb_dmem_mis = 1'b0;

        //--------------------------------------------------------------
        // ERR_LENGTH y orden entre errores
        //--------------------------------------------------------------
        fijar_estado(DBG_ST_READY);
        for (i = 0; i < 4200; i = i + 1) pl_buf[i] = i[7:0];
        n0 = n_cmd;
        peticion(DBG_CMD_LOAD, 16'd0, 0, 1'b1, 8'h00);
        esperar_err("LOAD LEN 0", DBG_CMD_LOAD, DBG_ERR_LENGTH);
        peticion(DBG_CMD_LOAD, 16'd6, 6, 1'b1, 8'h00);
        esperar_err("LOAD LEN 6", DBG_CMD_LOAD, DBG_ERR_LENGTH);
        peticion(DBG_CMD_LOAD, 16'd4100, 4100, 1'b1, 8'h00);
        esperar_err("LOAD N 1025", DBG_CMD_LOAD, DBG_ERR_LENGTH);
        peticion(DBG_CMD_INFO, 16'd1, 1, 1'b1, 8'h00);
        esperar_err("INFO LEN 1", DBG_CMD_INFO, DBG_ERR_LENGTH);
        peticion(DBG_CMD_READ_DMEM, 16'd5, 5, 1'b1, 8'h00);
        esperar_err("READ_DMEM LEN 5", DBG_CMD_READ_DMEM, DBG_ERR_LENGTH);
        peticion(DBG_CMD_READ_DMEM, 16'd7, 7, 1'b1, 8'h00);
        esperar_err("READ_DMEM LEN 7", DBG_CMD_READ_DMEM, DBG_ERR_LENGTH);
        fijar_estado(DBG_ST_RUNNING);
        peticion(8'h40, 16'd1, 1, 1'b1, 8'h00);
        esperar_err("orden: desconocido antes que LEN", 8'h40, DBG_ERR_UNKNOWN_CMD);
        peticion(DBG_CMD_RUN, 16'd1, 1, 1'b1, 8'h00);
        esperar_err("orden: LEN antes que estado", DBG_CMD_RUN, DBG_ERR_LENGTH);
        peticion(DBG_CMD_RUN, 16'd0, 0, 1'b1, 8'hFF);
        esperar_err("orden: estado aunque CHK mal", DBG_CMD_RUN, DBG_ERR_STATE);
        peticion(DBG_CMD_INFO, 16'd2, 2, 1'b1, 8'h01);
        esperar_err("orden: LEN aunque CHK mal", DBG_CMD_INFO, DBG_ERR_LENGTH);
        chk("ERR_LENGTH sin pulso", n_cmd - n0, 0);
        fijar_estado(DBG_ST_READY);
        peticion(DBG_CMD_LOAD, 16'd4096, 4096, 1'b1, 8'h00);
        esperar_resp("LOAD N 1024", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk("LOAD N 1024: un pulso", n_cmd - n0, 1);

        //--------------------------------------------------------------
        // ERR_ADDR de READ_DMEM (dmem de 1024 palabras = 4096 bytes)
        //--------------------------------------------------------------
        fijar_estado(DBG_ST_PAUSED);
        n0 = n_cmd;
        {pl_buf[3], pl_buf[2], pl_buf[1], pl_buf[0]} = 32'h0000_0012;
        {pl_buf[5], pl_buf[4]} = 16'd1;
        peticion(DBG_CMD_READ_DMEM, 16'd6, 6, 1'b1, 8'h00);
        esperar_err("ERR_ADDR desalineada", DBG_CMD_READ_DMEM, DBG_ERR_ADDR);
        {pl_buf[3], pl_buf[2], pl_buf[1], pl_buf[0]} = 32'h0000_0010;
        {pl_buf[5], pl_buf[4]} = 16'd0;
        peticion(DBG_CMD_READ_DMEM, 16'd6, 6, 1'b1, 8'h00);
        esperar_err("ERR_ADDR count 0", DBG_CMD_READ_DMEM, DBG_ERR_ADDR);
        {pl_buf[3], pl_buf[2], pl_buf[1], pl_buf[0]} = 32'h0000_0FF0;
        {pl_buf[5], pl_buf[4]} = 16'd5;
        peticion(DBG_CMD_READ_DMEM, 16'd6, 6, 1'b1, 8'h00);
        esperar_err("ERR_ADDR fuera de rango", DBG_CMD_READ_DMEM, DBG_ERR_ADDR);
        {pl_buf[3], pl_buf[2], pl_buf[1], pl_buf[0]} = 32'h0000_1000;
        {pl_buf[5], pl_buf[4]} = 16'd1;
        peticion(DBG_CMD_READ_DMEM, 16'd6, 6, 1'b1, 8'h00);
        esperar_err("ERR_ADDR addr 0x1000", DBG_CMD_READ_DMEM, DBG_ERR_ADDR);
        {pl_buf[3], pl_buf[2], pl_buf[1], pl_buf[0]} = 32'hFFFF_FFFC;
        {pl_buf[5], pl_buf[4]} = 16'd2;
        peticion(DBG_CMD_READ_DMEM, 16'd6, 6, 1'b1, 8'h00);
        esperar_err("ERR_ADDR da la vuelta", DBG_CMD_READ_DMEM, DBG_ERR_ADDR);
        chk("ERR_ADDR sin pulso", n_cmd - n0, 0);
        {pl_buf[3], pl_buf[2], pl_buf[1], pl_buf[0]} = 32'h0000_0FF0;
        {pl_buf[5], pl_buf[4]} = 16'd4;
        peticion(DBG_CMD_READ_DMEM, 16'd6, 6, 1'b1, 8'h00);
        esperar_resp("READ_DMEM hasta el final", DBG_CMD_READ_DMEM, DBG_OK, 16'd16);
        chk("READ_DMEM final: addr", last_addr, 32'hFF0);
        chk("READ_DMEM final: count", last_count, 16'd4);

        //--------------------------------------------------------------
        // ERR_TIMEOUT en cada estado de recepción
        //--------------------------------------------------------------
        n0 = n_cmd;
        enviar_hex(1, 8'hA5);
        esperar_hex("timeout en RX_CMD", 6, 48'h5A_00_06_00_00_06);
        enviar_hex(2, 16'hA5_02);
        esperar_hex("timeout en RX_LEN_L", 6, 48'h5A_02_06_00_00_04);
        enviar_hex(3, 24'hA5_02_00);
        esperar_hex("timeout en RX_LEN_H", 6, 48'h5A_02_06_00_00_04);
        enviar_hex(4, 32'hA5_02_00_00);
        esperar_hex("timeout en RX_CHK", 6, 48'h5A_02_06_00_00_04);
        enviar_hex(7, 56'hA5_32_06_00_10_00_00);
        esperar_hex("timeout en RX_PAYLOAD", 6, 48'h5A_32_06_00_00_34);
        enviar_hex(5, 40'hA5_01_02_00_00);                 // INFO con LEN 2: DISCARD
        esperar_hex("timeout en DISCARD", 6, 48'h5A_01_06_00_00_07);
        chk("timeout sin pulso", n_cmd - n0, 0);
        // pausa corta: el byte siguiente llega TOUT - 200 ciclos después
        // de que debug_unit leyó el anterior (un byte serie son 320)
        serie_tx(8'hA5);  serie_tx(8'h02);  serie_tx(8'h00);
        repeat (TOUT - 200 - BYTE_CYC) @(negedge tb_clk);
        serie_tx(8'h00);
        repeat (TOUT - 200 - BYTE_CYC) @(negedge tb_clk);
        serie_tx(8'h02);
        esperar_resp("pausa corta sin timeout", DBG_CMD_STATUS, DBG_OK, 16'd12);
        // en reposo no hay timeout
        sin_respuesta("reposo sin timeout", 3 * TOUT);

        //--------------------------------------------------------------
        // Basura antes del SOF
        //--------------------------------------------------------------
        n0 = n_cmd;
        enviar_hex(5, 40'h00_FF_5A_13_A4);
        enviar_hex(5, 40'hA5_02_00_00_02);
        esperar_resp("basura y STATUS", DBG_CMD_STATUS, DBG_OK, 16'd12);
        sin_respuesta("basura sin respuesta", 30 * BYTE_CYC);
        chk("basura: un pulso", n_cmd - n0, 1);

        //--------------------------------------------------------------
        // EVT_HALTED y orden de las tramas
        //--------------------------------------------------------------
        // El core llega al HALT mientras sale la confirmación de RUN
        model_on = 1'b1;
        fijar_estado(DBG_ST_READY);
        tb_used = 16'd0;
        halt_delay = 2 * BYTE_CYC;
        enviar_hex(5, 40'hA5_20_00_00_20);
        esperar_hex("evento: confirmacion de RUN", 6, 48'h5A_20_00_00_00_20);
        esperar_hex("evento: despues de RUN", 18,
                    144'h5A_E0_00_0C_00_04_03_00_00_08_00_00_00_06_00_00_00_E5);
        halt_delay = 0;
        model_on = 1'b0;
        // El evento aparece mientras llega una petición: sale después de
        // la respuesta (no se intercalan)
        fijar_estado(DBG_ST_RUNNING);
        tb_halted = 1'b0;  tb_pc = 32'h40;  tb_cycles = 32'h100;
        fork
            enviar_hex(5, 40'hA5_02_00_00_02);
            begin
                repeat (2 * BYTE_CYC) @(negedge tb_clk);
                tb_evt_pending = 1'b1;
            end
        join
        esperar_resp("evento: STATUS antes", DBG_CMD_STATUS, DBG_OK, 16'd12);
        chk("evento: STATUS dice RUNNING", resp_buf[0], DBG_ST_RUNNING);
        @(negedge tb_clk);
        tb_state = DBG_ST_HALTED;  tb_halted = 1'b1;
        esperar_resp("evento: despues de STATUS", DBG_CMD_EVT_HALTED, DBG_OK, 16'd12);
        // Ya pendiente en reposo, con una petición atrás: el evento sale
        // primero y la petición espera en la FIFO de uart
        @(negedge tb_clk);
        tb_evt_pending = 1'b1;
        enviar_hex(5, 40'hA5_02_00_00_02);
        esperar_resp("evento: antes de la peticion", DBG_CMD_EVT_HALTED, DBG_OK, 16'd12);
        chk_status_block("evento: bloque", 0);
        esperar_resp("evento: STATUS en la FIFO", DBG_CMD_STATUS, DBG_OK, 16'd12);
        sin_respuesta("evento: nada mas", 30 * BYTE_CYC);
        // El evento y una petición entera en la FIFO llegan mientras sale
        // otra respuesta: al volver a IDLE sale el evento sin consumir el
        // SOF que espera, y después se responde la petición
        fork
            enviar_hex(5, 40'hA5_02_00_00_02);
            begin
                wait (u_dut.state_reg == 4'd10);           // TX_PAYLOAD del primero
                tb_evt_pending = 1'b1;
                enviar_hex(5, 40'hA5_01_00_00_01);
            end
        join
        esperar_resp("evento en cola: STATUS", DBG_CMD_STATUS, DBG_OK, 16'd12);
        esperar_resp("evento en cola: evento", DBG_CMD_EVT_HALTED, DBG_OK, 16'd12);
        esperar_resp("evento en cola: INFO", DBG_CMD_INFO, DBG_OK, 16'd13);
        sin_respuesta("evento en cola: nada mas", 30 * BYTE_CYC);

        //--------------------------------------------------------------
        // El bloque de estado se toma de una vez: pc cambia mientras sale
        //--------------------------------------------------------------
        fijar_estado(DBG_ST_PAUSED);
        tb_pc = 32'h1111_1111;
        fork
            enviar_hex(5, 40'hA5_02_00_00_02);
            begin
                wait (tb_o_pl_idx == 16'd5 && u_dut.state_reg == 4'd10);
                tb_pc = 32'h2222_2222;
            end
        join
        esperar_resp("snapshot", DBG_CMD_STATUS, DBG_OK, 16'd12);
        chk("snapshot: pc entero", {resp_buf[7], resp_buf[6], resp_buf[5], resp_buf[4]},
            32'h1111_1111);
        enviar_hex(5, 40'hA5_02_00_00_02);
        esperar_resp("snapshot siguiente", DBG_CMD_STATUS, DBG_OK, 16'd12);
        chk("snapshot siguiente: pc", {resp_buf[7], resp_buf[6], resp_buf[5], resp_buf[4]},
            32'h2222_2222);

        //--------------------------------------------------------------
        // Reset en medio de una trama y en medio de una respuesta
        //--------------------------------------------------------------
        n0 = n_cmd;
        enviar_hex(7, 56'hA5_32_06_00_10_00_00);
        @(negedge tb_clk);  tb_rst = 1'b1;
        repeat (4) @(negedge tb_clk);  tb_rst = 1'b0;
        enviar_hex(5, 40'hA5_02_00_00_02);
        esperar_resp("reset en una trama", DBG_CMD_STATUS, DBG_OK, 16'd12);
        sin_respuesta("reset: sin timeout viejo", 2 * TOUT);
        enviar_hex(5, 40'hA5_30_00_00_30);                 // READ_REGS: 134 bytes
        repeat (20 * BYTE_CYC) @(negedge tb_clk);
        rx_on = 1'b0;
        @(negedge tb_clk);  tb_rst = 1'b1;
        repeat (4) @(negedge tb_clk);  tb_rst = 1'b0;
        repeat (2 * BYTE_CYC) @(negedge tb_clk);
        rx_on = 1'b1;  rx_rd = rx_n;
        enviar_hex(5, 40'hA5_01_00_00_01);
        esperar_hex("reset en una respuesta", 19,
                    152'h5A_01_00_0D_00_01_00_04_00_04_03_06_04_04_66_0E_00_00_60);
        chk("reset: pulsos", n_cmd - n0, 3);

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
