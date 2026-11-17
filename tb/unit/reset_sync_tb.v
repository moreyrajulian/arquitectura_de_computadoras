`timescale 1ns / 1ps

//======================================================================
// reset_sync_tb
//
// Testbench autoverificante del reset del sistema en la placa (I-49,
// decisión 040, docs/spec/verificacion.md §3.3).
//
// DUT: reset_sync con los parámetros por defecto (los del top).
//
// Oráculo, escrito aparte del RTL: la cantidad de flancos de subida con
// o_rst = 1 contada por el testbench, contra la latencia del encabezado
// del módulo (sube 3 ciclos después de i_rst_req, baja POR_CYCLES + 3 ciclos
// después de soltarlo; el reset de encendido dura POR_CYCLES + 1 ciclos).
//
// Casos:
//   - Reset de encendido: o_rst = 1 desde el tiempo 0, sin esperar nada,
//     durante POR_CYCLES + 1 ciclos
//   - Botón apretado a destiempo del reloj (i_rst_req cambia lejos del
//     flanco): sube a los 3 ciclos y baja POR_CYCLES + 3 después de
//     soltarlo
//   - Botón apretado durante el reset de encendido: lo alarga
//   - Rebotes al apretar y al soltar: o_rst no baja hasta POR_CYCLES + 3
//     ciclos después del último rebote
//   - Un pulso del botón de un solo ciclo también da un reset completo
//   - Monitores en todos los casos: o_rst solo cambia justo después de un
//     flanco de subida (sale de un registro) y cada reset dura al menos
//     POR_CYCLES + 1 ciclos
// Aleatoriedad: el largo de los rebotes, con semilla fija (SEED).
//======================================================================

module reset_sync_tb;

    localparam integer T_CLK      = 10;     // ns
    localparam integer POR_CYCLES = 16;     // los valores por defecto del DUT
    localparam integer MAX_CYCLES = 5000;   // watchdog
    localparam integer SEED       = 40;

    reg  tb_clk;
    reg  tb_btn;
    wire tb_o_rst;

    integer errors;
    integer checks;
    integer seed;

    reset_sync u_dut (
        .i_clk     (tb_clk),
        .i_rst_req (tb_btn),
        .o_rst     (tb_o_rst)
    );

    // Flancos de subida en 5, 15, 25 ... ns
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
                $display("[%0t] ERROR %0s | dut=0x%0h esperado=0x%0h",
                         $time, name, obtenido, esperado);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Monitores
    //------------------------------------------------------------------
    // o_rst sale de un registro: cambia 0 ns después de un flanco de
    // subida (con la semántica de <=, en el mismo instante)
    integer mon_async;
    always @(tb_o_rst)
        if ($time > 0 && ($time % T_CLK) != T_CLK/2)
            mon_async = mon_async + 1;

    // Largo de cada reset, en flancos de subida con o_rst = 1
    integer largo;
    integer mon_corto;
    always @(posedge tb_clk) begin
        if (tb_o_rst)
            largo = largo + 1;
        else if (largo > 0) begin
            if (largo < POR_CYCLES + 1) mon_corto = mon_corto + 1;
            largo = 0;
        end
    end

    // Flancos de subida hasta que o_rst valga v (máximo lim); el flanco
    // que lo cambia cuenta
    task flancos_hasta;
        input         v;
        input integer lim;
        output integer n;
        begin
            n = 0;
            while (tb_o_rst !== v && n < lim) begin
                @(posedge tb_clk);
                #1;
                n = n + 1;
            end
        end
    endtask

    // Cambia i_rst_req a mitad de ciclo, lejos del flanco
    task btn_a_destiempo;
        input v;
        begin
            @(negedge tb_clk);
            #2;
            tb_btn = v;
        end
    endtask

    integer n;
    integer k;
    integer espera;

    initial begin
        errors = 0;  checks = 0;  seed = SEED;
        mon_async = 0;  mon_corto = 0;  largo = 0;
        tb_btn = 1'b0;

        //--------------------------------------------------------------
        // Reset de encendido
        //--------------------------------------------------------------
        #1;
        chk("POR: o_rst = 1 al arrancar", tb_o_rst, 1'b1);
        flancos_hasta(1'b0, 100, n);
        chk("POR: dura POR_CYCLES + 1 ciclos", n, POR_CYCLES + 1);
        repeat (20) @(posedge tb_clk);
        #1;
        chk("POR: queda en 0", tb_o_rst, 1'b0);

        //--------------------------------------------------------------
        // Botón apretado y soltado a destiempo
        //--------------------------------------------------------------
        btn_a_destiempo(1'b1);
        flancos_hasta(1'b1, 100, n);
        chk("botón: sube a los 3 ciclos", n, 3);
        repeat (40) @(posedge tb_clk);
        #1;
        chk("botón: sigue en 1 apretado", tb_o_rst, 1'b1);
        btn_a_destiempo(1'b0);
        flancos_hasta(1'b0, 100, n);
        chk("botón: baja POR_CYCLES + 3 después", n, POR_CYCLES + 3);

        //--------------------------------------------------------------
        // Pulso de un solo ciclo
        //--------------------------------------------------------------
        repeat (10) @(posedge tb_clk);
        btn_a_destiempo(1'b1);
        btn_a_destiempo(1'b0);
        flancos_hasta(1'b1, 100, n);
        chk("pulso: sube a los 2 ciclos de soltar", n, 2);
        flancos_hasta(1'b0, 100, n);
        chk("pulso: reset completo", n, POR_CYCLES + 1);

        //--------------------------------------------------------------
        // Rebotes al apretar y al soltar
        //--------------------------------------------------------------
        repeat (10) @(posedge tb_clk);
        for (k = 0; k < 12; k = k + 1) begin
            btn_a_destiempo(k % 2 == 0);
            espera = 1 + ($random(seed) & 32'h7);      // 1 a 8 ciclos
            repeat (espera) @(posedge tb_clk);
        end
        btn_a_destiempo(1'b1);
        repeat (30) @(posedge tb_clk);
        for (k = 0; k < 12; k = k + 1) begin
            btn_a_destiempo(k % 2 == 0 ? 1'b0 : 1'b1);
            espera = 1 + ($random(seed) & 32'h7);
            repeat (espera) @(posedge tb_clk);
            #1;
            chk("rebotes: o_rst sigue en 1", tb_o_rst, 1'b1);
        end
        btn_a_destiempo(1'b0);
        flancos_hasta(1'b0, 100, n);
        chk("rebotes: baja POR_CYCLES + 3 después del último", n, POR_CYCLES + 3);

        //--------------------------------------------------------------
        // Monitores
        //--------------------------------------------------------------
        repeat (5) @(posedge tb_clk);
        chk("monitor: o_rst solo cambia en el flanco", mon_async, 0);
        chk("monitor: ningún reset corto", mon_corto, 0);

        if (errors == 0)
            $display("TEST PASSED: %0d chequeos, 0 errores", checks);
        else
            $display("TEST FAILED: %0d errores sobre %0d chequeos", errors, checks);
        $finish;
    end

    initial begin
        repeat (MAX_CYCLES) @(posedge tb_clk);
        $display("TEST FAILED: timeout de %0d ciclos", MAX_CYCLES);
        $finish;
    end

endmodule
