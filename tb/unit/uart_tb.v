`timescale 1ns / 1ps

//======================================================================
// uart_tb
//
// Testbench autoverificante de uart, la UART de la Debug Unit
// (docs/spec/verificacion.md §3.3, protocolo_debug.md §1, decisiones 003
// y 035).
//
// Oráculo, escrito aparte del RTL: un transmisor y un receptor serie del
// testbench (start en 0, 8 datos LSB primero, stop en 1, con el tiempo de
// bit dado en ns) y la lista de bytes que se mandaron. El receptor
// muestrea en el medio de cada bit y verifica el start y el stop. Los
// DVSR esperados son los de la tabla de protocolo_debug.md §1, escritos a
// mano.
//
// DUT:
//   u_dut     CLK_FREQ_HZ = 64 × 115200: DVSR = 4, un bit = 64 ciclos
//             (simulación rápida; la lógica es la misma que en la placa)
//   u_dut_100 CLK_FREQ_HZ = 100 MHz, BAUD = 115200: DVSR = 54. El
//             testbench le habla a 115200 exactos, como la PC
//   u_dvsr_*  80, 75 y 50 MHz, solo para comparar DVSR con la tabla
//
// Casos:
//   - DVSR y error de baudrate para 100, 80, 75 y 50 MHz (menor al 2 %)
//   - Loopback TX -> RX: 64 bytes aleatorios escritos de a uno con wr,
//     decodificados en tx por el receptor del testbench y leídos de la
//     FIFO en el mismo orden
//   - Tramas seguidas sin pausa entre bytes y sin leer: los 32 se
//     conservan; con 33, el último se descarta
//   - Recepción mientras se transmite: 17 bytes salen (un EVT_HALTED)
//     mientras llega una petición de 5; la petición queda entera en la
//     FIFO (decisión 035)
//   - wr con tx_full = 1: se ignora, sale un solo byte. También en el
//     último ciclo del stop bit (u_dut.tx_done_tick, leído por jerarquía),
//     cuando uart_tx lo tomaría si no se ignorara
//   - rd con la FIFO vacía: no tiene efecto
//   - Byte con stop en 0: su dato no entra a la FIFO; entra el 0xFF del
//     falso start que deja uart_rx del TP2 (decisión 035)
//   - Reset con bytes en la FIFO y en medio de una transmisión
//   - A velocidad real (u_dut_100): bytes a 115200 exactos recibidos con
//     DVSR = 54, y bytes transmitidos decodificados a 115200
// Semilla fija para los bytes aleatorios.
//======================================================================

module uart_tb;

    localparam integer NB_DATA  = 8;
    localparam integer T_CLK    = 10;            // ns, 100 MHz
    localparam integer BAUD     = 115200;
    localparam integer F_RAPIDO = 64 * BAUD;     // DVSR = 4
    localparam integer SEED     = 56;
    localparam integer N_LOOP   = 64;
    localparam integer MAX_TIME = 20_000_000;    // ns, watchdog

    // Tiempo de bit del testbench (oráculo): 16 ticks de DVSR ciclos
    localparam real BIT_RAPIDO = 16.0 * 4 * T_CLK;    // 640 ns
    localparam real BIT_PC     = 1.0e9 / BAUD;         // 8680,6 ns: la PC
    localparam integer TIMEOUT = 40 * 16 * 4;          // ciclos: ~4 bytes rápidos

    reg                tb_clk;
    reg                tb_rst;

    // u_dut (rápido)
    reg                tb_loopback;
    reg                tb_rx_drv;
    wire               tb_o_tx;
    wire               tb_rx = tb_loopback ? tb_o_tx : tb_rx_drv;
    wire [NB_DATA-1:0] tb_o_r_data;
    wire               tb_o_rx_empty;
    reg                tb_rd;
    reg  [NB_DATA-1:0] tb_w_data;
    reg                tb_wr;
    wire               tb_o_tx_full;

    // u_dut_100 (velocidad real)
    reg                tb_rx_100;
    wire               tb_o_tx_100;
    wire [NB_DATA-1:0] tb_o_r_data_100;
    wire               tb_o_rx_empty_100;
    reg                tb_rd_100;
    reg  [NB_DATA-1:0] tb_w_data_100;
    reg                tb_wr_100;
    wire               tb_o_tx_full_100;

    // Receptor del testbench: línea que observa
    reg                mon_sel;          // 0: u_dut, 1: u_dut_100
    wire               mon_line = mon_sel ? tb_o_tx_100 : tb_o_tx;

    reg  [NB_DATA-1:0] exp_b   [0:N_LOOP-1];
    reg  [NB_DATA-1:0] got_tx  [0:N_LOOP-1];
    reg  [NB_DATA-1:0] got_rx  [0:N_LOOP-1];

    integer errors;
    integer checks;
    integer seed;
    integer k;
    integer n_tx;
    integer n_rx;
    reg     ok;
    reg  [NB_DATA-1:0] b;
    real    baud_real;
    real    err_pct;

    uart #(
        .CLK_FREQ_HZ (F_RAPIDO),
        .BAUD        (BAUD)
    ) u_dut (
        .i_clk      (tb_clk),
        .i_rst      (tb_rst),
        .i_rx       (tb_rx),
        .o_tx       (tb_o_tx),
        .o_r_data   (tb_o_r_data),
        .o_rx_empty (tb_o_rx_empty),
        .i_rd       (tb_rd),
        .i_w_data   (tb_w_data),
        .i_wr       (tb_wr),
        .o_tx_full  (tb_o_tx_full)
    );

    uart #(
        .CLK_FREQ_HZ (100_000_000),
        .BAUD        (BAUD)
    ) u_dut_100 (
        .i_clk      (tb_clk),
        .i_rst      (tb_rst),
        .i_rx       (tb_rx_100),
        .o_tx       (tb_o_tx_100),
        .o_r_data   (tb_o_r_data_100),
        .o_rx_empty (tb_o_rx_empty_100),
        .i_rd       (tb_rd_100),
        .i_w_data   (tb_w_data_100),
        .i_wr       (tb_wr_100),
        .o_tx_full  (tb_o_tx_full_100)
    );

    // Solo para leer el DVSR que calculan (entradas en reposo)
    uart #(.CLK_FREQ_HZ (80_000_000), .BAUD (BAUD)) u_dvsr_80 (
        .i_clk (tb_clk), .i_rst (tb_rst), .i_rx (1'b1), .o_tx (), .o_r_data (),
        .o_rx_empty (), .i_rd (1'b0), .i_w_data (8'h00), .i_wr (1'b0), .o_tx_full ());
    uart #(.CLK_FREQ_HZ (75_000_000), .BAUD (BAUD)) u_dvsr_75 (
        .i_clk (tb_clk), .i_rst (tb_rst), .i_rx (1'b1), .o_tx (), .o_r_data (),
        .o_rx_empty (), .i_rd (1'b0), .i_w_data (8'h00), .i_wr (1'b0), .o_tx_full ());
    uart #(.CLK_FREQ_HZ (50_000_000), .BAUD (BAUD)) u_dvsr_50 (
        .i_clk (tb_clk), .i_rst (tb_rst), .i_rx (1'b1), .o_tx (), .o_r_data (),
        .o_rx_empty (), .i_rd (1'b0), .i_w_data (8'h00), .i_wr (1'b0), .o_tx_full ());

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    task chk;
        input [8*48-1:0] name;
        input [31:0]     obtenido;
        input [31:0]     esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                if (errors <= 30)
                    $display("[%0t] ERROR %0s | dut=0x%0h esperado=0x%0h",
                             $time, name, obtenido, esperado);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Transmisor del testbench: un byte por la línea rx de u_dut (sel 0)
    // o de u_dut_100 (sel 1), con el stop bit elegido
    //------------------------------------------------------------------
    task serie_tx;
        input               sel;
        input [NB_DATA-1:0] dato;
        input               stop;
        input real          bit_ns;
        integer             j;
        begin
            if (sel) tb_rx_100 = 1'b0; else tb_rx_drv = 1'b0;      // start
            #(bit_ns);
            for (j = 0; j < NB_DATA; j = j + 1) begin              // LSB primero
                if (sel) tb_rx_100 = dato[j]; else tb_rx_drv = dato[j];
                #(bit_ns);
            end
            if (sel) tb_rx_100 = stop; else tb_rx_drv = stop;      // stop
            #(bit_ns);
            if (sel) tb_rx_100 = 1'b1; else tb_rx_drv = 1'b1;      // reposo
        end
    endtask

    //------------------------------------------------------------------
    // Receptor del testbench: espera un start en mon_line y muestrea en
    // el medio de cada bit. ok = 0 si el start o el stop están mal, o si
    // no llega nada en max_ns
    //------------------------------------------------------------------
    task serie_rx;
        input real              bit_ns;
        input real              max_ns;
        output reg [NB_DATA-1:0] dato;
        output reg               bien;
        integer                  j;
        begin
            bien = 1'b0;
            dato = {NB_DATA{1'bx}};
            fork : espera
                begin @(negedge mon_line); bien = 1'b1; disable espera; end
                begin #(max_ns); disable espera; end
            join
            if (bien) begin
                #(bit_ns / 2.0);
                if (mon_line !== 1'b0) bien = 1'b0;               // start
                for (j = 0; j < NB_DATA; j = j + 1) begin
                    #(bit_ns);
                    dato[j] = mon_line;
                end
                #(bit_ns);
                if (mon_line !== 1'b1) bien = 1'b0;               // stop
            end
        end
    endtask

    // Escribe un byte en u_dut: espera tx_full = 0 y da un pulso de wr
    task escribir;
        input [NB_DATA-1:0] dato;
        begin
            @(negedge tb_clk);
            while (tb_o_tx_full) @(negedge tb_clk);
            tb_w_data = dato;
            tb_wr     = 1'b1;
            @(negedge tb_clk);
            tb_wr     = 1'b0;
        end
    endtask

    // Lee un byte de la FIFO de u_dut (o de u_dut_100): espera
    // rx_empty = 0 hasta max_ciclos y da un pulso de rd
    task leer;
        input                    sel;
        input integer            max_ciclos;
        output reg [NB_DATA-1:0] dato;
        output reg               bien;
        integer                  c;
        begin
            bien = 1'b0;
            dato = {NB_DATA{1'bx}};
            @(negedge tb_clk);
            for (c = 0; c < max_ciclos && !bien; c = c + 1) begin
                if (!(sel ? tb_o_rx_empty_100 : tb_o_rx_empty)) begin
                    bien = 1'b1;
                    dato = sel ? tb_o_r_data_100 : tb_o_r_data;
                    if (sel) tb_rd_100 = 1'b1; else tb_rd = 1'b1;
                    @(negedge tb_clk);
                    tb_rd     = 1'b0;
                    tb_rd_100 = 1'b0;
                end
                else
                    @(negedge tb_clk);
            end
        end
    endtask

    // Espera que la línea de u_dut quede en reposo n bits rápidos
    task reposo;
        input integer n_bits;
        begin
            #(n_bits * BIT_RAPIDO);
        end
    endtask

    task dvsr;
        input [8*16-1:0] name;
        input integer    f_clk;
        input integer    obtenido;
        input integer    esperado;
        begin
            chk(name, obtenido, esperado);
            baud_real = f_clk / (16.0 * obtenido);
            err_pct   = (baud_real - BAUD) * 100.0 / BAUD;
            chk({name, " error < 2 %"}, (err_pct < 2.0 && err_pct > -2.0), 1'b1);
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors = 0;  checks = 0;  seed = SEED;
        tb_rst = 1'b1;
        tb_loopback = 1'b0;  tb_rx_drv = 1'b1;  tb_rx_100 = 1'b1;
        tb_rd = 1'b0;  tb_wr = 1'b0;  tb_w_data = 8'h00;
        tb_rd_100 = 1'b0;  tb_wr_100 = 1'b0;  tb_w_data_100 = 8'h00;
        mon_sel = 1'b0;
        repeat (4) @(negedge tb_clk);
        tb_rst = 1'b0;
        @(negedge tb_clk);
        chk("reset: tx en reposo", tb_o_tx, 1'b1);
        chk("reset: FIFO vacia", tb_o_rx_empty, 1'b1);
        chk("reset: tx_full", tb_o_tx_full, 1'b0);

        // DVSR (protocolo_debug.md §1): 100 MHz 54, 80 MHz 43, 75 MHz 41, 50 MHz 27
        dvsr("DVSR 100 MHz", 100_000_000, u_dut_100.DVSR, 54);
        dvsr("DVSR 80 MHz",   80_000_000, u_dvsr_80.DVSR, 43);
        dvsr("DVSR 75 MHz",   75_000_000, u_dvsr_75.DVSR, 41);
        dvsr("DVSR 50 MHz",   50_000_000, u_dvsr_50.DVSR, 27);
        chk("DVSR del DUT rapido", u_dut.DVSR, 4);

        // Loopback TX -> RX
        tb_loopback = 1'b1;
        for (k = 0; k < N_LOOP; k = k + 1)
            exp_b[k] = $random(seed);
        exp_b[0] = 8'h00;  exp_b[1] = 8'hFF;  exp_b[2] = 8'hA5;  exp_b[3] = 8'h5A;
        n_tx = 0;  n_rx = 0;
        fork
            for (k = 0; k < N_LOOP; k = k + 1)
                escribir(exp_b[k]);
            begin : mon_loop
                integer m;
                reg [NB_DATA-1:0] bm;
                reg okm;
                for (m = 0; m < N_LOOP; m = m + 1) begin
                    serie_rx(BIT_RAPIDO, 30 * BIT_RAPIDO, bm, okm);
                    chk("loopback: trama en tx", okm, 1'b1);
                    got_tx[m] = bm;
                    if (okm) n_tx = n_tx + 1;
                end
            end
            begin : lec_loop
                integer m;
                reg [NB_DATA-1:0] bl;
                reg okl;
                for (m = 0; m < N_LOOP; m = m + 1) begin
                    leer(1'b0, TIMEOUT, bl, okl);
                    got_rx[m] = bl;
                    if (okl) n_rx = n_rx + 1;
                end
            end
        join
        chk("loopback: bytes en tx", n_tx, N_LOOP);
        chk("loopback: bytes leidos", n_rx, N_LOOP);
        for (k = 0; k < N_LOOP; k = k + 1) begin
            chk("loopback: byte en tx", got_tx[k], exp_b[k]);
            chk("loopback: byte leido", got_rx[k], exp_b[k]);
        end
        chk("loopback: FIFO vacia al final", tb_o_rx_empty, 1'b1);
        tb_loopback = 1'b0;
        reposo(4);

        // Tramas seguidas sin leer: 32 se conservan
        for (k = 0; k < 32; k = k + 1)
            serie_tx(1'b0, exp_b[k], 1'b1, BIT_RAPIDO);
        reposo(2);
        for (k = 0; k < 32; k = k + 1) begin
            leer(1'b0, 4, b, ok);
            chk("32 seguidas: hay byte", ok, 1'b1);
            chk("32 seguidas: byte", b, exp_b[k]);
        end
        chk("32 seguidas: FIFO vacia", tb_o_rx_empty, 1'b1);

        // 33 seguidas sin leer: el 33 se descarta
        for (k = 0; k < 33; k = k + 1)
            serie_tx(1'b0, exp_b[k + 8], 1'b1, BIT_RAPIDO);
        reposo(2);
        for (k = 0; k < 32; k = k + 1) begin
            leer(1'b0, 4, b, ok);
            chk("33 seguidas: hay byte", ok, 1'b1);
            chk("33 seguidas: byte", b, exp_b[k + 8]);
        end
        chk("33 seguidas: el 33 no entro", tb_o_rx_empty, 1'b1);

        // Recepción mientras se transmite: 17 bytes salen y llegan 5
        n_tx = 0;
        fork
            for (k = 0; k < 17; k = k + 1)
                escribir(exp_b[k + 20]);
            begin : mon_evt
                integer m;
                reg [NB_DATA-1:0] bm;
                reg okm;
                for (m = 0; m < 17; m = m + 1) begin
                    serie_rx(BIT_RAPIDO, 30 * BIT_RAPIDO, bm, okm);
                    chk("evento: trama en tx", okm, 1'b1);
                    chk("evento: byte en tx", bm, exp_b[m + 20]);
                    if (okm) n_tx = n_tx + 1;
                end
            end
            begin : pet_evt
                integer m;
                #(3.5 * BIT_RAPIDO);                  // empieza con tx ocupado
                for (m = 0; m < 5; m = m + 1)
                    serie_tx(1'b0, exp_b[m + 40], 1'b1, BIT_RAPIDO);
            end
        join
        chk("evento: 17 bytes en tx", n_tx, 17);
        for (k = 0; k < 5; k = k + 1) begin
            leer(1'b0, 4, b, ok);
            chk("evento: peticion entera", ok, 1'b1);
            chk("evento: byte de la peticion", b, exp_b[k + 40]);
        end
        chk("evento: FIFO vacia", tb_o_rx_empty, 1'b1);
        reposo(4);

        // wr con tx_full = 1: se ignora
        fork
            begin
                escribir(8'h3C);
                @(negedge tb_clk);
                chk("wr ignorado: tx_full", tb_o_tx_full, 1'b1);
                tb_w_data = 8'hC3;              // otro byte con tx_full = 1
                tb_wr     = 1'b1;
                @(negedge tb_clk);
                tb_wr     = 1'b0;
            end
            begin : mon_full
                reg [NB_DATA-1:0] bm;
                reg okm;
                serie_rx(BIT_RAPIDO, 30 * BIT_RAPIDO, bm, okm);
                chk("wr ignorado: sale el primero", okm, 1'b1);
                chk("wr ignorado: byte", bm, 8'h3C);
                serie_rx(BIT_RAPIDO, 30 * BIT_RAPIDO, bm, okm);
                chk("wr ignorado: no sale otro", okm, 1'b0);
            end
        join
        chk("wr ignorado: tx_full al final", tb_o_tx_full, 1'b0);

        // wr con tx_full = 1 en el último ciclo del stop bit (tx_done_tick):
        // uart_tx vuelve a reposo en el ciclo siguiente y lo tomaría, así que
        // es el único ciclo en que importa que wr se ignore con tx_full = 1
        fork
            begin
                escribir(8'h3C);
                while (!u_dut.tx_done_tick) @(negedge tb_clk);
                chk("wr en el fin del stop: tx_full", tb_o_tx_full, 1'b1);
                tb_w_data = 8'hC3;
                tb_wr     = 1'b1;
                @(negedge tb_clk);
                tb_wr     = 1'b0;
            end
            begin : mon_fin
                reg [NB_DATA-1:0] bm;
                reg okm;
                serie_rx(BIT_RAPIDO, 30 * BIT_RAPIDO, bm, okm);
                chk("wr en el fin del stop: sale el primero", okm, 1'b1);
                chk("wr en el fin del stop: byte", bm, 8'h3C);
                serie_rx(BIT_RAPIDO, 30 * BIT_RAPIDO, bm, okm);
                chk("wr en el fin del stop: no sale otro", okm, 1'b0);
            end
        join
        chk("wr en el fin del stop: tx_full al final", tb_o_tx_full, 1'b0);

        // rd con la FIFO vacía: no tiene efecto
        @(negedge tb_clk);
        tb_rd = 1'b1;
        @(negedge tb_clk);
        tb_rd = 1'b0;
        chk("rd con vacia: sigue vacia", tb_o_rx_empty, 1'b1);
        serie_tx(1'b0, 8'h96, 1'b1, BIT_RAPIDO);
        leer(1'b0, TIMEOUT, b, ok);
        chk("rd con vacia: llega el siguiente", ok, 1'b1);
        chk("rd con vacia: byte", b, 8'h96);
        chk("rd con vacia: vacia otra vez", tb_o_rx_empty, 1'b1);

        // Byte con stop en 0: su dato no entra. uart_rx (TP2) no vuelve a
        // mirar la línea en el medio del start bit: vuelve a reposo en el
        // medio del stop, ve la línea todavía en 0 como un start y recibe
        // los 1 del reposo, así que entra un 0xFF (decisión 035)
        serie_tx(1'b0, 8'h5A, 1'b0, BIT_RAPIDO);
        reposo(14);
        leer(1'b0, 2, b, ok);
        chk("stop en 0: entra el 0xFF del falso start", ok, 1'b1);
        chk("stop en 0: no entra su dato", b, 8'hFF);
        chk("stop en 0: nada mas", tb_o_rx_empty, 1'b1);
        serie_tx(1'b0, 8'h69, 1'b1, BIT_RAPIDO);
        leer(1'b0, TIMEOUT, b, ok);
        chk("stop en 0: el siguiente llega", ok, 1'b1);
        chk("stop en 0: byte siguiente", b, 8'h69);

        // Reset con bytes en la FIFO y en medio de una transmisión
        serie_tx(1'b0, 8'h11, 1'b1, BIT_RAPIDO);
        serie_tx(1'b0, 8'h22, 1'b1, BIT_RAPIDO);
        reposo(2);
        chk("antes del reset: FIFO con datos", tb_o_rx_empty, 1'b0);
        escribir(8'h0F);
        #(4.5 * BIT_RAPIDO);                          // en medio del byte
        @(negedge tb_clk);
        tb_rst = 1'b1;
        @(negedge tb_clk);
        tb_rst = 1'b0;
        chk("reset: FIFO vacia", tb_o_rx_empty, 1'b1);
        chk("reset: tx_full", tb_o_tx_full, 1'b0);
        @(negedge tb_clk);
        chk("reset: tx en reposo", tb_o_tx, 1'b1);
        tb_loopback = 1'b1;
        fork
            escribir(8'h77);
            leer(1'b0, TIMEOUT, b, ok);
        join
        chk("despues del reset: loopback", ok, 1'b1);
        chk("despues del reset: byte", b, 8'h77);
        tb_loopback = 1'b0;

        // Velocidad real: 115200 exactos contra DVSR = 54
        for (k = 0; k < 3; k = k + 1) begin
            serie_tx(1'b1, exp_b[k + 1], 1'b1, BIT_PC);
            leer(1'b1, 2000, b, ok);
            chk("100 MHz: recibe a 115200", ok, 1'b1);
            chk("100 MHz: byte recibido", b, exp_b[k + 1]);
        end
        mon_sel = 1'b1;
        for (k = 0; k < 2; k = k + 1) begin
            fork
                begin
                    @(negedge tb_clk);
                    tb_w_data_100 = exp_b[k + 4];
                    tb_wr_100     = 1'b1;
                    @(negedge tb_clk);
                    tb_wr_100     = 1'b0;
                end
                serie_rx(BIT_PC, 3 * BIT_PC, b, ok);
            join
            chk("100 MHz: trama a 115200", ok, 1'b1);
            chk("100 MHz: byte transmitido", b, exp_b[k + 4]);
            while (tb_o_tx_full_100) @(negedge tb_clk);
        end

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
