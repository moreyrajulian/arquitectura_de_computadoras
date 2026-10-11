`timescale 1ns / 1ps

//======================================================================
// if_stage_tb
//
// Testbench autoverificante de if_stage (docs/spec/verificacion.md §3.1):
// pc_logic + imem + if_id_reg conectados como pipeline.md §3.
// Simula el IP imem_bram, así que corre en xsim dentro del proyecto de
// Vivado; necesita ~32 µs (run all), más que los 1000 ns por defecto.
//
// Casos:
//   - Carga del programa por el puerto B con el core en reset (LOAD,
//     memoria.md §4); cada palabra es distinta, así una dirección
//     equivocada se ve en if_id_instr
//   - Reset: PC = 0 e IF/ID en burbuja
//   - Arranque (memoria.md §4.4): primer ciclo habilitado -> IF/ID tiene
//     pc = 0 e instr(0); después la secuencia pc, pc + 4, ...
//   - en_pc = en_if_id = 0 (core detenido o stall): PC, valid, pc e
//     instr de IF/ID no cambian, también con flush = 1 (en > flush)
//   - flush con en = 1: IF/ID queda en burbuja (valid = 0); el PC sigue
//   - redirect + flush (salto tomado, §10.5): el PC toma redirect_pc y
//     la instrucción del camino equivocado queda en burbuja; después se
//     busca desde el destino
//   - stop_fetch + flush (HALT en vuelo, §3.4): el PC se retiene y todo
//     lo que entra a IF/ID es burbuja
//   - o_if_id_latch = {valid, pc, instr} (pipeline.md §8)
//   - Estímulo aleatorio con semilla fija contra un modelo de §3
//
// Como en la traza del modelo (tools/isasim/isasim/latches.py), en una
// burbuja solo se compara valid: los datos no importan (pipeline.md §2).
// En las retenciones (en = 0) se compara todo, bit a bit.
//
// Los estímulos cambian en el flanco de bajada y se comprueban en el
// flanco de bajada siguiente, después de un flanco de subida.
//======================================================================

module if_stage_tb;

    localparam integer NB_PC      = 32;
    localparam integer NB_INSTR   = 32;
    localparam integer NB_LATCH   = 1 + NB_PC + NB_INSTR;   // 65 (§8)
    localparam integer IMEM_AW    = 10;
    localparam integer IMEM_WORDS = 1 << IMEM_AW;
    localparam integer T_CLK      = 10;     // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM   = 2000;   // ciclos de estímulo aleatorio
    localparam integer MAX_CYCLES = 6000;   // watchdog
    localparam integer SEED       = 34;     // semilla fija (issue #34)

    reg                 tb_clk;
    reg                 tb_rst;
    reg                 tb_en_pc;
    reg                 tb_en_if_id;
    reg                 tb_flush;
    reg                 tb_redirect;
    reg  [NB_PC-1:0]    tb_redirect_pc;
    reg                 tb_stop_fetch;
    reg                 tb_imem_b_en;
    reg                 tb_imem_b_we;
    reg  [IMEM_AW-1:0]  tb_imem_b_addr;
    reg  [NB_INSTR-1:0] tb_imem_b_din;
    wire [NB_PC-1:0]    tb_o_pc;
    wire                tb_o_if_id_valid;
    wire [NB_PC-1:0]    tb_o_if_id_pc;
    wire [NB_INSTR-1:0] tb_o_if_id_instr;
    wire [NB_LATCH-1:0] tb_o_if_id_latch;

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer k;

    // Contenido de imem que escribe el banco y estado del modelo
    reg [NB_INSTR-1:0] mem [0:IMEM_WORDS-1];
    reg [NB_PC-1:0]    m_pc;
    reg                m_valid;
    reg [NB_PC-1:0]    m_if_id_pc;
    reg [NB_INSTR-1:0] m_instr;

    // Foto del estado para las retenciones
    reg [NB_PC-1:0]    foto_pc;
    reg [NB_LATCH-1:0] foto_latch;

    if_stage #(
        .NB_PC    (NB_PC),
        .NB_INSTR (NB_INSTR)
    ) u_dut (
        .i_clk         (tb_clk),
        .i_rst         (tb_rst),
        .i_en_pc       (tb_en_pc),
        .i_en_if_id    (tb_en_if_id),
        .i_flush       (tb_flush),
        .i_redirect    (tb_redirect),
        .i_redirect_pc (tb_redirect_pc),
        .i_stop_fetch  (tb_stop_fetch),
        .i_imem_b_en   (tb_imem_b_en),
        .i_imem_b_we   (tb_imem_b_we),
        .i_imem_b_addr (tb_imem_b_addr),
        .i_imem_b_din  (tb_imem_b_din),
        .o_pc          (tb_o_pc),
        .o_if_id_valid (tb_o_if_id_valid),
        .o_if_id_pc    (tb_o_if_id_pc),
        .o_if_id_instr (tb_o_if_id_instr),
        .o_if_id_latch (tb_o_if_id_latch)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Modelo de referencia, escrito a partir de pipeline.md §2 y §3:
    //   PC:    rst -> 0; si en_pc: redirect > stop_fetch > +4
    //   IF/ID: rst -> burbuja; si en_if_id: valid = ~flush, pc = pc_reg
    //   imem:  si en_if_id, la salida toma mem[pc_reg[11:2]] (alias,
    //          memoria.md §6.1), también durante el reset
    //------------------------------------------------------------------
    task modelo;
        reg [NB_PC-1:0] pc_ant;
        begin
            pc_ant = m_pc;
            if (tb_en_if_id)
                m_instr = mem[pc_ant[IMEM_AW+1:2]];
            if (tb_rst) begin
                m_pc    = {NB_PC{1'b0}};
                m_valid = 1'b0;
            end
            else begin
                if (tb_en_pc) begin
                    if (tb_redirect)
                        m_pc = tb_redirect_pc;
                    else if (!tb_stop_fetch)
                        m_pc = pc_ant + 4;
                end
                if (tb_en_if_id) begin
                    m_valid    = ~tb_flush;
                    m_if_id_pc = pc_ant;
                end
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

    // Compara PC e IF/ID con el modelo; pc e instr solo si es instrucción
    task chk_modelo;
        input [8*40-1:0] name;
        begin
            chk(name, tb_o_pc, m_pc);
            chk(name, tb_o_if_id_valid, m_valid);
            chk(name, tb_o_if_id_latch[NB_LATCH-1], m_valid);
            if (m_valid) begin
                chk(name, tb_o_if_id_pc, m_if_id_pc);
                chk(name, tb_o_if_id_instr, m_instr);
                chk(name, tb_o_if_id_latch, {1'b1, m_if_id_pc, m_instr});
            end
        end
    endtask

    // Retención: todo igual a la foto, bit a bit
    task chk_foto;
        input [8*40-1:0] name;
        begin
            chk(name, tb_o_pc, foto_pc);
            chk(name, tb_o_if_id_latch, foto_latch);
        end
    endtask

    task tomar_foto;
        begin
            foto_pc    = tb_o_pc;
            foto_latch = tb_o_if_id_latch;
        end
    endtask

    // Un ciclo (un flanco de subida) con estas entradas; actualiza el modelo
    task ciclo;
        input             rst;
        input             en_pc;
        input             en_if_id;
        input             flush;
        input             redirect;
        input [NB_PC-1:0] redirect_pc;
        input             stop_fetch;
        begin
            tb_rst         = rst;
            tb_en_pc       = en_pc;
            tb_en_if_id    = en_if_id;
            tb_flush       = flush;
            tb_redirect    = redirect;
            tb_redirect_pc = redirect_pc;
            tb_stop_fetch  = stop_fetch;
            modelo;
            @(negedge tb_clk);
        end
    endtask

    // Ciclo normal: enables en 1, sin flush ni salto
    task normal;
        begin
            ciclo(1'b0, 1'b1, 1'b1, 1'b0, 1'b0, {NB_PC{1'b0}}, 1'b0);
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
        tb_en_if_id    = 1'b0;
        tb_flush       = 1'b0;
        tb_redirect    = 1'b0;
        tb_redirect_pc = {NB_PC{1'b0}};
        tb_stop_fetch  = 1'b0;
        tb_imem_b_en   = 1'b0;
        tb_imem_b_we   = 1'b0;
        tb_imem_b_addr = {IMEM_AW{1'b0}};
        tb_imem_b_din  = {NB_INSTR{1'b0}};
        m_pc           = {NB_PC{1'b0}};
        m_valid        = 1'b0;
        m_if_id_pc     = {NB_PC{1'b0}};
        m_instr        = {NB_INSTR{1'b0}};

        // Palabras distintas: 0xA5 en el byte alto y el índice abajo
        for (k = 0; k < IMEM_WORDS; k = k + 1)
            mem[k] = 32'hA500_0000 | (k << 4) | (k & 15);

        // Carga por el puerto B con el core en reset y en = 0, como LOAD
        @(negedge tb_clk);
        for (k = 0; k < IMEM_WORDS; k = k + 1) begin
            tb_imem_b_en   = 1'b1;
            tb_imem_b_we   = 1'b1;
            tb_imem_b_addr = k[IMEM_AW-1:0];
            tb_imem_b_din  = mem[k];
            @(negedge tb_clk);
        end
        tb_imem_b_en = 1'b0;
        tb_imem_b_we = 1'b0;

        // Reset: PC = 0 e IF/ID en burbuja
        ciclo(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, {NB_PC{1'b0}}, 1'b0);
        chk_modelo("reset");
        chk("reset pc = 0", tb_o_pc, 32'h0000_0000);
        chk("reset valid = 0", tb_o_if_id_valid, 1'b0);

        // Arranque: el primer ciclo habilitado trae instr(0) con pc = 0
        tb_rst = 1'b0;
        normal;
        chk_modelo("arranque");
        chk("arranque if_id_pc", tb_o_if_id_pc, 32'h0000_0000);
        chk("arranque if_id_instr", tb_o_if_id_instr, mem[0]);
        chk("arranque pc", tb_o_pc, 32'h0000_0004);

        // Secuencia pc, pc + 4, ...
        for (i = 1; i < 8; i = i + 1) begin
            normal;
            chk_modelo("secuencia");
            chk("secuencia if_id", tb_o_if_id_latch, {1'b1, 32'h0 + 4*i, mem[i]});
        end

        // Core detenido (enable = 0): nada cambia, tampoco con flush
        tomar_foto;
        for (i = 0; i < 4; i = i + 1) begin
            ciclo(1'b0, 1'b0, 1'b0, i[0], 1'b0, {NB_PC{1'b0}}, 1'b0);
            chk_foto("en = 0 conserva");
        end
        // Al volver, sigue donde quedó
        normal;
        chk_modelo("retoma tras en = 0");
        chk("retoma if_id_pc", tb_o_if_id_pc, foto_pc);

        // flush con en = 1: burbuja; el PC sigue avanzando
        ciclo(1'b0, 1'b1, 1'b1, 1'b1, 1'b0, {NB_PC{1'b0}}, 1'b0);
        chk_modelo("flush carga burbuja");
        chk("flush valid = 0", tb_o_if_id_valid, 1'b0);
        normal;
        chk_modelo("carga tras flush");

        // Burbuja retenida sigue siendo burbuja
        ciclo(1'b0, 1'b1, 1'b1, 1'b1, 1'b0, {NB_PC{1'b0}}, 1'b0);
        tomar_foto;
        ciclo(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, {NB_PC{1'b0}}, 1'b0);
        chk_foto("en = 0 conserva burbuja");
        normal;
        chk_modelo("carga tras burbuja");

        // Salto tomado: PC <- redirect_pc, lo que entra es burbuja
        ciclo(1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 32'h0000_0200, 1'b0);
        chk_modelo("redirect");
        chk("redirect pc", tb_o_pc, 32'h0000_0200);
        chk("redirect valid = 0", tb_o_if_id_valid, 1'b0);
        normal;
        chk_modelo("destino del salto");
        chk("destino del salto", tb_o_if_id_latch, {1'b1, 32'h0000_0200, mem[32'h200 >> 2]});
        normal;
        chk_modelo("destino + 4");

        // Salto hacia atrás
        ciclo(1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 32'h0000_0010, 1'b0);
        chk_modelo("redirect hacia atrás");
        normal;
        chk_modelo("destino hacia atrás");

        // Salto con el core detenido: no pasa nada (en gana)
        tomar_foto;
        ciclo(1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 32'h0000_0300, 1'b0);
        chk_foto("redirect con en = 0");

        // HALT en vuelo: stop_fetch retiene el PC; IF/ID solo burbujas
        normal;
        normal;
        for (i = 0; i < 4; i = i + 1) begin
            ciclo(1'b0, 1'b1, 1'b1, 1'b1, 1'b0, {NB_PC{1'b0}}, 1'b1);
            chk_modelo("stop_fetch");
            chk("stop_fetch valid = 0", tb_o_if_id_valid, 1'b0);
        end
        // redirect gana sobre stop_fetch (HALT en el camino equivocado)
        ciclo(1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 32'h0000_0100, 1'b1);
        chk_modelo("redirect > stop_fetch");
        chk("redirect > stop_fetch pc", tb_o_pc, 32'h0000_0100);

        // HALT retenido por un stall: en = 0 con flush = 1 conserva
        normal;
        tomar_foto;
        for (i = 0; i < 3; i = i + 1) begin
            ciclo(1'b0, 1'b0, 1'b0, 1'b1, 1'b0, {NB_PC{1'b0}}, 1'b1);
            chk_foto("stall con stop_fetch conserva");
        end

        // Reset con el core detenido: gana el reset
        ciclo(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, {NB_PC{1'b0}}, 1'b0);
        chk_modelo("rst con en = 0");
        chk("rst con en = 0 pc", tb_o_pc, 32'h0000_0000);
        chk("rst con en = 0 valid", tb_o_if_id_valid, 1'b0);

        // Estímulo aleatorio con semilla fija contra el modelo. Los en_*
        // van juntos casi siempre (en el core son iguales), y a veces no
        ciclo(1'b1, 1'b1, 1'b1, 1'b0, 1'b0, {NB_PC{1'b0}}, 1'b0);
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            tb_en_pc = (($random(seed) & 3) != 0);              // 3/4
            ciclo((($random(seed) & 63) == 0),                  // rst        1/64
                  tb_en_pc,
                  ((($random(seed) & 15) == 0) ? ~tb_en_pc : tb_en_pc),
                  (($random(seed) & 7)  == 0),                  // flush      1/8
                  (($random(seed) & 15) == 0),                  // redirect   1/16
                  $random(seed),                                // cualquier destino
                  (($random(seed) & 15) == 0));                 // stop_fetch 1/16
            chk_modelo("aleatorio");
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
