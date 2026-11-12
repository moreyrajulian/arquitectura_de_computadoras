`timescale 1ns / 1ps

//======================================================================
// uart_fifo_tb
//
// Testbench autoverificante de uart_fifo (docs/spec/verificacion.md §3.3,
// decisión 035).
//
// Oráculo, escrito aparte del RTL: una cola del testbench (arreglo con
// índice de cabeza y cantidad de elementos). En cada ciclo saca un dato si
// se pide y hay alguno, y agrega el nuevo si se pide y hay lugar, contando
// el que se libera en el mismo ciclo. Después de cada flanco compara
// o_empty, o_full y, si hay datos, o_data con la cabeza de la cola.
//
// Casos:
//   - Dirigidos: orden FIFO; empty y full con 0, 1, 31 y 32 elementos;
//     push con la FIFO llena descartado; pop con la FIFO vacía sin efecto;
//     push y pop en el mismo ciclo con la FIFO vacía, a medio llenar y
//     llena; reset con datos adentro; vuelta completa de los punteros
//   - Aleatorio con semilla fija: 20000 ciclos en tramos que favorecen
//     llenar y vaciar, para pasar muchas veces por los bordes. Al final
//     comprueba que se llegó a llena, a vacía y a los casos de borde
//======================================================================

module uart_fifo_tb;

    localparam integer NB_DATA    = 8;
    localparam integer NB_ADDR    = 5;
    localparam integer DEPTH      = 1 << NB_ADDR;
    localparam integer T_CLK      = 10;         // ns
    localparam integer N_RANDOM   = 20000;
    localparam integer MAX_CYCLES = 30000;      // watchdog
    localparam integer SEED       = 44;

    reg                tb_clk;
    reg                tb_rst;
    reg                tb_push;
    reg  [NB_DATA-1:0] tb_data;
    reg                tb_pop;
    wire [NB_DATA-1:0] tb_o_data;
    wire               tb_o_empty;
    wire               tb_o_full;

    // Cola de referencia
    reg  [NB_DATA-1:0] ref_q [0:DEPTH-1];
    integer            ref_head;
    integer            ref_count;

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer prob_push;
    integer prob_pop;
    integer cov_full;           // ciclos con la FIFO llena
    integer cov_empty;          // ciclos con la FIFO vacía
    integer cov_drop;           // push descartado con la FIFO llena
    integer cov_full_both;      // push y pop con la FIFO llena
    integer cov_empty_both;     // push y pop con la FIFO vacía
    integer cov_empty_pop;      // pop con la FIFO vacía

    uart_fifo #(
        .NB_DATA (NB_DATA),
        .NB_ADDR (NB_ADDR)
    ) u_dut (
        .i_clk   (tb_clk),
        .i_rst   (tb_rst),
        .i_push  (tb_push),
        .i_data  (tb_data),
        .i_pop   (tb_pop),
        .o_data  (tb_o_data),
        .o_empty (tb_o_empty),
        .o_full  (tb_o_full)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    task chk;
        input [8*40-1:0]    name;
        input [NB_DATA-1:0] obtenido;
        input [NB_DATA-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("[%0t] ERROR %0s | dut=0x%0h esperado=0x%0h (en la cola: %0d)",
                             $time, name, obtenido, esperado, ref_count);
            end
        end
    endtask

    // Compara las salidas con la cola de referencia
    task comparar;
        input [8*40-1:0] name;
        begin
            chk(name, tb_o_empty, (ref_count == 0));
            chk(name, tb_o_full,  (ref_count == DEPTH));
            if (ref_count > 0)
                chk(name, tb_o_data, ref_q[ref_head]);
        end
    endtask

    // Un ciclo: presenta push/pop en el flanco de bajada, actualiza la
    // cola como debería hacerlo la FIFO en el flanco de subida y compara
    // en el flanco de bajada siguiente
    task ciclo;
        input [8*40-1:0]    name;
        input               push;
        input               pop;
        input [NB_DATA-1:0] dato;
        reg                 saca;
        reg                 mete;
        begin
            tb_push = push;
            tb_pop  = pop;
            tb_data = dato;
            saca = pop && (ref_count > 0);
            mete = push && ((ref_count < DEPTH) || saca);
            if (push && pop && ref_count == DEPTH) cov_full_both  = cov_full_both + 1;
            if (push && pop && ref_count == 0)     cov_empty_both = cov_empty_both + 1;
            if (push && !mete)                     cov_drop       = cov_drop + 1;
            if (pop && ref_count == 0)             cov_empty_pop  = cov_empty_pop + 1;
            @(posedge tb_clk);
            if (saca) begin
                ref_head  = (ref_head + 1) % DEPTH;
                ref_count = ref_count - 1;
            end
            if (mete) begin
                ref_q[(ref_head + ref_count) % DEPTH] = dato;
                ref_count = ref_count + 1;
            end
            @(negedge tb_clk);
            tb_push = 1'b0;
            tb_pop  = 1'b0;
            if (ref_count == DEPTH) cov_full  = cov_full + 1;
            if (ref_count == 0)     cov_empty = cov_empty + 1;
            comparar(name);
        end
    endtask

    task reset_fifo;
        begin
            tb_rst = 1'b1;
            @(negedge tb_clk);
            tb_rst    = 1'b0;
            ref_head  = 0;
            ref_count = 0;
            comparar("despues del reset");
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors = 0;      checks = 0;     seed = SEED;
        cov_full = 0;    cov_empty = 0;  cov_drop = 0;
        cov_full_both = 0; cov_empty_both = 0; cov_empty_pop = 0;
        tb_rst  = 1'b1;
        tb_push = 1'b0;
        tb_pop  = 1'b0;
        tb_data = {NB_DATA{1'b0}};
        ref_head  = 0;
        ref_count = 0;
        repeat (2) @(negedge tb_clk);
        reset_fifo;

        // Pop con la FIFO vacía: no pasa nada
        ciclo("pop con la FIFO vacia", 1'b0, 1'b1, 8'h00);

        // Un elemento, y orden FIFO al vaciar
        ciclo("push 1 elemento", 1'b1, 1'b0, 8'hA5);
        ciclo("push 2 elementos", 1'b1, 1'b0, 8'h5A);
        ciclo("pop: sale el mas viejo", 1'b0, 1'b1, 8'h00);
        ciclo("pop: queda vacia", 1'b0, 1'b1, 8'h00);

        // Push y pop en el mismo ciclo con la FIFO vacía: el dato queda
        ciclo("push y pop con la FIFO vacia", 1'b1, 1'b1, 8'h3C);
        ciclo("pop del dato que quedo", 1'b0, 1'b1, 8'h00);

        // Llenar: 31 y 32 elementos
        for (i = 0; i < DEPTH; i = i + 1)
            ciclo("llenando", 1'b1, 1'b0, 8'h10 + i[7:0]);
        // Push con la FIFO llena: se descarta
        ciclo("push con la FIFO llena", 1'b1, 1'b0, 8'hEE);
        // Push y pop con la FIFO llena: sale uno y entra el nuevo
        ciclo("push y pop con la FIFO llena", 1'b1, 1'b1, 8'hDD);
        // Push y pop a medio llenar
        ciclo("pop a 31", 1'b0, 1'b1, 8'h00);
        ciclo("push y pop a medio llenar", 1'b1, 1'b1, 8'hCC);
        // Vaciar todo, en orden (pasa por 1 y 0 elementos)
        for (i = 0; i < DEPTH; i = i + 1)
            ciclo("vaciando en orden", 1'b0, 1'b1, 8'h00);

        // Reset con datos adentro
        for (i = 0; i < 5; i = i + 1)
            ciclo("antes del reset", 1'b1, 1'b0, 8'h70 + i[7:0]);
        reset_fifo;
        ciclo("push despues del reset", 1'b1, 1'b0, 8'h99);
        ciclo("pop despues del reset", 1'b0, 1'b1, 8'h00);

        // Aleatorio: tramos de 200 ciclos que favorecen llenar o vaciar
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            if (i % 200 == 0) begin
                case ((i / 200) % 3)
                    0: begin prob_push = 80; prob_pop = 30; end   // llena
                    1: begin prob_push = 30; prob_pop = 80; end   // vacía
                    default: begin prob_push = 50; prob_pop = 50; end
                endcase
            end
            ciclo("aleatorio",
                  (($random(seed) % 100 + 100) % 100) < prob_push,
                  (($random(seed) % 100 + 100) % 100) < prob_pop,
                  $random(seed));
        end

        // Que el aleatorio haya pasado por los bordes
        chk("cobertura: llena",              (cov_full > 50),       1'b1);
        chk("cobertura: vacia",              (cov_empty > 50),      1'b1);
        chk("cobertura: push descartado",    (cov_drop > 10),       1'b1);
        chk("cobertura: push y pop llena",   (cov_full_both > 10),  1'b1);
        chk("cobertura: push y pop vacia",   (cov_empty_both > 10), 1'b1);
        chk("cobertura: pop con vacia",      (cov_empty_pop > 10),  1'b1);

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
