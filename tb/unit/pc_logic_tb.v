`timescale 1ns / 1ps

//======================================================================
// pc_logic_tb
//
// Testbench autoverificante de pc_logic (docs/spec/verificacion.md §3.1).
//
// Casos:
//   - Reset a 0x0000_0000, también con en_pc = 0 y con redirect (rst > en)
//   - Avance de a 4
//   - en_pc = 0 retiene, también con redirect = 1 (decisión 018)
//   - stop_fetch retiene; redirect gana sobre stop_fetch (pipeline.md §3.1)
//   - Destinos desalineados y fuera de rango pasan sin enmascarar (memoria.md §6)
//   - 0xFFFF_FFFC + 4 vuelve a 0
//   - Barrido exhaustivo de {rst, en_pc, redirect, stop_fetch}
//   - Estímulo aleatorio con semilla fija contra un modelo de §3.1
//
// Los estímulos cambian en el flanco de bajada y se comprueban en el
// flanco de bajada siguiente, después de un flanco de subida.
//======================================================================

module pc_logic_tb;

    localparam integer NB_PC      = 32;
    localparam integer T_CLK      = 10;     // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM   = 2000;   // ciclos de estímulo aleatorio
    localparam integer MAX_CYCLES = 5000;   // watchdog
    localparam integer SEED       = 31;     // semilla fija (issue #31)

    localparam [NB_PC-1:0] PC_RST = 32'h0000_0000;

    reg              tb_clk;
    reg              tb_rst;
    reg              tb_en_pc;
    reg              tb_redirect;
    reg  [NB_PC-1:0] tb_redirect_pc;
    reg              tb_stop_fetch;
    wire [NB_PC-1:0] tb_pc;

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer combo;

    reg [NB_PC-1:0] modelo_pc;

    pc_logic #(
        .NB_PC (NB_PC)
    ) u_dut (
        .i_clk         (tb_clk),
        .i_rst         (tb_rst),
        .i_en_pc       (tb_en_pc),
        .i_redirect    (tb_redirect),
        .i_redirect_pc (tb_redirect_pc),
        .i_stop_fetch  (tb_stop_fetch),
        .o_pc          (tb_pc)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Modelo de referencia, escrito a partir de pipeline.md §3.1 y de
    // la decisión 018 (rst > en_pc; en_pc gana sobre redirect)
    //------------------------------------------------------------------
    function [NB_PC-1:0] pc_esperado;
        input [NB_PC-1:0] pc;
        input             rst;
        input             en;
        input             redirect;
        input [NB_PC-1:0] redirect_pc;
        input             stop_fetch;
        begin
            if (rst)
                pc_esperado = PC_RST;
            else if (!en)
                pc_esperado = pc;
            else if (redirect)
                pc_esperado = redirect_pc;
            else if (stop_fetch)
                pc_esperado = pc;
            else
                pc_esperado = pc + 32'd4;
        end
    endfunction

    //------------------------------------------------------------------
    // Chequeo con etiqueta, para que el log diga qué caso falló
    //------------------------------------------------------------------
    task chk;
        input [8*40-1:0]  name;
        input [NB_PC-1:0] obtenido;
        input [NB_PC-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | dut=0x%08h esperado=0x%08h",
                         $time, name, obtenido, esperado);
            end
        end
    endtask

    // Aplica un juego de entradas durante un ciclo (un flanco de subida)
    task ciclo;
        input             rst;
        input             en;
        input             redirect;
        input [NB_PC-1:0] redirect_pc;
        input             stop_fetch;
        begin
            tb_rst         = rst;
            tb_en_pc       = en;
            tb_redirect    = redirect;
            tb_redirect_pc = redirect_pc;
            tb_stop_fetch  = stop_fetch;
            @(negedge tb_clk);
        end
    endtask

    // Ciclo normal: sin reset, habilitado, sin salto ni HALT
    task avanzar;
        begin
            ciclo(1'b0, 1'b1, 1'b0, 32'hDEAD_BEEF, 1'b0);
        end
    endtask

    // Lleva el PC a una dirección conocida con un salto
    task saltar;
        input [NB_PC-1:0] destino;
        begin
            ciclo(1'b0, 1'b1, 1'b1, destino, 1'b0);
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors         = 0;
        checks         = 0;
        seed           = SEED;
        tb_rst         = 1'b1;
        tb_en_pc       = 1'b0;
        tb_redirect    = 1'b0;
        tb_redirect_pc = {NB_PC{1'b0}};
        tb_stop_fetch  = 1'b0;

        // Reset
        @(negedge tb_clk);
        ciclo(1'b1, 1'b1, 1'b0, 32'h0, 1'b0);
        chk("reset", tb_pc, 32'h0000_0000);

        // Avance de a 4
        avanzar; chk("pc + 4 (1)", tb_pc, 32'h0000_0004);
        avanzar; chk("pc + 4 (2)", tb_pc, 32'h0000_0008);
        avanzar; chk("pc + 4 (3)", tb_pc, 32'h0000_000C);
        avanzar; chk("pc + 4 (4)", tb_pc, 32'h0000_0010);

        // en_pc = 0 retiene
        for (i = 0; i < 3; i = i + 1) begin
            ciclo(1'b0, 1'b0, 1'b0, 32'h0, 1'b0);
            chk("en_pc = 0 retiene", tb_pc, 32'h0000_0010);
        end

        // stop_fetch retiene
        for (i = 0; i < 3; i = i + 1) begin
            ciclo(1'b0, 1'b1, 1'b0, 32'h0, 1'b1);
            chk("stop_fetch retiene", tb_pc, 32'h0000_0010);
        end

        // Al soltar stop_fetch sigue de a 4
        avanzar; chk("sigue tras stop_fetch", tb_pc, 32'h0000_0014);

        // redirect
        saltar(32'h0000_0100);
        chk("redirect", tb_pc, 32'h0000_0100);
        avanzar; chk("pc + 4 tras redirect", tb_pc, 32'h0000_0104);

        // redirect gana sobre stop_fetch
        ciclo(1'b0, 1'b1, 1'b1, 32'h0000_0200, 1'b1);
        chk("redirect > stop_fetch", tb_pc, 32'h0000_0200);

        // en_pc = 0 gana sobre redirect: con el core detenido el PC no cambia
        ciclo(1'b0, 1'b0, 1'b1, 32'h0000_0300, 1'b0);
        chk("en_pc = 0 retiene con redirect", tb_pc, 32'h0000_0200);
        ciclo(1'b0, 1'b0, 1'b1, 32'h0000_0300, 1'b1);
        chk("en_pc = 0 retiene con todo", tb_pc, 32'h0000_0200);
        // El mismo salto, ya habilitado, se toma
        ciclo(1'b0, 1'b1, 1'b1, 32'h0000_0300, 1'b0);
        chk("redirect al habilitar", tb_pc, 32'h0000_0300);

        // rst gana sobre en_pc y sobre redirect
        ciclo(1'b0, 1'b1, 1'b1, 32'h0000_0ABC, 1'b0);
        ciclo(1'b1, 1'b0, 1'b0, 32'h0, 1'b0);
        chk("rst con en_pc = 0", tb_pc, 32'h0000_0000);
        saltar(32'h0000_0ABC);
        ciclo(1'b1, 1'b1, 1'b1, 32'h0000_0F00, 1'b1);
        chk("rst con redirect y stop_fetch", tb_pc, 32'h0000_0000);

        // Destinos que no se enmascaran (imem_fault los detecta después)
        saltar(32'h0000_0FFE);
        chk("destino con pc[1:0] = 10", tb_pc, 32'h0000_0FFE);
        avanzar; chk("desalineado + 4", tb_pc, 32'h0000_1002);
        saltar(32'h8000_2000);
        chk("destino fuera de rango", tb_pc, 32'h8000_2000);

        // Vuelta de 0xFFFF_FFFC a 0
        saltar(32'hFFFF_FFFC);
        chk("pc = 0xFFFF_FFFC", tb_pc, 32'hFFFF_FFFC);
        avanzar; chk("0xFFFF_FFFC + 4", tb_pc, 32'h0000_0000);

        // Barrido exhaustivo de {rst, en_pc, redirect, stop_fetch} desde un
        // PC conocido distinto de 0 y del destino
        for (combo = 0; combo < 16; combo = combo + 1) begin
            saltar(32'h0000_0040);
            ciclo(combo[3], combo[2], combo[1], 32'h0000_0800, combo[0]);
            chk("barrido {rst,en,redirect,stop}", tb_pc,
                pc_esperado(32'h0000_0040, combo[3], combo[2], combo[1],
                            32'h0000_0800, combo[0]));
            if (tb_pc !== pc_esperado(32'h0000_0040, combo[3], combo[2], combo[1],
                                      32'h0000_0800, combo[0]))
                $display("        combo {rst,en,redirect,stop} = %b", combo[3:0]);
        end

        // Estímulo aleatorio con semilla fija contra el modelo
        ciclo(1'b1, 1'b1, 1'b0, 32'h0, 1'b0);
        modelo_pc = PC_RST;
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            tb_rst         = (($random(seed) & 31) == 0);   // 1/32
            tb_en_pc       = (($random(seed) & 3)  != 0);   // 3/4
            tb_redirect    = (($random(seed) & 7)  == 0);   // 1/8
            tb_redirect_pc = $random(seed);
            tb_stop_fetch  = (($random(seed) & 7)  == 0);   // 1/8
            modelo_pc = pc_esperado(modelo_pc, tb_rst, tb_en_pc, tb_redirect,
                                    tb_redirect_pc, tb_stop_fetch);
            @(negedge tb_clk);
            chk("aleatorio", tb_pc, modelo_pc);
        end

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
