`timescale 1ns / 1ps

//======================================================================
// top_tb
//
// Testbench autoverificante del top de la placa (I-49: fpga/riscv_basys3/
// top.v; docs/spec/verificacion.md §3.3, decisiones 035 a 039, 041 y 042).
//
// Montaje: el testbench hace de placa, de PC y de botón. Solo toca los
// pines del top (clk, reset, rx, tx, led), como en la placa: entra a
// clk con 100 MHz, el Clock Wizard da clk_sys de 65 MHz (decisión 042) y
// el testbench no maneja ningún reset propio, así que el reset de
// encendido de reset_sync, que espera a locked, es lo único que
// inicializa el sistema. Corre en xsim dentro del proyecto riscv_basys3
// (usa las BRAM del core y el MMCM). Los ciclos se cuentan con clk_sys,
// por jerarquía.
//
// Qué agrega a debug_load_tb, debug_run_tb y debug_dump_tb, que ya prueban
// los bloques con el mismo cableado: que el top los conecte bien (cada
// comando llega al bloque que corresponde y cada respuesta tiene los
// datos del core real), el reset por botón y de encendido, y los LEDs.
//
// Oráculo, escrito aparte del RTL:
//   - Los programas, escritos a mano con un comentario por instrucción, y
//     su estado final calculado a mano (regs, dmem, PC = dirección del
//     HALT + 4, ciclos = n + 4 + stalls, verificacion.md §5). Coinciden
//     con el modelo de referencia (tools/isasim).
//   - Los latches: los buses o_*_latch del core por jerarquía, partidos en
//     palabras de 32 bits como dice protocolo_debug.md §3.6. Que esos
//     buses tengan los campos de pipeline.md §8 lo prueba debug_dump_tb.
//   - Las respuestas: encabezado, LEN y checksum calculados acá.
//   - LEDs (encabezado de top.v): uno por estado de ejecución, los avisos,
//     el reset y el latido, contra el estado de debug_exec y los avisos
//     del core por jerarquía, en todos los ciclos.
//
// UART: el top queda con su CLK_FREQ_HZ, la frecuencia real del MMCM, y el
// testbench le pone BAUD = CLK_FREQ_HZ / 32 (DVSR = 2, un byte serie = 320
// ciclos de clk_sys) para simular rápido. BLINK_HZ = 15625: el latido cambia
// cada F_SYS / 31250 ciclos (2080 a 65 MHz).
//
// F_SYS tiene que ser el CLK_FREQ_HZ del top (y la salida de ip/clk_wiz.tcl):
// un testbench no puede leer el parámetro de una instancia como constante.
// Para que un cambio de frecuencia no quede en una falla confusa, lo primero
// que se comprueba, apenas engancha el MMCM, es que el período medido de
// clk_sys sea 1e9 / F_SYS; si no, termina con TEST FAILED y dice qué cambiar.
//
// Casos:
//   - Reset de encendido: el reset sigue activo hasta que el MMCM engancha;
//     después el sistema arranca en NO_PROG sin ningún reset del testbench,
//     y responde INFO con clk_khz = F_SYS / 1000 y las palabras de cada latch
//     (3, 6, 4, 4)
//   - LOAD, dos STEP y READ_LATCHES; RUN hasta el EVT_HALTED; READ_ALL
//     con registros, latches y el par de dmem usada (programa con
//     store, load y un stall de carga-uso)
//   - Programa con un store fuera de rango y un load desalineado: los
//     avisos en el EVT_HALTED y en los LEDs; READ_REGS y READ_DMEM_USED;
//     el LOAD siguiente los borra
//   - Botón de reset con el core en RUNNING (bucle infinito) y una
//     petición a medias: el core se detiene, el sistema vuelve a NO_PROG,
//     la petición cortada no responde nada, STATUS responde NO_PROG y RUN
//     responde ERR_STATE
//   - Latido: cambia cada CLK_FREQ_HZ / (2 × BLINK_HZ) ciclos y queda
//     quieto (apagado) con el botón apretado
//   - Ningún byte de más en la línea ni con stop en 0
// Sin aleatoriedad: no hace falta semilla.
//======================================================================

module top_tb;

    `include "riscv_defs.vh"

    localparam integer T_CLK     = 10;            // ns, reloj de la placa (100 MHz)
    localparam integer F_SYS     = 65_000_000;    // = CLK_FREQ_HZ del top y ip/clk_wiz.tcl
    localparam real    T_SYS_NS  = 1.0e9 / F_SYS; // período de clk_sys
    localparam integer BAUD      = F_SYS / 32;    // DVSR = 2
    localparam integer BLINK_HZ  = 15625;
    localparam integer HB_HALF   = F_SYS / (2 * BLINK_HZ);   // 2080 ciclos a 65 MHz
    localparam integer BYTE_CYC  = 320;           // ciclos de clk_sys por byte serie
    localparam real    BIT_NS    = 32.0 * T_SYS_NS;   // 16 ticks × 2 ciclos
    localparam integer LOCK_MAX  = 1_000_000;     // ns hasta que engancha el MMCM
    localparam integer MAX_TIME  = 50_000_000;    // ns, watchdog
    localparam integer RESP_WAIT = 2000 + 40 * BYTE_CYC;   // ciclos hasta un byte (CLEAR incluido)
    localparam integer LEN_LAT   = 68;            // 3 + 6 + 4 + 4 palabras
    localparam integer OFF_REGS  = 12;
    localparam integer OFF_LAT   = 12 + 128;
    localparam integer OFF_PARES = 12 + 128 + LEN_LAT;

    reg         tb_clk;
    reg         tb_btn;
    reg         tb_rx;
    wire        tb_o_tx;
    wire [15:0] tb_led;

    top #(
        .BAUD        (BAUD),
        .BLINK_HZ    (BLINK_HZ)
    ) u_dut (
        .clk   (tb_clk),
        .reset (tb_btn),
        .rx    (tb_rx),
        .tx    (tb_o_tx),
        .led   (tb_led)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    // Reloj del sistema, salida del Clock Wizard (por jerarquía)
    wire sys_clk = u_dut.clk_sys;

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
    // Monitor de los LEDs, en cada ciclo (a mitad de ciclo, ya estables),
    // desde que engancha el MMCM: antes, clk_sys no tiene flancos válidos
    //------------------------------------------------------------------
    integer led_mal;
    reg     led_mal_dicho;
    reg [15:0] led_esp;

    always @(negedge sys_clk) if (u_dut.clk_locked === 1'b1) begin
        led_esp = 16'h0000;
        case (u_dut.ex_state)
            DBG_ST_NO_PROG: led_esp[0] = 1'b1;
            DBG_ST_READY:   led_esp[1] = 1'b1;
            DBG_ST_RUNNING: led_esp[2] = 1'b1;
            DBG_ST_PAUSED:  led_esp[3] = 1'b1;
            DBG_ST_HALTED:  led_esp[4] = 1'b1;
            default:        led_esp    = 16'hxxxx;   // un estado inválido es un error
        endcase
        led_esp[8]  = u_dut.core_imem_fault;
        led_esp[9]  = u_dut.core_dmem_oob;
        led_esp[10] = u_dut.core_dmem_misaligned;
        led_esp[14] = u_dut.rst;
        led_esp[15] = tb_led[15];                    // el latido se prueba aparte
        if (tb_led !== led_esp) begin
            led_mal = led_mal + 1;
            if (!led_mal_dicho) begin
                $display("[%0t] ERROR LEDs | dut=0x%0h esperado=0x%0h", $time, tb_led, led_esp);
                led_mal_dicho = 1'b1;
            end
        end
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
                @(negedge sys_clk);
            if (rx_rd < rx_n) begin
                dato  = rx_q[rx_rd];
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
            serie_tx(DBG_SOF_REQ);
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
    reg [31:0] prog [0:15];

    task load;
        input integer n;
        integer       i;
        begin
            for (i = 0; i < n; i = i + 1)
                {pl_buf[4*i+3], pl_buf[4*i+2], pl_buf[4*i+1], pl_buf[4*i]} = prog[i];
            peticion(DBG_CMD_LOAD, 4 * n, 4 * n);
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
            leer_byte(b, ok);  chk({name, " SOF"},    ok ? b : 32'hDEAD, DBG_SOF_RSP);
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

    // Palabra little-endian de resp_buf
    function [31:0] w32;
        input integer off;
        begin
            w32 = {resp_buf[off+3], resp_buf[off+2], resp_buf[off+1], resp_buf[off]};
        end
    endfunction

    // Bloque de estado (§3.1) desde resp_buf[off]
    task chk_bloque;
        input [8*40-1:0] name;
        input integer    off;
        input [2:0]      st;
        input [7:0]      flags;
        input [15:0]     used;
        input [31:0]     pc;
        input [31:0]     cyc;
        begin
            chk({name, ": state"},     resp_buf[off], {5'b0, st});
            chk({name, ": flags"},     resp_buf[off+1], flags);
            chk({name, ": dmem_used"}, {resp_buf[off+3], resp_buf[off+2]}, used);
            chk({name, ": pc"},        w32(off + 4), pc);
            chk({name, ": cycles"},    w32(off + 8), cyc);
        end
    endtask

    // Latches desde resp_buf[off]: los buses del core partidos en palabras
    // de 32 bits, la menos significativa primero, con relleno en 0 (§3.6)
    reg [191:0] lat_w;
    reg [7:0]   lat_esp [0:LEN_LAT-1];

    task chk_latches;
        input [8*40-1:0] name;
        input integer    off;
        integer          k;
        reg              bien;
        begin
            lat_w = 192'd0;  lat_w[64:0]  = u_dut.core_if_id_latch;
            for (k = 0; k < 12; k = k + 1) lat_esp[k]      = lat_w[8*k +: 8];
            lat_w = 192'd0;  lat_w[160:0] = u_dut.core_id_ex_latch;
            for (k = 0; k < 24; k = k + 1) lat_esp[12 + k] = lat_w[8*k +: 8];
            lat_w = 192'd0;  lat_w[108:0] = u_dut.core_ex_mem_latch;
            for (k = 0; k < 16; k = k + 1) lat_esp[36 + k] = lat_w[8*k +: 8];
            lat_w = 192'd0;  lat_w[109:0] = u_dut.core_mem_wb_latch;
            for (k = 0; k < 16; k = k + 1) lat_esp[52 + k] = lat_w[8*k +: 8];
            bien = 1'b1;
            for (k = 0; k < LEN_LAT; k = k + 1)
                if (resp_buf[off + k] !== lat_esp[k]) begin
                    if (bien)
                        $display("[%0t] ERROR %0s: byte %0d de latches | dut=0x%0h esperado=0x%0h",
                                 $time, name, k, resp_buf[off + k], lat_esp[k]);
                    bien = 1'b0;
                end
            chk({name, ": latches"}, bien, 1'b1);
        end
    endtask

    // Registros x0..x31 desde resp_buf[off] contra regs_esp
    reg [31:0] regs_esp [0:31];

    task chk_regs;
        input [8*40-1:0] name;
        input integer    off;
        integer          r;
        reg              bien;
        begin
            bien = 1'b1;
            for (r = 0; r < 32; r = r + 1)
                if (w32(off + 4 * r) !== regs_esp[r]) begin
                    $display("[%0t] ERROR %0s: x%0d | dut=0x%0h esperado=0x%0h",
                             $time, name, r, w32(off + 4 * r), regs_esp[r]);
                    bien = 1'b0;
                end
            chk({name, ": registros"}, bien, 1'b1);
        end
    endtask

    task regs_en_cero;
        integer r;
        begin
            for (r = 0; r < 32; r = r + 1) regs_esp[r] = 32'd0;
        end
    endtask

    // RUN hasta el EVT_HALTED (protocolo_debug.md §3.5)
    task correr;
        input [8*40-1:0] name;
        input [7:0]      flags;
        input [15:0]     used;
        input [31:0]     pc;
        input [31:0]     cyc;
        begin
            cmd0(DBG_CMD_RUN);
            esperar_resp({name, " RUN"}, DBG_CMD_RUN, DBG_OK, 16'd0);
            esperar_resp({name, " EVT_HALTED"}, DBG_CMD_EVT_HALTED, DBG_OK, 16'd12);
            chk_bloque({name, " EVT_HALTED"}, 0, DBG_ST_HALTED, flags, used, pc, cyc);
        end
    endtask

    // Botón apretado n ciclos, cambiando a destiempo del reloj
    task boton;
        input integer n;
        begin
            @(negedge sys_clk);
            #3;
            tb_btn = 1'b1;
            repeat (n) @(negedge sys_clk);
            #3;
            tb_btn = 1'b0;
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    integer c;
    integer t0;
    integer n_ciclos;
    real    t_flanco;
    real    periodo;
    integer n_hb;
    reg     hb_ant;

    initial begin
        errors = 0;  checks = 0;
        led_mal = 0;  led_mal_dicho = 1'b0;
        tb_btn = 1'b0;  tb_rx = 1'b1;

        //--------------------------------------------------------------
        // Reset de encendido: sin ningún reset del testbench
        //--------------------------------------------------------------
        #1;
        chk("POR: reset activo al arrancar", tb_led[14], 1'b1);
        for (c = 0; c < LOCK_MAX / T_CLK && u_dut.clk_locked !== 1'b1; c = c + 1)
            @(negedge tb_clk);
        chk("POR: el MMCM engancha", u_dut.clk_locked, 1'b1);
        // El período de clk_sys tiene que ser el de F_SYS (error < 0,1 %)
        @(posedge sys_clk);  t_flanco = $realtime;
        repeat (10) @(posedge sys_clk);
        periodo = ($realtime - t_flanco) / 10.0;
        if (periodo < 0.999 * T_SYS_NS || periodo > 1.001 * T_SYS_NS) begin
            $display("ERROR clk_sys mide %0.3f ns y top_tb espera %0.3f ns (F_SYS = %0d Hz): actualizar F_SYS a CLK_FREQ_HZ del top",
                     periodo, T_SYS_NS, F_SYS);
            $display("TEST FAILED: frecuencia de clk_sys distinta de F_SYS");
            $finish;
        end
        chk("POR: reset activo hasta locked", tb_led[14], 1'b1);
        repeat (40) @(negedge sys_clk);
        chk("POR: reset liberado", tb_led[14], 1'b0);
        chk("POR: NO_PROG", tb_led[4:0], 5'b00001);
        chk("POR: core en reset", u_dut.ex_core_rst, 1'b1);

        cmd0(DBG_CMD_INFO);
        esperar_resp("INFO", DBG_CMD_INFO, DBG_OK, 16'd13);
        chk("INFO: proto_version", resp_buf[0], 8'd1);
        chk("INFO: imem_words", {resp_buf[2], resp_buf[1]}, 16'd1024);
        chk("INFO: dmem_words", {resp_buf[4], resp_buf[3]}, 16'd1024);
        chk("INFO: palabras IF/ID", resp_buf[5], 8'd3);
        chk("INFO: palabras ID/EX", resp_buf[6], 8'd6);
        chk("INFO: palabras EX/MEM", resp_buf[7], 8'd4);
        chk("INFO: palabras MEM/WB", resp_buf[8], 8'd4);
        chk("INFO: clk_khz", w32(9), F_SYS / 1000);

        //--------------------------------------------------------------
        // Programa 1: LOAD, STEP, READ_LATCHES, RUN y READ_ALL
        //--------------------------------------------------------------
        // n = 5 instrucciones con el HALT, 1 stall de carga-uso (add usa x6
        // enseguida del lw): ciclos = 5 + 4 + 1 = 10; HALT en 0x10, PC = 0x14
        prog[0] = 32'h07B0_0293;     // addi x5, x0, 123   x5 = 0x7B
        prog[1] = 32'h0050_2823;     // sw   x5, 16(x0)    dmem[0x010] = 0x7B
        prog[2] = 32'h0100_2303;     // lw   x6, 16(x0)    x6 = 0x7B
        prog[3] = 32'h0053_03B3;     // add  x7, x6, x5    x7 = 0xF6
        prog[4] = 32'h0010_0073;     // halt
        load(5);
        esperar_resp("LOAD 1", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_bloque("LOAD 1", 0, DBG_ST_READY, 8'h01, 16'd0, 32'h0, 32'd0);
        chk("LOAD 1: LED READY", tb_led[4:0], 5'b00010);

        cmd0(DBG_CMD_STEP);
        esperar_resp("STEP 1", DBG_CMD_STEP, DBG_OK, 16'd12);
        chk_bloque("STEP 1", 0, DBG_ST_PAUSED, 8'h01, 16'd0, 32'h4, 32'd1);
        cmd0(DBG_CMD_STEP);
        esperar_resp("STEP 2", DBG_CMD_STEP, DBG_OK, 16'd12);
        chk_bloque("STEP 2", 0, DBG_ST_PAUSED, 8'h01, 16'd0, 32'h8, 32'd2);
        chk("STEP 2: LED PAUSED", tb_led[4:0], 5'b01000);
        chk("STEP 2: IF/ID tiene el sw", u_dut.u_core.if_id_instr, prog[1]);

        cmd0(DBG_CMD_READ_LATCHES);
        esperar_resp("READ_LATCHES", DBG_CMD_READ_LATCHES, DBG_OK, LEN_LAT);
        chk_latches("READ_LATCHES en pausa", 0);

        correr("programa 1", 8'h03, 16'd1, 32'h14, 32'd10);
        chk("programa 1: LED HALTED", tb_led[4:0], 5'b10000);

        cmd0(DBG_CMD_READ_ALL);
        esperar_resp("READ_ALL", DBG_CMD_READ_ALL, DBG_OK, OFF_PARES + 8);
        chk_bloque("READ_ALL", 0, DBG_ST_HALTED, 8'h03, 16'd1, 32'h14, 32'd10);
        regs_en_cero;
        regs_esp[5] = 32'h7B;  regs_esp[6] = 32'h7B;  regs_esp[7] = 32'hF6;
        chk_regs("READ_ALL", OFF_REGS);
        chk_latches("READ_ALL", OFF_LAT);
        chk("READ_ALL: dirección del par", w32(OFF_PARES), 32'h010);
        chk("READ_ALL: valor del par", w32(OFF_PARES + 4), 32'h7B);

        //--------------------------------------------------------------
        // Programa 2: avisos de acceso (memoria.md §6)
        //--------------------------------------------------------------
        // n = 4, sin stalls: ciclos = 8; HALT en 0x0C, PC = 0x10.
        // El sw a 0x1000 escribe el alias dmem[0x000] (= 0, la marca como
        // usada) y levanta dmem_oob; el lw desalineado lee la palabra de
        // 0x000 y levanta dmem_misaligned. flags = 0x01 | 0x02 | 0x08 | 0x10
        prog[0] = 32'h0000_10B7;     // lui  x1, 1         x1 = 0x1000
        prog[1] = 32'h0000_A023;     // sw   x0, 0(x1)     dmem[0x000] = 0, dmem_oob
        prog[2] = 32'h0010_2103;     // lw   x2, 1(x0)     x2 = 0, dmem_misaligned
        prog[3] = 32'h0010_0073;     // halt
        load(4);
        esperar_resp("LOAD 2", DBG_CMD_LOAD, DBG_OK, 16'd12);
        chk_bloque("LOAD 2", 0, DBG_ST_READY, 8'h01, 16'd0, 32'h0, 32'd0);
        chk("LOAD 2: LEDs de avisos apagados", tb_led[10:8], 3'b000);
        correr("programa 2", 8'h1B, 16'd1, 32'h10, 32'd8);
        chk("programa 2: LEDs de avisos", tb_led[10:8], 3'b110);

        cmd0(DBG_CMD_READ_REGS);
        esperar_resp("READ_REGS", DBG_CMD_READ_REGS, DBG_OK, 16'd128);
        regs_en_cero;
        regs_esp[1] = 32'h1000;
        chk_regs("READ_REGS", 0);

        cmd0(DBG_CMD_READ_DMEM_USED);
        esperar_resp("READ_DMEM_USED", DBG_CMD_READ_DMEM_USED, DBG_OK, 16'd8);
        chk("READ_DMEM_USED: dirección", w32(0), 32'h000);
        chk("READ_DMEM_USED: valor", w32(4), 32'h0);

        //--------------------------------------------------------------
        // Botón de reset en RUNNING con una petición a medias
        //--------------------------------------------------------------
        prog[0] = 32'h0000_006F;     // jal x0, 0          bucle infinito
        load(1);
        esperar_resp("LOAD bucle", DBG_CMD_LOAD, DBG_OK, 16'd12);
        // core_rst borra los avisos del programa 2 (memoria.md §6.2)
        chk_bloque("LOAD bucle", 0, DBG_ST_READY, 8'h01, 16'd0, 32'h0, 32'd0);
        chk("LOAD bucle: LEDs de avisos apagados", tb_led[10:8], 3'b000);
        cmd0(DBG_CMD_RUN);
        esperar_resp("bucle RUN", DBG_CMD_RUN, DBG_OK, 16'd0);
        repeat (50) @(negedge sys_clk);
        chk("bucle: LED RUNNING", tb_led[4:0], 5'b00100);
        chk("bucle: enable", u_dut.ex_enable, 1'b1);
        serie_tx(DBG_SOF_REQ);       // STATUS cortado: A5 02 y nada más
        serie_tx(DBG_CMD_STATUS);
        t0 = rx_n;
        boton(60);
        // Con el botón apretado: reset, core detenido y latido quieto
        chk("botón: LED de reset", tb_led[14], 1'b1);
        chk("botón: core detenido", u_dut.ex_enable, 1'b0);
        chk("botón: core en reset", u_dut.ex_core_rst, 1'b1);
        repeat (40) @(negedge sys_clk);
        chk("botón: reset liberado", tb_led[14], 1'b0);
        chk("botón: LED NO_PROG", tb_led[4:0], 5'b00001);
        repeat (4 * BYTE_CYC) @(negedge sys_clk);
        chk("botón: la petición cortada no responde", rx_n, t0);

        cmd0(DBG_CMD_STATUS);
        esperar_resp("STATUS después del botón", DBG_CMD_STATUS, DBG_OK, 16'd12);
        chk_bloque("STATUS después del botón", 0, DBG_ST_NO_PROG, 8'h00, 16'd0, 32'h0, 32'd0);
        cmd0(DBG_CMD_RUN);
        esperar_resp("RUN sin programa", DBG_CMD_RUN, DBG_ERR_STATE, 16'd0);

        //--------------------------------------------------------------
        // Latido: dos cambios seguidos separados por HB_HALF ciclos, y
        // quieto en 0 con el botón apretado
        //--------------------------------------------------------------
        @(negedge sys_clk);
        hb_ant = tb_led[15];
        for (c = 0; c < 2 * HB_HALF && tb_led[15] === hb_ant; c = c + 1) @(negedge sys_clk);
        hb_ant = tb_led[15];
        n_ciclos = 0;
        for (c = 0; c < 2 * HB_HALF && tb_led[15] === hb_ant; c = c + 1) begin
            @(negedge sys_clk);
            n_ciclos = n_ciclos + 1;
        end
        chk("latido: medio período", n_ciclos, HB_HALF);

        @(negedge sys_clk);
        #3;
        tb_btn = 1'b1;
        repeat (5) @(negedge sys_clk);
        n_hb = 0;
        for (c = 0; c < 2 * HB_HALF; c = c + 1) begin
            @(negedge sys_clk);
            if (tb_led[15] !== 1'b0) n_hb = n_hb + 1;
        end
        #3;
        tb_btn = 1'b0;
        chk("latido: apagado con el botón", n_hb, 0);
        repeat (40) @(negedge sys_clk);

        //--------------------------------------------------------------
        // Final
        //--------------------------------------------------------------
        repeat (4 * BYTE_CYC) @(negedge sys_clk);
        chk("línea: sin bytes de más", rx_n - rx_rd, 0);
        chk("línea: sin stop en 0", rx_bad, 0);
        chk("LEDs en todos los ciclos", led_mal, 0);

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
