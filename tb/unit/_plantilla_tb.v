`timescale 1ns / 1ps

//======================================================================
// _plantilla_tb
//
// Plantilla de testbench autoverificante (docs/decisiones/009_convenciones-rtl.md).
// Copiar a tb/unit/<modulo>_tb.v y renombrar el módulo igual que el archivo.
//
// Reglas:
//   - Compara contra un valor esperado; nunca depende de mirar formas de onda
//   - Cada fallo imprime "ERROR" con el caso, lo obtenido y lo esperado
//   - Al final imprime "TEST PASSED" o "TEST FAILED" y llama a $finish
//   - Un watchdog corta la simulación si se cuelga (cuenta como FAILED)
//======================================================================

module _plantilla_tb;

    localparam integer NB_DATA   = 8;
    localparam integer T_CLK     = 10;      // ns, 100 MHz como la Basys 3
    localparam integer MAX_CYCLES = 1000;   // watchdog

    reg                tb_clk;
    reg                tb_rst;
    reg                tb_valid;
    reg  [NB_DATA-1:0] tb_data;
    wire               tb_o_valid;
    wire [NB_DATA-1:0] tb_o_data;

    integer errors;
    integer checks;

    _plantilla #(
        .NB_DATA (NB_DATA)
    ) u_dut (
        .i_clk   (tb_clk),
        .i_rst   (tb_rst),
        .i_valid (tb_valid),
        .i_data  (tb_data),
        .o_valid (tb_o_valid),
        .o_data  (tb_o_data)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Chequeo con etiqueta, para que el log diga qué caso falló
    //------------------------------------------------------------------
    task chk;
        input [8*32-1:0]    name;
        input [NB_DATA-1:0] obtenido;
        input [NB_DATA-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | dut=0x%0h esperado=0x%0h",
                         $time, name, obtenido, esperado);
            end
        end
    endtask

    // Presenta un dato y espera a que el DUT lo registre
    task enviar;
        input [NB_DATA-1:0] dato;
        begin
            @(negedge tb_clk);
            tb_valid = 1'b1;
            tb_data  = dato;
            @(negedge tb_clk);
            tb_valid = 1'b0;
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors   = 0;
        checks   = 0;
        tb_rst   = 1'b1;
        tb_valid = 1'b0;
        tb_data  = {NB_DATA{1'b0}};

        repeat (2) @(negedge tb_clk);
        tb_rst = 1'b0;
        chk("reset", tb_o_data, {NB_DATA{1'b0}});

        enviar(8'hA5);
        chk("carga A5", tb_o_data, 8'hA5);

        @(negedge tb_clk);
        chk("mantiene sin valid", tb_o_data, 8'hA5);

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
