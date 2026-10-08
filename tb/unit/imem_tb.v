`timescale 1ns / 1ps

//======================================================================
// imem_tb
//
// Testbench autoverificante de imem (docs/spec/verificacion.md §3.1).
// Simula el IP imem_bram, así que corre en xsim dentro del proyecto de
// Vivado; necesita ~31 µs (run all), más que los 1000 ns por defecto.
//
// Casos:
//   - Contenido inicial HALT en las 1024 palabras (memoria.md §3.2, §3.6)
//   - Escritura de las 1024 palabras por el puerto B con el puerto A
//     deshabilitado, como LOAD (memoria.md §4), y relectura por el A
//   - Latencia de un ciclo: el dato de la dirección a aparece en el
//     flanco siguiente, no antes (decisión 009)
//   - i_a_en = 0 conserva la salida aunque cambie la dirección
//   - Alias: pc >= 0x1000 y pc[1:0] != 00 leen imem[pc[11:2]]
//     (memoria.md §6.1)
//   - Puerto B: en = 1 con we = 0 no escribe; we = 1 con en = 0 tampoco
//   - Reescribir una palabra no toca las vecinas
//
// No lee el arreglo interno del IP por jerarquía: su ruta depende de la
// versión del Block Memory Generator. Todo se comprueba por el puerto A.
//
// Los estímulos cambian en el flanco de bajada y se comprueban en el
// flanco de bajada siguiente, después de un flanco de subida.
//======================================================================

module imem_tb;

    localparam integer NB_DATA    = 32;
    localparam integer NB_ADDR    = 32;
    localparam integer IMEM_AW    = 10;
    localparam integer IMEM_WORDS = 1 << IMEM_AW;
    localparam integer T_CLK      = 10;     // ns, 100 MHz como la Basys 3
    localparam integer MAX_CYCLES = 5000;   // watchdog

    `include "riscv_defs.vh"

    reg                tb_clk;
    reg                tb_a_en;
    reg  [NB_ADDR-1:0] tb_a_addr;
    wire [NB_DATA-1:0] tb_a_dout;
    reg                tb_b_en;
    reg                tb_b_we;
    reg  [IMEM_AW-1:0] tb_b_addr;
    reg  [NB_DATA-1:0] tb_b_din;

    integer errors;
    integer checks;
    integer k;

    imem u_dut (
        .i_clk    (tb_clk),
        .i_a_en   (tb_a_en),
        .i_a_addr (tb_a_addr),
        .o_a_dout (tb_a_dout),
        .i_b_en   (tb_b_en),
        .i_b_we   (tb_b_we),
        .i_b_addr (tb_b_addr),
        .i_b_din  (tb_b_din)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Palabra que se escribe en imem[k]: distinta para cada k y para
    // cada bit de la dirección, y distinta de HALT
    //------------------------------------------------------------------
    function [NB_DATA-1:0] patron;
        input integer idx;
        reg [IMEM_AW-1:0] a;
        begin
            a      = idx;
            patron = {~a, 6'h2A, a, 6'h15};
        end
    endfunction

    //------------------------------------------------------------------
    // Chequeo con etiqueta, para que el log diga qué caso falló
    //------------------------------------------------------------------
    task chk;
        input [8*40-1:0]    name;
        input [NB_DATA-1:0] obtenido;
        input [NB_DATA-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | dut=0x%08h esperado=0x%08h",
                         $time, name, obtenido, esperado);
            end
        end
    endtask

    // Lee por el puerto A: presenta la dirección durante un ciclo.
    // Al volver, tb_a_dout tiene la palabra de esa dirección.
    task leer;
        input [NB_ADDR-1:0] addr;
        begin
            tb_a_en   = 1'b1;
            tb_a_addr = addr;
            @(negedge tb_clk);
        end
    endtask

    // Un ciclo en el puerto B con en y we explícitos
    task puerto_b;
        input               en;
        input               we;
        input [IMEM_AW-1:0] addr;
        input [NB_DATA-1:0] din;
        begin
            tb_b_en   = en;
            tb_b_we   = we;
            tb_b_addr = addr;
            tb_b_din  = din;
            @(negedge tb_clk);
            tb_b_en   = 1'b0;
            tb_b_we   = 1'b0;
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors    = 0;
        checks    = 0;
        tb_a_en   = 1'b0;
        tb_a_addr = {NB_ADDR{1'b0}};
        tb_b_en   = 1'b0;
        tb_b_we   = 1'b0;
        tb_b_addr = {IMEM_AW{1'b0}};
        tb_b_din  = {NB_DATA{1'b0}};

        @(negedge tb_clk);

        // Contenido inicial: HALT en todas las palabras
        for (k = 0; k < IMEM_WORDS; k = k + 1) begin
            leer(4 * k);
            chk("contenido inicial HALT", tb_a_dout, INSTR_HALT);
        end

        // Carga por el puerto B con el puerto A deshabilitado (LOAD).
        // Mientras tanto la salida del A conserva el último HALT leído.
        tb_a_en   = 1'b0;
        tb_a_addr = 32'h0000_0000;
        for (k = 0; k < IMEM_WORDS; k = k + 1) begin
            puerto_b(1'b1, 1'b1, k, patron(k));
            chk("a_en = 0 durante la carga", tb_a_dout, INSTR_HALT);
        end

        // Relectura de las 1024 palabras por el puerto A
        for (k = 0; k < IMEM_WORDS; k = k + 1) begin
            leer(4 * k);
            chk("relectura tras la carga", tb_a_dout, patron(k));
        end

        // Latencia de un ciclo: antes del flanco la salida no cambia
        leer(32'h0000_0010);
        chk("latencia: dirección 0x010", tb_a_dout, patron(4));
        tb_a_addr = 32'h0000_0014;
        #1;
        chk("latencia: sin dato antes del flanco", tb_a_dout, patron(4));
        @(negedge tb_clk);
        chk("latencia: dato tras un flanco", tb_a_dout, patron(5));

        // i_a_en = 0 conserva la salida aunque cambie la dirección
        leer(32'h0000_001C);
        chk("a_en: lectura previa", tb_a_dout, patron(7));
        tb_a_en = 1'b0;
        for (k = 0; k < 3; k = k + 1) begin
            tb_a_addr = 32'h0000_0020 + 4 * k;
            @(negedge tb_clk);
            chk("a_en = 0 conserva la salida", tb_a_dout, patron(7));
        end
        leer(32'h0000_0020);
        chk("a_en = 1 vuelve a leer", tb_a_dout, patron(8));

        // Alias: los bits [31:12] y [1:0] del PC se ignoran
        leer(32'h0000_1000); chk("alias 0x0000_1000", tb_a_dout, patron(0));
        leer(32'h0000_1FFC); chk("alias 0x0000_1FFC", tb_a_dout, patron(1023));
        leer(32'hFFFF_F004); chk("alias 0xFFFF_F004", tb_a_dout, patron(1));
        leer(32'h8000_0ABC); chk("alias 0x8000_0ABC", tb_a_dout, patron(32'hABC >> 2));
        leer(32'h0000_0029); chk("alias pc[1:0] = 01", tb_a_dout, patron(10));
        leer(32'h0000_002A); chk("alias pc[1:0] = 10", tb_a_dout, patron(10));
        leer(32'h0000_002B); chk("alias pc[1:0] = 11", tb_a_dout, patron(10));

        // Puerto B sin en o sin we no escribe
        puerto_b(1'b1, 1'b0, 10'd3, 32'hFFFF_FFFF);
        leer(32'h0000_000C);
        chk("b_en = 1, b_we = 0 no escribe", tb_a_dout, patron(3));
        puerto_b(1'b0, 1'b1, 10'd3, 32'hFFFF_FFFF);
        leer(32'h0000_000C);
        chk("b_en = 0, b_we = 1 no escribe", tb_a_dout, patron(3));

        // Reescribir una palabra no toca las vecinas
        tb_a_en = 1'b0;
        puerto_b(1'b1, 1'b1, 10'd512, 32'h1234_5678);
        leer(32'h0000_07FC); chk("vecina anterior intacta", tb_a_dout, patron(511));
        leer(32'h0000_0800); chk("palabra reescrita", tb_a_dout, 32'h1234_5678);
        leer(32'h0000_0804); chk("vecina siguiente intacta", tb_a_dout, patron(513));

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
