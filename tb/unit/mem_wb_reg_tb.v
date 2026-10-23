`timescale 1ns / 1ps

//======================================================================
// mem_wb_reg_tb
//
// Testbench autoverificante de mem_wb_reg (docs/spec/verificacion.md
// §3.1: "igual que ID/EX (110 bits)").
//
// Casos:
//   - Reset carga burbuja (valid = 0 y control en 0), también con
//     en = 0 (rst > en) y con flush = 1
//   - en = 1 sin flush carga los 10 campos
//   - flush carga burbuja aunque la instrucción de MEM traiga todo el
//     control en 1, y al soltarlo vuelve a cargar
//   - Una burbuja de EX/MEM (valid = 0, control en 0) pasa como burbuja
//   - en = 0 conserva los 110 bits, también con flush = 1 (core
//     detenido, pipeline.md §2 y §10.4)
//   - Bit a bit: con en = 1, un 1 (y un 0) en cada posición de los 110
//     bits llega a su puerto y a su lugar de o_latch; detecta campos
//     cruzados o truncados
//   - o_read_data es i_read_data sin registrar (decisión 009): un
//     cambio en la salida de la BRAM se ve sin flanco, en el puerto y
//     en o_latch, y los 78 bits en flip-flops no cambian
//   - Barrido exhaustivo de {rst, en, flush} x i_valid desde un estado
//     válido
//   - Estímulo aleatorio con semilla fija contra un modelo de §2
//
// read_data no lo guarda mem_wb_reg: es el registro de salida de dmem
// (pipeline.md §6.3). El testbench emula ese registro con
// ena = en_mem_wb, como lo conecta la I-34 (§10.4), y así los 110 bits
// de MEM/WB se comportan como un solo registro. tb_read_data es la
// palabra que la BRAM lee en el ciclo y tb_bram_dout su salida, que
// entra a i_read_data.
//
// El orden de los campos (pipeline.md §8, el primero en los bits altos)
// lo arma este testbench concatenando sus entradas y los puertos de
// salida uno por uno; no usa el agrupamiento interno del módulo.
// offset no se ata a result[1:0]: el registro lo copia de i_offset, y
// moverlo aparte detecta si se cruza con otro campo.
// Como en la traza del modelo (tools/isasim/isasim/latches.py), en una
// burbuja solo se comparan valid y las 3 señales de control: los datos
// no importan (pipeline.md §2) y no tienen reset.
//
// Los estímulos cambian en el flanco de bajada y se comprueban en el
// flanco de bajada siguiente, después de un flanco de subida.
//======================================================================

module mem_wb_reg_tb;

    localparam integer NB_PC      = 32;
    localparam integer NB_DATA    = 32;
    localparam integer NB_ADDR    = 5;
    localparam integer NB_FUNCT3  = 3;
    localparam integer NB_OFFSET  = 2;
    localparam integer NB_LATCH   = 110;    // pipeline.md §8
    localparam integer NB_CTRL    = 3;      // reg_write, mem_to_reg, halt
    localparam integer T_CLK      = 10;     // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM   = 2000;   // ciclos de estímulo aleatorio
    localparam integer MAX_CYCLES = 5000;   // watchdog
    localparam integer SEED       = 45;     // semilla fija (issue #45)

    // Bit menos significativo de read_data en el latch (bits 44:13)
    localparam integer LSB_READ_DATA = NB_ADDR + NB_FUNCT3 + NB_OFFSET + NB_CTRL;

    // Bits que se comparan en una burbuja: valid (bit 109) y control
    // (bits 2:0, de reg_write a halt)
    localparam [NB_LATCH-1:0] MASK_BURBUJA = {1'b1, {(NB_LATCH-1-NB_CTRL){1'b0}}, {NB_CTRL{1'b1}}};
    localparam [NB_LATCH-1:0] MASK_TODO    = {NB_LATCH{1'b1}};
    localparam [NB_LATCH-1:0] BIT_VALID    = {1'b1, {(NB_LATCH-1){1'b0}}};

    reg                  tb_clk;
    reg                  tb_rst;
    reg                  tb_en;
    reg                  tb_flush;

    reg                  tb_valid;
    reg  [NB_PC-1:0]     tb_pc;
    reg  [NB_DATA-1:0]   tb_result;
    reg  [NB_DATA-1:0]   tb_read_data;
    reg  [NB_ADDR-1:0]   tb_rd;
    reg  [NB_FUNCT3-1:0] tb_funct3;
    reg  [NB_OFFSET-1:0] tb_offset;
    reg                  tb_reg_write;
    reg                  tb_mem_to_reg;
    reg                  tb_halt;

    wire                 tb_o_valid;
    wire [NB_PC-1:0]     tb_o_pc;
    wire [NB_DATA-1:0]   tb_o_result;
    wire [NB_DATA-1:0]   tb_o_read_data;
    wire [NB_ADDR-1:0]   tb_o_rd;
    wire [NB_FUNCT3-1:0] tb_o_funct3;
    wire [NB_OFFSET-1:0] tb_o_offset;
    wire                 tb_o_reg_write;
    wire                 tb_o_mem_to_reg;
    wire                 tb_o_halt;
    wire [NB_LATCH-1:0]  tb_o_latch;

    // Salidas en el orden de pipeline.md §8
    wire [NB_LATCH-1:0] tb_salida = {
        tb_o_valid, tb_o_pc, tb_o_result, tb_o_read_data, tb_o_rd,
        tb_o_funct3, tb_o_offset, tb_o_reg_write, tb_o_mem_to_reg,
        tb_o_halt
    };

    // Registro de salida del puerto A de dmem (decisión 009), con
    // ena = en_mem_wb y sin reset, como la BRAM
    reg  [NB_DATA-1:0]   tb_bram_dout;

    always @(posedge tb_clk) begin
        if (tb_en)
            tb_bram_dout <= tb_read_data;
    end

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer combo;

    reg [NB_LATCH-1:0] modelo;
    reg [NB_LATCH-1:0] patron_a;
    reg [NB_LATCH-1:0] patron_b;
    reg [NB_LATCH-1:0] patron;

    mem_wb_reg #(
        .NB_PC     (NB_PC),
        .NB_DATA   (NB_DATA),
        .NB_ADDR   (NB_ADDR),
        .NB_FUNCT3 (NB_FUNCT3),
        .NB_OFFSET (NB_OFFSET)
    ) u_dut (
        .i_clk        (tb_clk),
        .i_rst        (tb_rst),
        .i_en         (tb_en),
        .i_flush      (tb_flush),
        .i_valid      (tb_valid),
        .i_pc         (tb_pc),
        .i_result     (tb_result),
        .i_read_data  (tb_bram_dout),
        .i_rd         (tb_rd),
        .i_funct3     (tb_funct3),
        .i_offset     (tb_offset),
        .i_reg_write  (tb_reg_write),
        .i_mem_to_reg (tb_mem_to_reg),
        .i_halt       (tb_halt),
        .o_valid      (tb_o_valid),
        .o_pc         (tb_o_pc),
        .o_result     (tb_o_result),
        .o_read_data  (tb_o_read_data),
        .o_rd         (tb_o_rd),
        .o_funct3     (tb_o_funct3),
        .o_offset     (tb_o_offset),
        .o_reg_write  (tb_o_reg_write),
        .o_mem_to_reg (tb_o_mem_to_reg),
        .o_halt       (tb_o_halt),
        .o_latch      (tb_o_latch)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Modelo de referencia de MEM/WB más la BRAM, escrito a partir de
    // pipeline.md §2, §6.3 y §8: prioridad rst > en > flush; rst y flush
    // cargan burbuja (valid y control en 0). Los datos de una burbuja no
    // se comparan, así que el modelo no necesita fijar qué hacen el rst
    // y el flush con ellos ni con read_data.
    //------------------------------------------------------------------
    task modelo_ciclo;
        input                rst;
        input                en;
        input                flush;
        input [NB_LATCH-1:0] entrada;
        begin
            if (rst)
                modelo = modelo & ~MASK_BURBUJA;
            else if (en) begin
                if (flush)
                    modelo = entrada & ~MASK_BURBUJA;
                else
                    modelo = entrada;
            end
        end
    endtask

    //------------------------------------------------------------------
    // Chequeo con etiqueta, para que el log diga qué caso falló
    //------------------------------------------------------------------
    task chk;
        input [8*44-1:0]     name;
        input [NB_LATCH-1:0] obtenido;
        input [NB_LATCH-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | dut=0x%h esperado=0x%h",
                         $time, name, obtenido, esperado);
            end
        end
    endtask

    // Compara los puertos y o_latch contra el modelo; en una burbuja,
    // solo valid y control
    task chk_latch;
        input [8*44-1:0] name;
        reg [NB_LATCH-1:0] mask;
        begin
            mask = modelo[NB_LATCH-1] ? MASK_TODO : MASK_BURBUJA;
            chk(name, tb_salida & mask, modelo & mask);
            chk(name, tb_o_latch & mask, modelo & mask);
        end
    endtask

    // Pone un juego de entradas en el orden de §8; read_data es la
    // palabra que lee la BRAM, que aparece en i_read_data tras el flanco
    task poner;
        input [NB_LATCH-1:0] v;
        begin
            {tb_valid, tb_pc, tb_result, tb_read_data, tb_rd, tb_funct3,
             tb_offset, tb_reg_write, tb_mem_to_reg, tb_halt} = v;
        end
    endtask

    // Aplica un juego de entradas durante un ciclo (un flanco de subida)
    // y actualiza el modelo
    task ciclo;
        input                rst;
        input                en;
        input                flush;
        input [NB_LATCH-1:0] entrada;
        begin
            tb_rst   = rst;
            tb_en    = en;
            tb_flush = flush;
            poner(entrada);
            modelo_ciclo(rst, en, flush, entrada);
            @(negedge tb_clk);
        end
    endtask

    // Cambia la salida de la BRAM sin flanco: o_read_data y su lugar de
    // o_latch la siguen y el resto de los 110 bits no cambia
    task chk_read_data_sin_flanco;
        input [NB_DATA-1:0] palabra;
        begin
            tb_bram_dout = palabra;
            modelo[LSB_READ_DATA +: NB_DATA] = palabra;
            #1;
            chk("o_read_data = i_read_data sin flanco",
                {{(NB_LATCH-NB_DATA){1'b0}}, tb_o_read_data},
                {{(NB_LATCH-NB_DATA){1'b0}}, palabra});
            chk("o_latch sigue a i_read_data sin flanco", tb_o_latch, modelo);
            chk("puertos siguen a i_read_data sin flanco", tb_salida, modelo);
        end
    endtask

    // 110 bits al azar
    function [NB_LATCH-1:0] al_azar;
        input dummy;
        reg [127:0] r;
        begin
            r = {$random(seed), $random(seed), $random(seed), $random(seed)};
            al_azar = r[NB_LATCH-1:0];
        end
    endfunction

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors = 0;
        checks = 0;
        seed   = SEED;
        modelo = {NB_LATCH{1'b0}};
        tb_rst   = 1'b1;
        tb_en    = 1'b0;
        tb_flush = 1'b0;
        poner({NB_LATCH{1'b0}});

        // Instrucción con todo el control en 1 y datos que no se
        // confunden entre campos; patron_b difiere en todos los bits
        patron_a = {1'b1, 32'h0000_0104, 32'h1111_1111, 32'h2222_2222,
                    5'd3, 3'b101, 2'b10, 3'b111};
        patron_b = ~patron_a;

        // Reset: burbuja, aunque la entrada sea válida y con control en 1
        @(negedge tb_clk);
        ciclo(1'b1, 1'b1, 1'b0, patron_a);
        chk_latch("reset");
        ciclo(1'b1, 1'b0, 1'b0, patron_a);
        chk_latch("reset con en = 0");
        ciclo(1'b1, 1'b1, 1'b1, patron_a);
        chk_latch("reset con flush");

        // Carga normal
        ciclo(1'b0, 1'b1, 1'b0, patron_a);
        chk_latch("carga");
        chk("carga: los 110 bits", tb_salida, patron_a);
        chk("carga: o_latch", tb_o_latch, patron_a);

        // Una burbuja de EX/MEM pasa como burbuja
        ciclo(1'b0, 1'b1, 1'b0, patron_a & ~MASK_BURBUJA);
        chk_latch("burbuja de EX/MEM");

        // flush carga burbuja aunque MEM traiga todo el control en 1
        ciclo(1'b0, 1'b1, 1'b0, patron_a);
        ciclo(1'b0, 1'b1, 1'b1, patron_a);
        chk_latch("flush carga burbuja");
        chk("flush: control en 0", tb_salida & MASK_BURBUJA, {NB_LATCH{1'b0}});
        ciclo(1'b0, 1'b1, 1'b1, patron_b | BIT_VALID);
        chk_latch("flush seguido");
        ciclo(1'b0, 1'b1, 1'b0, patron_b | BIT_VALID);
        chk_latch("carga tras flush");

        // en = 0 conserva los 110 bits (78 aquí y 32 en la BRAM)
        ciclo(1'b0, 1'b1, 1'b0, patron_a);
        for (i = 0; i < 3; i = i + 1) begin
            ciclo(1'b0, 1'b0, 1'b0, al_azar(0));
            chk_latch("en = 0 conserva");
            chk("en = 0 conserva: los 110 bits", tb_salida, patron_a);
        end

        // Core detenido: en = 0 gana sobre flush = 1
        for (i = 0; i < 3; i = i + 1) begin
            ciclo(1'b0, 1'b0, 1'b1, al_azar(0));
            chk_latch("en = 0 conserva con flush");
            chk("en = 0 con flush: los 110 bits", tb_salida, patron_a);
        end
        // Al volver enable con flush, carga burbuja
        ciclo(1'b0, 1'b1, 1'b1, patron_b | BIT_VALID);
        chk_latch("flush al volver enable");
        // Una burbuja retenida sigue siendo burbuja
        ciclo(1'b0, 1'b0, 1'b0, patron_a);
        chk_latch("en = 0 conserva burbuja");

        // rst gana sobre en = 0 y sobre flush
        ciclo(1'b0, 1'b1, 1'b0, patron_a);
        ciclo(1'b1, 1'b0, 1'b0, patron_b | BIT_VALID);
        chk_latch("rst con en = 0");
        ciclo(1'b0, 1'b1, 1'b0, patron_a);
        ciclo(1'b1, 1'b0, 1'b1, patron_b | BIT_VALID);
        chk_latch("rst con en = 0 y flush");

        // read_data no pasa por flip-flops de mem_wb_reg (decisión 009):
        // con en = 1 y con en = 0, un cambio en la salida de la BRAM se
        // ve sin flanco y el resto de los campos no cambia
        ciclo(1'b0, 1'b1, 1'b0, patron_a);
        chk_read_data_sin_flanco(32'hDEAD_BEEF);
        chk_read_data_sin_flanco(32'h0000_0000);
        tb_en = 1'b0;
        chk_read_data_sin_flanco(32'hFFFF_FFFF);
        chk_read_data_sin_flanco(32'h8000_0001);
        @(negedge tb_clk);
        chk_latch("en = 0 tras cambiar read_data");

        // Bit a bit: un 1 y un 0 en cada posición, con valid = 1 para que
        // se comparen todos los bits. Cada puerto y o_latch tienen que
        // dar exactamente la entrada, también read_data a través de la
        // BRAM emulada.
        for (i = 0; i < NB_LATCH; i = i + 1) begin
            patron = ({{(NB_LATCH-1){1'b0}}, 1'b1} << i) | BIT_VALID;
            ciclo(1'b0, 1'b1, 1'b0, patron);
            chk("un 1 por bit: puertos", tb_salida, patron);
            chk("un 1 por bit: o_latch", tb_o_latch, patron);
            if (tb_salida !== patron || tb_o_latch !== patron)
                $display("        bit %0d", i);
            patron = ~({{(NB_LATCH-1){1'b0}}, 1'b1} << i) | BIT_VALID;
            ciclo(1'b0, 1'b1, 1'b0, patron);
            chk("un 0 por bit: puertos", tb_salida, patron);
            chk("un 0 por bit: o_latch", tb_o_latch, patron);
            if (tb_salida !== patron || tb_o_latch !== patron)
                $display("        bit %0d", i);
        end

        // Barrido exhaustivo de {rst, en, flush} x i_valid desde un
        // estado válido, con una entrada distinta en todos los bits
        for (combo = 0; combo < 16; combo = combo + 1) begin
            ciclo(1'b0, 1'b1, 1'b0, patron_a);
            patron = combo[3] ? (patron_b | BIT_VALID) : (patron_b & ~BIT_VALID);
            ciclo(combo[2], combo[1], combo[0], patron);
            i = errors;
            chk_latch("barrido {rst,en,flush} x valid");
            if (errors != i)
                $display("        combo {valid,rst,en,flush} = %b", combo[3:0]);
        end

        // Estímulo aleatorio con semilla fija contra el modelo
        ciclo(1'b1, 1'b1, 1'b0, {NB_LATCH{1'b0}});
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            patron = al_azar(0);
            patron[NB_LATCH-1] = (($random(seed) & 3) != 0);   // valid 3/4
            ciclo((($random(seed) & 31) == 0),                 // rst   1/32
                  (($random(seed) & 3)  != 0),                 // en    3/4
                  (($random(seed) & 7)  == 0),                 // flush 1/8
                  patron);
            chk_latch("aleatorio");
            chk("aleatorio: o_latch = puertos", tb_o_latch, tb_salida);
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
