`timescale 1ns / 1ps

//======================================================================
// regfile_tb
//
// Testbench autoverificante de regfile (docs/spec/verificacion.md §3.1).
//
// Casos:
//   - El reset pone los 32 registros en 0, gana sobre la escritura y
//     actúa también con en = 0 (decisión 018)
//   - Escribir y leer los 31 registros por rs1, rs2 y el puerto de debug
//   - Dos lecturas simultáneas, de registros distintos y del mismo
//   - x0 siempre 0 en los tres puertos aunque se escriba; el bypass no
//     actúa sobre x0
//   - Bypass WB -> ID en rs1, en rs2 y en los dos (decisión 007); no
//     actúa con we = 0 ni con otro rd
//   - en = 0 no escribe; el bypass sigue la fórmula de pipeline.md §4.2
//     (usa wb_reg_write, sin enable)
//   - El puerto de debug lee el valor guardado, sin bypass, y no
//     interfiere con las lecturas de ID
//   - Carga por jerarquía como el banco incremental (decisión 021):
//     después de soltar el reset, se conserva tras un flanco con we = 0
//   - Estímulo aleatorio con semilla fija contra un modelo de §4.2
//
// Los estímulos cambian en el flanco de bajada; las lecturas
// (combinacionales) se comprueban 1 ns después, antes del flanco de
// subida que escribe.
//======================================================================

module regfile_tb;

    localparam integer NB_DATA    = 32;
    localparam integer NB_ADDR    = 5;
    localparam integer N_REGS     = 1 << NB_ADDR;
    localparam integer T_CLK      = 10;     // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM   = 5000;   // ciclos de estímulo aleatorio
    localparam integer MAX_CYCLES = 20000;  // watchdog
    localparam integer SEED       = 35;     // semilla fija (issue #35)

    localparam [NB_DATA-1:0] ZERO = {NB_DATA{1'b0}};
    localparam [NB_DATA-1:0] ONES = {NB_DATA{1'b1}};

    reg                tb_clk;
    reg                tb_rst;
    reg                tb_en;
    reg  [NB_ADDR-1:0] tb_rs1;
    reg  [NB_ADDR-1:0] tb_rs2;
    reg                tb_we;
    reg  [NB_ADDR-1:0] tb_rd;
    reg  [NB_DATA-1:0] tb_wdata;
    reg  [NB_ADDR-1:0] tb_dbg;
    wire [NB_DATA-1:0] tb_o_rs1_data;
    wire [NB_DATA-1:0] tb_o_rs2_data;
    wire [NB_DATA-1:0] tb_o_dbg_reg_data;

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer r;
    integer errores_antes;

    reg [NB_DATA-1:0] modelo [0:N_REGS-1];

    regfile #(
        .NB_DATA (NB_DATA),
        .NB_ADDR (NB_ADDR)
    ) u_dut (
        .i_clk          (tb_clk),
        .i_rst          (tb_rst),
        .i_en           (tb_en),
        .i_rs1_addr     (tb_rs1),
        .i_rs2_addr     (tb_rs2),
        .o_rs1_data     (tb_o_rs1_data),
        .o_rs2_data     (tb_o_rs2_data),
        .i_we           (tb_we),
        .i_rd_addr      (tb_rd),
        .i_rd_data      (tb_wdata),
        .i_dbg_reg_addr (tb_dbg),
        .o_dbg_reg_data (tb_o_dbg_reg_data)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Modelo de referencia, escrito a partir de pipeline.md §4.2 y de la
    // decisión 018
    //------------------------------------------------------------------

    // Lectura de ID: x0 = 0; bypass si WB escribe ese registro
    function [NB_DATA-1:0] esperado_id;
        input [NB_ADDR-1:0] addr;
        begin
            if (addr == 0)
                esperado_id = ZERO;
            else if (tb_we && tb_rd == addr)
                esperado_id = tb_wdata;
            else
                esperado_id = modelo[addr];
        end
    endfunction

    // Lectura de debug: x0 = 0; valor guardado, sin bypass
    function [NB_DATA-1:0] esperado_dbg;
        input [NB_ADDR-1:0] addr;
        begin
            if (addr == 0)
                esperado_dbg = ZERO;
            else
                esperado_dbg = modelo[addr];
        end
    endfunction

    // Efecto del flanco de subida: rst > en; rd = 0 no escribe
    task modelo_flanco;
        integer k;
        begin
            if (tb_rst)
                for (k = 0; k < N_REGS; k = k + 1)
                    modelo[k] = ZERO;
            else if (tb_en && tb_we && tb_rd != 0)
                modelo[tb_rd] = tb_wdata;
        end
    endtask

    // Valor distinto por registro y por pasada, nunca 0
    function [NB_DATA-1:0] patron;
        input integer reg_n;
        input integer pasada;
        begin
            patron = {pasada[7:0] ^ 8'hC3, 3'b101, reg_n[4:0],
                      3'b010, ~reg_n[4:0], 8'h5A};
        end
    endfunction

    //------------------------------------------------------------------
    // Chequeo con etiqueta, para que el log diga qué caso falló
    //------------------------------------------------------------------
    task chk;
        input [8*48-1:0]    name;
        input [NB_DATA-1:0] obtenido;
        input [NB_DATA-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | dut=0x%h esperado=0x%h",
                         $time, name, obtenido, esperado);
            end
        end
    endtask

    // Compara los tres puertos de lectura contra el modelo; si algo
    // falla, informa también las entradas de ese ciclo
    task chk_puertos;
        input [8*40-1:0] name;
        begin
            errores_antes = errors;
            chk({name, " rs1"}, tb_o_rs1_data,     esperado_id(tb_rs1));
            chk({name, " rs2"}, tb_o_rs2_data,     esperado_id(tb_rs2));
            chk({name, " dbg"}, tb_o_dbg_reg_data, esperado_dbg(tb_dbg));
            if (errors != errores_antes)
                $display("        rst=%b en=%b we=%b rd=x%0d data=0x%h rs1=x%0d rs2=x%0d dbg=x%0d",
                         tb_rst, tb_en, tb_we, tb_rd, tb_wdata, tb_rs1, tb_rs2, tb_dbg);
        end
    endtask

    // Presenta las entradas de un ciclo y comprueba las lecturas antes
    // del flanco de subida
    task poner;
        input [8*40-1:0]    name;
        input               rst;
        input               en;
        input               we;
        input [NB_ADDR-1:0] rd;
        input [NB_DATA-1:0] wdata;
        input [NB_ADDR-1:0] rs1;
        input [NB_ADDR-1:0] rs2;
        input [NB_ADDR-1:0] dbg;
        begin
            tb_rst   = rst;
            tb_en    = en;
            tb_we    = we;
            tb_rd    = rd;
            tb_wdata = wdata;
            tb_rs1   = rs1;
            tb_rs2   = rs2;
            tb_dbg   = dbg;
            #1;
            chk_puertos(name);
        end
    endtask

    // Deja pasar el flanco de subida y vuelve al de bajada
    task flanco;
        begin
            modelo_flanco;
            @(negedge tb_clk);
        end
    endtask

    task ciclo;
        input [8*40-1:0]    name;
        input               rst;
        input               en;
        input               we;
        input [NB_ADDR-1:0] rd;
        input [NB_DATA-1:0] wdata;
        input [NB_ADDR-1:0] rs1;
        input [NB_ADDR-1:0] rs2;
        input [NB_ADDR-1:0] dbg;
        begin
            poner(name, rst, en, we, rd, wdata, rs1, rs2, dbg);
            flanco;
        end
    endtask

    // Lee los 32 registros por los tres puertos (we = 0): rs1 = n,
    // rs2 = n + 1 (dos lecturas distintas a la vez), debug = n
    task leer_todos;
        input [8*40-1:0] name;
        integer n;
        begin
            for (n = 0; n < N_REGS; n = n + 1)
                ciclo(name, 1'b0, 1'b1, 1'b0, 5'd0, ONES,
                      n[NB_ADDR-1:0], n[NB_ADDR-1:0] + 1'b1, n[NB_ADDR-1:0]);
        end
    endtask

    // Comprueba que los 32 registros guardados son 0 (por jerarquía, sin
    // consumir tiempo; la lectura por los puertos la hace leer_todos)
    task chk_todos_cero;
        input [8*40-1:0] name;
        integer n;
        begin
            for (n = 0; n < N_REGS; n = n + 1)
                chk(name, u_dut.regs[n], ZERO);
        end
    endtask

    // Escribe x1..x31 con patron(n, pasada); cada escritura comprueba
    // además el bypass en rs1 y el valor viejo en el puerto de debug
    task escribir_todos;
        input integer pasada;
        integer n;
        begin
            for (n = 1; n < N_REGS; n = n + 1)
                ciclo("escritura", 1'b0, 1'b1, 1'b1, n[NB_ADDR-1:0], patron(n, pasada),
                      n[NB_ADDR-1:0], 5'd0, n[NB_ADDR-1:0]);
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors   = 0;
        checks   = 0;
        seed     = SEED;
        tb_rst   = 1'b1;
        tb_en    = 1'b1;
        tb_we    = 1'b0;
        tb_rd    = 5'd0;
        tb_wdata = ZERO;
        tb_rs1   = 5'd0;
        tb_rs2   = 5'd0;
        tb_dbg   = 5'd0;
        for (i = 0; i < N_REGS; i = i + 1)
            modelo[i] = ZERO;

        // Reset inicial: antes los registros no tienen valor, no se leen
        repeat (2) @(negedge tb_clk);
        chk_todos_cero("reset inicial");
        leer_todos("reset inicial");

        // Escribir y leer los 31 registros
        escribir_todos(1);
        leer_todos("lectura tras escritura");
        for (i = 1; i < N_REGS; i = i + 1)
            chk("x1..x31 guardados", u_dut.regs[i], patron(i, 1));

        // Dos lecturas del mismo registro a la vez
        for (i = 0; i < N_REGS; i = i + 1)
            ciclo("rs1 = rs2", 1'b0, 1'b1, 1'b0, 5'd0, ONES,
                  i[NB_ADDR-1:0], i[NB_ADDR-1:0], (N_REGS - 1 - i));

        // x0: escribirlo no tiene efecto y el bypass no actúa
        poner("x0 escritura", 1'b0, 1'b1, 1'b1, 5'd0, ONES, 5'd0, 5'd0, 5'd0);
        chk("x0 bypass rs1", tb_o_rs1_data, ZERO);
        chk("x0 bypass rs2", tb_o_rs2_data, ZERO);
        chk("x0 dbg", tb_o_dbg_reg_data, ZERO);
        flanco;
        ciclo("x0 tras escritura", 1'b0, 1'b1, 1'b0, 5'd0, ONES, 5'd0, 5'd0, 5'd0);
        chk("x0 tras escritura rs1", tb_o_rs1_data, ZERO);
        chk("x0 guardado", u_dut.regs[0], ZERO);

        // Bypass en rs1, en rs2 y en los dos a la vez
        poner("bypass rs1", 1'b0, 1'b1, 1'b1, 5'd5, 32'h1111_0005, 5'd5, 5'd6, 5'd5);
        chk("bypass rs1 dato nuevo", tb_o_rs1_data, 32'h1111_0005);
        chk("bypass rs1 rs2 sin bypass", tb_o_rs2_data, patron(6, 1));
        chk("bypass rs1 dbg sin bypass", tb_o_dbg_reg_data, patron(5, 1));
        flanco;
        poner("bypass rs2", 1'b0, 1'b1, 1'b1, 5'd6, 32'h2222_0006, 5'd5, 5'd6, 5'd6);
        chk("bypass rs2 rs1 escrito antes", tb_o_rs1_data, 32'h1111_0005);
        chk("bypass rs2 dato nuevo", tb_o_rs2_data, 32'h2222_0006);
        chk("bypass rs2 dbg sin bypass", tb_o_dbg_reg_data, patron(6, 1));
        flanco;
        poner("bypass rs1 y rs2", 1'b0, 1'b1, 1'b1, 5'd7, 32'h3333_0007, 5'd7, 5'd7, 5'd7);
        chk("bypass ambos rs1", tb_o_rs1_data, 32'h3333_0007);
        chk("bypass ambos rs2", tb_o_rs2_data, 32'h3333_0007);
        chk("bypass ambos dbg sin bypass", tb_o_dbg_reg_data, patron(7, 1));
        flanco;
        ciclo("dbg tras escritura", 1'b0, 1'b1, 1'b0, 5'd0, ONES, 5'd5, 5'd6, 5'd7);
        chk("dbg ve la escritura al ciclo siguiente", tb_o_dbg_reg_data, 32'h3333_0007);

        // Sin bypass: we = 0 con rd = rs1, y we = 1 con otro rd
        poner("we = 0 sin bypass", 1'b0, 1'b1, 1'b0, 5'd8, ONES, 5'd8, 5'd8, 5'd8);
        chk("we = 0 sin bypass rs1", tb_o_rs1_data, patron(8, 1));
        flanco;
        chk("we = 0 no escribe", u_dut.regs[8], patron(8, 1));
        poner("otro rd sin bypass", 1'b0, 1'b1, 1'b1, 5'd9, 32'h4444_0009, 5'd10, 5'd11, 5'd9);
        chk("otro rd sin bypass rs1", tb_o_rs1_data, patron(10, 1));
        chk("otro rd sin bypass rs2", tb_o_rs2_data, patron(11, 1));
        flanco;

        // en = 0: no escribe; el bypass de ID sigue la fórmula de §4.2
        for (i = 0; i < 3; i = i + 1) begin
            poner("en = 0", 1'b0, 1'b0, 1'b1, 5'd12, 32'h5555_000C, 5'd12, 5'd3, 5'd12);
            chk("en = 0 bypass rs1", tb_o_rs1_data, 32'h5555_000C);
            chk("en = 0 dbg valor guardado", tb_o_dbg_reg_data, patron(12, 1));
            flanco;
            chk("en = 0 no escribe", u_dut.regs[12], patron(12, 1));
        end
        // Al volver en = 1 (un STEP) la escritura se hace una sola vez
        ciclo("en = 1 escribe", 1'b0, 1'b1, 1'b1, 5'd12, 32'h5555_000C, 5'd12, 5'd3, 5'd12);
        chk("en = 1 escribe", u_dut.regs[12], 32'h5555_000C);

        // El puerto de debug no interfiere con las lecturas de ID
        for (i = 0; i < N_REGS; i = i + 1)
            ciclo("dbg no interfiere", 1'b0, 1'b1, 1'b1, 5'd13, 32'h6666_0000 + i,
                  5'd13, 5'd14, i[NB_ADDR-1:0]);

        // Reset: gana sobre una escritura con en = 1
        ciclo("reset con escritura", 1'b1, 1'b1, 1'b1, 5'd3, ONES, 5'd3, 5'd4, 5'd3);
        chk_todos_cero("reset con escritura");
        // Reset con en = 0 (core detenido, como LOAD y RESET)
        escribir_todos(2);
        ciclo("reset con en = 0", 1'b1, 1'b0, 1'b1, 5'd3, ONES, 5'd3, 5'd4, 5'd3);
        chk_todos_cero("reset con en = 0");
        leer_todos("tras reset con en = 0");

        // Carga por jerarquía como pipeline_tb (decisión 021): se suelta
        // el reset y se carga antes del primer flanco habilitado
        ciclo("reset antes de la carga", 1'b1, 1'b0, 1'b0, 5'd0, ZERO, 5'd0, 5'd0, 5'd0);
        tb_rst = 1'b0;
        for (i = 1; i < N_REGS; i = i + 1) begin
            u_dut.regs[i] = patron(i, 3);
            modelo[i]     = patron(i, 3);
        end
        ciclo("primer flanco tras la carga", 1'b0, 1'b1, 1'b0, 5'd0, ZERO, 5'd1, 5'd2, 5'd1);
        leer_todos("carga por jerarquía");

        // Aleatorio contra el modelo. rd coincide con rs1 o rs2 a menudo
        // para ejercitar el bypass; reset poco frecuente
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            r = $random(seed);
            poner("aleatorio",
                  (r[5:0] == 6'd0),             // rst: 1 de cada 64
                  (r[7:6] != 2'b00),            // en: 3 de cada 4
                  r[8],                         // we: 1 de cada 2
                  r[13:9],                      // rd
                  $random(seed),                // dato
                  (r[15:14] == 2'b00) ? r[13:9] : r[20:16],   // rs1
                  (r[22:21] == 2'b00) ? r[13:9] : r[27:23],   // rs2
                  $random(seed));               // dbg
            flanco;
        end
        // Estado final guardado contra el modelo
        for (i = 1; i < N_REGS; i = i + 1)
            chk("estado final", u_dut.regs[i], modelo[i]);

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
