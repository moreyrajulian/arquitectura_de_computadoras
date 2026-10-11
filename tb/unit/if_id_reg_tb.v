`timescale 1ns / 1ps

//======================================================================
// if_id_reg_tb
//
// Testbench autoverificante de if_id_reg (docs/spec/verificacion.md §3.1).
//
// Casos:
//   - Reset carga burbuja (valid = 0), también con en = 0 (rst > en)
//   - en = 1 sin flush carga valid = 1 y el PC
//   - flush carga burbuja (valid = 0) y al soltarlo vuelve a cargar
//   - en = 0 conserva valid y pc, también con flush = 1 (en > flush):
//     el HALT retenido por un stall no se pierde (pipeline.md §3.4)
//   - Barrido exhaustivo de {rst, en, flush} desde un estado válido
//   - o_instr es i_instr sin registrar (decisión 009)
//   - o_latch = {valid, pc, instr} en el orden de pipeline.md §8
//   - Estímulo aleatorio con semilla fija contra un modelo de §2
//
// Como en la traza del modelo (tools/isasim/isasim/latches.py), en una
// burbuja solo se compara valid: los datos no importan (pipeline.md §2),
// y if_id_pc no tiene reset.
//
// Los estímulos cambian en el flanco de bajada y se comprueban en el
// flanco de bajada siguiente, después de un flanco de subida.
//======================================================================

module if_id_reg_tb;

    localparam integer NB_PC      = 32;
    localparam integer NB_INSTR   = 32;
    localparam integer NB_LATCH   = 1 + NB_PC + NB_INSTR;   // 65 (§8)
    localparam integer T_CLK      = 10;     // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM   = 2000;   // ciclos de estímulo aleatorio
    localparam integer MAX_CYCLES = 5000;   // watchdog
    localparam integer SEED       = 33;     // semilla fija (issue #33)

    localparam [NB_INSTR-1:0] INSTR_HALT = 32'h0010_0073;   // decisión 001

    reg                 tb_clk;
    reg                 tb_rst;
    reg                 tb_en;
    reg                 tb_flush;
    reg  [NB_PC-1:0]    tb_pc;
    reg  [NB_INSTR-1:0] tb_instr;
    wire                tb_o_valid;
    wire [NB_PC-1:0]    tb_o_pc;
    wire [NB_INSTR-1:0] tb_o_instr;
    wire [NB_LATCH-1:0] tb_o_latch;

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer combo;

    reg             modelo_valid;
    reg [NB_PC-1:0] modelo_pc;
    reg             exp_valid;
    reg [NB_PC-1:0] exp_pc;

    if_id_reg #(
        .NB_PC    (NB_PC),
        .NB_INSTR (NB_INSTR)
    ) u_dut (
        .i_clk   (tb_clk),
        .i_rst   (tb_rst),
        .i_en    (tb_en),
        .i_flush (tb_flush),
        .i_pc    (tb_pc),
        .i_instr (tb_instr),
        .o_valid (tb_o_valid),
        .o_pc    (tb_o_pc),
        .o_instr (tb_o_instr),
        .o_latch (tb_o_latch)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Modelo de referencia, escrito a partir de pipeline.md §2 y §3.3:
    // prioridad rst > en > flush; rst y flush cargan burbuja
    //------------------------------------------------------------------
    task modelo;
        input rst;
        input en;
        input flush;
        input [NB_PC-1:0] pc_in;
        begin
            if (rst)
                modelo_valid = 1'b0;
            else if (en) begin
                modelo_valid = ~flush;
                modelo_pc    = pc_in;
            end
        end
    endtask

    //------------------------------------------------------------------
    // Chequeo con etiqueta, para que el log diga qué caso falló
    //------------------------------------------------------------------
    task chk;
        input [8*40-1:0]     name;
        input [NB_LATCH-1:0] obtenido;
        input [NB_LATCH-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | dut=0x%0h esperado=0x%0h",
                         $time, name, obtenido, esperado);
            end
        end
    endtask

    // Compara las salidas con lo esperado; el pc y el bus completo solo
    // si es una instrucción real (en una burbuja los datos no importan)
    task chk_latch;
        input [8*40-1:0]  name;
        input             valid;
        input [NB_PC-1:0] pc;
        begin
            chk(name, tb_o_valid, valid);
            chk(name, tb_o_latch[NB_LATCH-1], valid);
            if (valid) begin
                chk(name, tb_o_pc, pc);
                chk(name, tb_o_latch, {valid, pc, tb_instr});
            end
        end
    endtask

    // Aplica un juego de entradas durante un ciclo (un flanco de subida)
    // y actualiza el modelo
    task ciclo;
        input             rst;
        input             en;
        input             flush;
        input [NB_PC-1:0] pc;
        begin
            tb_rst   = rst;
            tb_en    = en;
            tb_flush = flush;
            tb_pc    = pc;
            modelo(rst, en, flush, pc);
            @(negedge tb_clk);
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors       = 0;
        checks       = 0;
        seed         = SEED;
        tb_rst       = 1'b1;
        tb_en        = 1'b0;
        tb_flush     = 1'b0;
        tb_pc        = {NB_PC{1'b0}};
        tb_instr     = INSTR_HALT;
        modelo_valid = 1'b0;
        modelo_pc    = {NB_PC{1'b0}};

        // Reset: burbuja
        @(negedge tb_clk);
        ciclo(1'b1, 1'b1, 1'b0, 32'h0000_0000);
        chk_latch("reset", 1'b0, 32'h0);

        // Carga normal
        ciclo(1'b0, 1'b1, 1'b0, 32'h0000_0000);
        chk_latch("carga pc 0", 1'b1, 32'h0000_0000);
        ciclo(1'b0, 1'b1, 1'b0, 32'h0000_0004);
        chk_latch("carga pc 4", 1'b1, 32'h0000_0004);

        // flush carga burbuja; al soltarlo vuelve a cargar
        ciclo(1'b0, 1'b1, 1'b1, 32'h0000_0008);
        chk_latch("flush carga burbuja", 1'b0, 32'h0);
        ciclo(1'b0, 1'b1, 1'b1, 32'h0000_0100);
        chk_latch("flush seguido", 1'b0, 32'h0);
        ciclo(1'b0, 1'b1, 1'b0, 32'h0000_0104);
        chk_latch("carga tras flush", 1'b1, 32'h0000_0104);

        // en = 0 conserva
        for (i = 0; i < 3; i = i + 1) begin
            ciclo(1'b0, 1'b0, 1'b0, 32'h0000_0F00 + 4*i);
            chk_latch("en = 0 conserva", 1'b1, 32'h0000_0104);
        end

        // HALT retenido por un stall: en = 0 gana sobre flush = 1
        // (pipeline.md §3.4 y §10.4, stall con HALT en ID)
        ciclo(1'b0, 1'b1, 1'b0, 32'h0000_0040);
        chk_latch("HALT entra a IF/ID", 1'b1, 32'h0000_0040);
        for (i = 0; i < 3; i = i + 1) begin
            ciclo(1'b0, 1'b0, 1'b1, 32'h0000_0044);
            chk_latch("en = 0 conserva con flush", 1'b1, 32'h0000_0040);
        end
        // Termina el stall: entra burbuja detrás del HALT
        ciclo(1'b0, 1'b1, 1'b1, 32'h0000_0044);
        chk_latch("flush al terminar el stall", 1'b0, 32'h0);
        // Una burbuja retenida sigue siendo burbuja
        ciclo(1'b0, 1'b0, 1'b0, 32'h0000_0048);
        chk_latch("en = 0 conserva burbuja", 1'b0, 32'h0);

        // rst gana sobre en = 0 y sobre flush
        ciclo(1'b0, 1'b1, 1'b0, 32'h0000_0200);
        ciclo(1'b1, 1'b0, 1'b0, 32'h0000_0204);
        chk_latch("rst con en = 0", 1'b0, 32'h0);
        ciclo(1'b0, 1'b1, 1'b0, 32'h0000_0200);
        ciclo(1'b1, 1'b0, 1'b1, 32'h0000_0204);
        chk_latch("rst con en = 0 y flush", 1'b0, 32'h0);

        // o_instr es i_instr sin registrar, y o_latch lo incluye
        ciclo(1'b0, 1'b1, 1'b0, 32'h0000_0300);
        tb_instr = 32'h00A0_0093;   // addi x1, x0, 10
        #1;
        chk("o_instr = i_instr", tb_o_instr, 32'h00A0_0093);
        chk("o_latch {valid, pc, instr}", tb_o_latch,
            {1'b1, 32'h0000_0300, 32'h00A0_0093});
        tb_instr = 32'hFFFF_FFFF;
        #1;
        chk("o_instr = i_instr", tb_o_instr, 32'hFFFF_FFFF);
        chk("o_latch {valid, pc, instr}", tb_o_latch,
            {1'b1, 32'h0000_0300, 32'hFFFF_FFFF});
        // Orden de los campos con valores que no se confunden
        ciclo(1'b0, 1'b1, 1'b0, 32'h8000_0001);
        tb_instr = 32'h0000_0001;
        #1;
        chk("o_latch orden", tb_o_latch, 65'h1_8000_0001_0000_0001);

        // Barrido exhaustivo de {rst, en, flush} desde un estado válido
        // con un pc conocido, distinto del que se presenta
        for (combo = 0; combo < 8; combo = combo + 1) begin
            ciclo(1'b0, 1'b1, 1'b0, 32'h0000_0040);
            ciclo(combo[2], combo[1], combo[0], 32'h0000_0800);
            chk_latch("barrido {rst,en,flush}", modelo_valid, modelo_pc);
            if (tb_o_valid !== modelo_valid)
                $display("        combo {rst,en,flush} = %b", combo[2:0]);
        end

        // Estímulo aleatorio con semilla fija contra el modelo
        ciclo(1'b1, 1'b1, 1'b0, 32'h0);
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            tb_instr = $random(seed);
            ciclo((($random(seed) & 31) == 0),     // rst   1/32
                  (($random(seed) & 3)  != 0),     // en    3/4
                  (($random(seed) & 7)  == 0),     // flush 1/8
                  $random(seed));
            exp_valid = modelo_valid;
            exp_pc    = modelo_pc;
            chk_latch("aleatorio", exp_valid, exp_pc);
            chk("aleatorio o_instr", tb_o_instr, tb_instr);
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
