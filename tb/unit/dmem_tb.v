`timescale 1ns / 1ps

//======================================================================
// dmem_tb
//
// Testbench autoverificante de dmem (docs/spec/verificacion.md §3.1).
// Simula el IP dmem_bram, así que corre en xsim dentro del proyecto de
// Vivado; necesita ~103 µs (run all), más que los 1000 ns por defecto.
//
// Casos:
//   - Reset: avisos en 0. Contenido inicial en cero (memoria.md §3.6),
//     leído por los dos puertos
//   - Carga de las 1024 palabras por el puerto B con el puerto A
//     deshabilitado, como la hace el banco incremental, con el estado
//     inicial de los indep_* (sw/estado_inicial/dmem.hex) en 0x100,
//     0x104 y 0xFFC; relectura por los dos puertos
//   - Latencia de un ciclo en los dos puertos: el dato aparece en el
//     flanco siguiente, no antes (decisión 009)
//   - i_a_en = 0 conserva la salida y no escribe aunque haya un store
//   - Escritura parcial: sb en los 4 offsets, sh en los 2 y sw, con
//     bits basura en el dato; los bytes no escritos y las palabras
//     vecinas no cambian
//   - Ejemplos little-endian de memoria.md §5. Un load entrega la
//     palabra completa con cualquier funct3: la extensión es de WB
//   - READ_FIRST: en el ciclo del store o_a_dout trae la palabra vieja
//   - Un load no escribe; un funct3 que no es sb ni sh escribe como sw
//   - Alias y avisos (memoria.md §6.1 y §6.2): lw/lh/lhu/sw/sh
//     desalineados caen en la palabra o media palabra alineada y
//     levantan dmem_misaligned; los de byte nunca; addr >= 0x1000 cae
//     en addr mod 4096 y levanta dmem_oob. Los avisos persisten, una
//     burbuja o i_a_en = 0 no los levantan, i_rst los borra (también
//     con un acceso malo en el mismo ciclo) y no toca la memoria
//   - Puerto B: en sin we no escribe, we sin en tampoco, we por byte,
//     en = 0 conserva la salida
//   - Estímulo aleatorio con semilla fija contra un modelo de memoria
//     del testbench, y volcado final de las 1024 palabras por el B
//
// El modelo es un arreglo de bytes: un store escribe sus 1, 2 o 4
// bytes desde la dirección alineada a su tamaño, dentro de los 4 KiB.
// No usa la máscara ni la replicación de pipeline.md §6.2, para no
// repetir el diseño (verificacion.md §2); los casos dirigidos además
// comparan contra constantes escritas a mano. Cada ciclo del puerto A
// compara o_a_dout y los dos avisos contra el modelo.
//
// No lee archivos ni el arreglo interno del IP (decisión 027): las
// tres palabras del estado inicial se escriben por el puerto B, como lo
// hace el banco incremental con dmem_init.hex (STAGE_MEM, I-34).
//
// Los estímulos cambian en el flanco de bajada y se comprueban en el
// flanco de bajada siguiente, después de un flanco de subida.
//======================================================================

module dmem_tb;

    localparam integer NB_DATA    = 32;
    localparam integer NB_ADDR    = 32;
    localparam integer NB_FUNCT3  = 3;
    localparam integer NB_WE      = 4;
    localparam integer NB_BYTE    = 8;
    localparam integer DMEM_AW    = 10;
    localparam integer DMEM_WORDS = 1 << DMEM_AW;
    localparam integer DMEM_BYTES = 4 * DMEM_WORDS;
    localparam integer T_CLK      = 10;     // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM   = 4000;   // ciclos de estímulo aleatorio
    localparam integer SEED       = 44;     // semilla fija (issue #44)
    localparam integer MAX_CYCLES = 20000;  // watchdog

    // Estado inicial de los indep_* (sw/estado_inicial/dmem.hex)
    localparam integer       IDX_INI_0 = 'h040;            // 0x100
    localparam integer       IDX_INI_1 = 'h041;            // 0x104
    localparam integer       IDX_INI_2 = 'h3FF;            // 0xFFC
    localparam [NB_DATA-1:0] INI_0     = 32'hDEAD_BEEF;
    localparam [NB_DATA-1:0] INI_1     = 32'h7F01_8040;
    localparam [NB_DATA-1:0] INI_2     = 32'hCAFE_BABE;

    localparam [NB_WE-1:0] WE_NONE = 4'b0000;
    localparam [NB_WE-1:0] WE_WORD = 4'b1111;

    `include "riscv_defs.vh"

    reg                  tb_clk;
    reg                  tb_rst;
    reg                  tb_a_en;
    reg  [NB_ADDR-1:0]   tb_a_addr;
    reg  [NB_FUNCT3-1:0] tb_a_funct3;
    reg                  tb_a_store;
    reg                  tb_a_load;
    reg  [NB_DATA-1:0]   tb_a_store_data;
    wire [NB_DATA-1:0]   tb_o_a_dout;
    wire                 tb_o_oob;
    wire                 tb_o_misaligned;
    reg                  tb_b_en;
    reg  [NB_WE-1:0]     tb_b_we;
    reg  [DMEM_AW-1:0]   tb_b_addr;
    reg  [NB_DATA-1:0]   tb_b_din;
    wire [NB_DATA-1:0]   tb_o_b_dout;

    // Modelo
    reg  [NB_BYTE-1:0]   ref_mem [0:DMEM_BYTES-1];
    reg  [NB_DATA-1:0]   exp_a_dout;
    reg                  exp_oob;
    reg                  exp_mis;

    // Estímulo aleatorio
    reg                  r_rst;
    reg                  r_en;
    reg  [2:0]           r_op;
    reg  [NB_FUNCT3-1:0] r_f3;
    reg  [NB_ADDR-1:0]   r_addr;
    reg  [NB_DATA-1:0]   r_d;

    reg  [NB_DATA-1:0]   w;
    integer errors;
    integer checks;
    integer k;
    integer seed;

    dmem u_dut (
        .i_clk          (tb_clk),
        .i_rst          (tb_rst),
        .i_a_en         (tb_a_en),
        .i_a_addr       (tb_a_addr),
        .i_a_funct3     (tb_a_funct3),
        .i_a_store      (tb_a_store),
        .i_a_load       (tb_a_load),
        .i_a_store_data (tb_a_store_data),
        .o_a_dout       (tb_o_a_dout),
        .o_oob          (tb_o_oob),
        .o_misaligned   (tb_o_misaligned),
        .i_b_en         (tb_b_en),
        .i_b_we         (tb_b_we),
        .i_b_addr       (tb_b_addr),
        .i_b_din        (tb_b_din),
        .o_b_dout       (tb_o_b_dout)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Palabra que se carga en dmem[k]: distinta para cada k y para cada
    // bit de la dirección; en las tres del estado inicial, su valor
    //------------------------------------------------------------------
    function [NB_DATA-1:0] patron;
        input integer idx;
        reg [DMEM_AW-1:0] a;
        begin
            a      = idx;
            patron = {~a, 6'h2A, a, 6'h15};
        end
    endfunction

    function [NB_DATA-1:0] carga;
        input integer idx;
        begin
            case (idx)
                IDX_INI_0: carga = INI_0;
                IDX_INI_1: carga = INI_1;
                IDX_INI_2: carga = INI_2;
                default:   carga = patron(idx);
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // Modelo de memoria
    //------------------------------------------------------------------
    // Bytes que toca un load o un store según su funct3 (isa.md)
    function integer tam;
        input [NB_FUNCT3-1:0] f3;
        begin
            case (f3)
                FUNCT3_LB, FUNCT3_LBU: tam = 1;     // y sb
                FUNCT3_LH, FUNCT3_LHU: tam = 2;     // y sh
                default:               tam = 4;     // lw, sw
            endcase
        end
    endfunction

    // Palabra idx, little-endian: el byte de la dirección más baja abajo
    function [NB_DATA-1:0] ref_word;
        input integer idx;
        begin
            ref_word = {ref_mem[4*idx+3], ref_mem[4*idx+2],
                        ref_mem[4*idx+1], ref_mem[4*idx]};
        end
    endfunction

    // Store: n bytes desde la dirección alineada a n, en addr mod 4096
    task ref_store;
        input [NB_ADDR-1:0]   addr;
        input [NB_FUNCT3-1:0] f3;
        input [NB_DATA-1:0]   d;
        integer n;
        integer base;
        integer i;
        begin
            n    = tam(f3);
            base = addr % DMEM_BYTES;
            base = base - base % n;
            for (i = 0; i < n; i = i + 1)
                ref_mem[base + i] = d[NB_BYTE*i +: NB_BYTE];
        end
    endtask

    //------------------------------------------------------------------
    // Chequeo con etiqueta, para que el log diga qué caso falló
    //------------------------------------------------------------------
    task chk;
        input [8*44-1:0]    caso;
        input [8*16-1:0]    campo;
        input [NB_DATA-1:0] obtenido;
        input [NB_DATA-1:0] esperado;
        begin
            checks = checks + 1;
            if (obtenido !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s, %0s | dut=0x%08h esperado=0x%08h",
                         $time, caso, campo, obtenido, esperado);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Un ciclo del puerto A. Antes del flanco calcula lo esperado con el
    // modelo; después compara o_a_dout (con i_a_en = 1, la palabra que
    // había: READ_FIRST; si no, la salida anterior) y los dos avisos.
    // Al volver deja el puerto A en reposo (en = 0, sin load ni store).
    //------------------------------------------------------------------
    task ciclo_a;
        input [8*44-1:0]      caso;
        input                 rst;
        input                 en;
        input                 store;
        input                 load;
        input [NB_FUNCT3-1:0] f3;
        input [NB_ADDR-1:0]   addr;
        input [NB_DATA-1:0]   d;
        begin
            tb_rst          = rst;
            tb_a_en         = en;
            tb_a_store      = store;
            tb_a_load       = load;
            tb_a_funct3     = f3;
            tb_a_addr       = addr;
            tb_a_store_data = d;

            if (en)
                exp_a_dout = ref_word((addr % DMEM_BYTES) / 4);
            if (en && store)
                ref_store(addr, f3, d);
            if (rst) begin
                exp_oob = 1'b0;
                exp_mis = 1'b0;
            end
            else if (en && (store || load)) begin
                if (addr >= DMEM_BYTES)    exp_oob = 1'b1;
                if (addr % tam(f3) != 0)   exp_mis = 1'b1;
            end

            @(negedge tb_clk);
            chk(caso, "o_a_dout",     tb_o_a_dout,     exp_a_dout);
            chk(caso, "o_oob",        tb_o_oob,        exp_oob);
            chk(caso, "o_misaligned", tb_o_misaligned, exp_mis);

            tb_rst     = 1'b0;
            tb_a_en    = 1'b0;
            tb_a_store = 1'b0;
            tb_a_load  = 1'b0;
        end
    endtask

    task leer_a;
        input [8*44-1:0]      caso;
        input [NB_FUNCT3-1:0] f3;
        input [NB_ADDR-1:0]   addr;
        begin
            ciclo_a(caso, 1'b0, 1'b1, 1'b0, 1'b1, f3, addr, {NB_DATA{1'b0}});
        end
    endtask

    task store_a;
        input [8*44-1:0]      caso;
        input [NB_FUNCT3-1:0] f3;
        input [NB_ADDR-1:0]   addr;
        input [NB_DATA-1:0]   d;
        begin
            ciclo_a(caso, 1'b0, 1'b1, 1'b1, 1'b0, f3, addr, d);
        end
    endtask

    // Ciclo de reset con el puerto A deshabilitado, como core_rst
    task reset_avisos;
        begin
            ciclo_a("reset de avisos", 1'b1, 1'b0, 1'b0, 1'b0,
                    FUNCT3_LW, {NB_ADDR{1'b0}}, {NB_DATA{1'b0}});
        end
    endtask

    // Lee una palabra alineada por el puerto A y la compara con un valor
    // escrito a mano
    task chk_palabra;
        input [8*44-1:0]    caso;
        input [NB_ADDR-1:0] addr;
        input [NB_DATA-1:0] esperado;
        begin
            leer_a(caso, FUNCT3_LW, addr);
            chk(caso, "palabra", tb_o_a_dout, esperado);
        end
    endtask

    //------------------------------------------------------------------
    // Un ciclo del puerto B con en y we explícitos; actualiza el modelo.
    // En un ciclo de lectura (en = 1, we = 0000) compara o_b_dout. En uno
    // de escritura no: el modo del puerto B es indistinto (memoria.md
    // §3.2).
    //------------------------------------------------------------------
    task puerto_b;
        input [8*44-1:0]    caso;
        input               en;
        input [NB_WE-1:0]   we;
        input [DMEM_AW-1:0] addr;
        input [NB_DATA-1:0] din;
        reg   [NB_DATA-1:0] esperado;
        integer i;
        begin
            tb_b_en   = en;
            tb_b_we   = we;
            tb_b_addr = addr;
            tb_b_din  = din;
            esperado  = ref_word(addr);
            if (en)
                for (i = 0; i < NB_WE; i = i + 1)
                    if (we[i])
                        ref_mem[4*addr + i] = din[NB_BYTE*i +: NB_BYTE];
            @(negedge tb_clk);
            if (en && we == WE_NONE)
                chk(caso, "o_b_dout", tb_o_b_dout, esperado);
            tb_b_en = 1'b0;
            tb_b_we = WE_NONE;
        end
    endtask

    task escribir_b;
        input [DMEM_AW-1:0] addr;
        input [NB_DATA-1:0] din;
        begin
            puerto_b("escritura por el puerto B", 1'b1, WE_WORD, addr, din);
        end
    endtask

    task leer_b;
        input [8*44-1:0]    caso;
        input [DMEM_AW-1:0] addr;
        begin
            puerto_b(caso, 1'b1, WE_NONE, addr, {NB_DATA{1'b0}});
        end
    endtask

    //------------------------------------------------------------------
    // Escritura parcial sobre la palabra 0x200 = 0x1122_3344, con las
    // vecinas 0x1FC y 0x204 cargadas con su patrón
    //------------------------------------------------------------------
    task parcial;
        input [8*44-1:0]      caso;
        input [NB_FUNCT3-1:0] f3;
        input [NB_ADDR-1:0]   addr;
        input [NB_DATA-1:0]   d;
        input [NB_DATA-1:0]   esperado;
        begin
            escribir_b('h200 / 4, 32'h1122_3344);
            store_a(caso, f3, addr, d);
            chk_palabra(caso, 32'h0000_0200, esperado);
            chk_palabra("vecina anterior intacta", 32'h0000_01FC, patron('h1FC / 4));
            chk_palabra("vecina siguiente intacta", 32'h0000_0204, patron('h204 / 4));
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors          = 0;
        checks          = 0;
        tb_rst          = 1'b1;
        tb_a_en         = 1'b0;
        tb_a_addr       = {NB_ADDR{1'b0}};
        tb_a_funct3     = FUNCT3_LW;
        tb_a_store      = 1'b0;
        tb_a_load       = 1'b0;
        tb_a_store_data = {NB_DATA{1'b0}};
        tb_b_en         = 1'b0;
        tb_b_we         = WE_NONE;
        tb_b_addr       = {DMEM_AW{1'b0}};
        tb_b_din        = {NB_DATA{1'b0}};
        exp_a_dout      = {NB_DATA{1'b0}};
        exp_oob         = 1'b0;
        exp_mis         = 1'b0;
        for (k = 0; k < DMEM_BYTES; k = k + 1)
            ref_mem[k] = {NB_BYTE{1'b0}};

        // Reset: avisos en 0
        repeat (2) @(negedge tb_clk);
        tb_rst = 1'b0;
        chk("reset", "o_oob",        tb_o_oob,        1'b0);
        chk("reset", "o_misaligned", tb_o_misaligned, 1'b0);

        // Contenido inicial: ceros (el modelo arranca en cero)
        for (k = 0; k < DMEM_WORDS; k = k + 1)
            leer_a("contenido inicial, puerto A", FUNCT3_LW, 4 * k);
        for (k = 0; k < DMEM_WORDS; k = k + 1)
            leer_b("contenido inicial, puerto B", k);

        // Carga por el puerto B con el A deshabilitado. Mientras tanto la
        // salida del A conserva la última palabra leída (0)
        for (k = 0; k < DMEM_WORDS; k = k + 1) begin
            escribir_b(k, carga(k));
            chk("a_en = 0 durante la carga", "o_a_dout", tb_o_a_dout, {NB_DATA{1'b0}});
        end
        for (k = 0; k < DMEM_WORDS; k = k + 1)
            chk_palabra("relectura tras la carga, puerto A", 4 * k, carga(k));
        for (k = 0; k < DMEM_WORDS; k = k + 1) begin
            leer_b("relectura tras la carga, puerto B", k);
            chk("relectura tras la carga, puerto B", "palabra", tb_o_b_dout, carga(k));
        end

        // Latencia de un ciclo: antes del flanco la salida no cambia
        chk_palabra("latencia A: 0x010", 32'h0000_0010, patron(4));
        tb_a_en     = 1'b1;
        tb_a_load   = 1'b1;
        tb_a_funct3 = FUNCT3_LW;
        tb_a_addr   = 32'h0000_0014;
        #1;
        chk("latencia A: sin dato antes del flanco", "palabra", tb_o_a_dout, patron(4));
        @(negedge tb_clk);
        chk("latencia A: dato tras un flanco", "palabra", tb_o_a_dout, patron(5));
        tb_a_en    = 1'b0;
        tb_a_load  = 1'b0;
        exp_a_dout = patron(5);             // ciclo hecho a mano, fuera de ciclo_a

        leer_b("latencia B: 0x018", 10'd6);
        tb_b_en   = 1'b1;
        tb_b_addr = 10'd7;
        #1;
        chk("latencia B: sin dato antes del flanco", "palabra", tb_o_b_dout, patron(6));
        @(negedge tb_clk);
        chk("latencia B: dato tras un flanco", "palabra", tb_o_b_dout, patron(7));
        tb_b_en = 1'b0;

        // i_a_en = 0 conserva la salida y no escribe aunque haya un store
        chk_palabra("a_en: lectura previa", 32'h0000_001C, patron(7));
        for (k = 0; k < 3; k = k + 1) begin
            ciclo_a("a_en = 0 con un store", 1'b0, 1'b0, 1'b1, 1'b0,
                    FUNCT3_SW, 32'h0000_0020 + 4 * k, 32'hFFFF_FFFF);
            chk("a_en = 0 conserva la salida", "palabra", tb_o_a_dout, patron(7));
        end
        for (k = 0; k < 3; k = k + 1)
            chk_palabra("a_en = 0 no escribe", 32'h0000_0020 + 4 * k, patron(8 + k));

        // Escritura parcial: solo cambian los bytes del store, con bits
        // basura en el dato que no se tienen que escribir
        parcial("sb offset 0", FUNCT3_SB, 32'h0000_0200, 32'hA5A5_A5EE, 32'h1122_33EE);
        parcial("sb offset 1", FUNCT3_SB, 32'h0000_0201, 32'hA5A5_A5EE, 32'h1122_EE44);
        parcial("sb offset 2", FUNCT3_SB, 32'h0000_0202, 32'hA5A5_A5EE, 32'h11EE_3344);
        parcial("sb offset 3", FUNCT3_SB, 32'h0000_0203, 32'hA5A5_A5EE, 32'hEE22_3344);
        parcial("sh offset 0", FUNCT3_SH, 32'h0000_0200, 32'h5A5A_BEEF, 32'h1122_BEEF);
        parcial("sh offset 2", FUNCT3_SH, 32'h0000_0202, 32'h5A5A_BEEF, 32'hBEEF_3344);
        parcial("sw",          FUNCT3_SW, 32'h0000_0200, 32'h0BAD_F00D, 32'h0BAD_F00D);

        // memoria.md §5, con 0xDEAD_BEEF en 0x100. Un load entrega la
        // palabra completa con cualquier funct3: la extensión es de WB
        chk_palabra("lw 0x100", 32'h0000_0100, INI_0);
        leer_a("lb 0x101", FUNCT3_LB, 32'h0000_0101);
        chk("lb 0x101: palabra completa", "palabra", tb_o_a_dout, INI_0);
        leer_a("lbu 0x101", FUNCT3_LBU, 32'h0000_0101);
        chk("lbu 0x101: palabra completa", "palabra", tb_o_a_dout, INI_0);
        leer_a("lh 0x102", FUNCT3_LH, 32'h0000_0102);
        chk("lh 0x102: palabra completa", "palabra", tb_o_a_dout, INI_0);
        leer_a("lhu 0x102", FUNCT3_LHU, 32'h0000_0102);
        chk("lhu 0x102: palabra completa", "palabra", tb_o_a_dout, INI_0);
        store_a("sb 0x12 en 0x102", FUNCT3_SB, 32'h0000_0102, 32'h0000_0012);
        chk_palabra("sb 0x12 en 0x102", 32'h0000_0100, 32'hDE12_BEEF);
        escribir_b(IDX_INI_0, INI_0);
        store_a("sh 0x3456 en 0x102", FUNCT3_SH, 32'h0000_0102, 32'h0000_3456);
        chk_palabra("sh 0x3456 en 0x102", 32'h0000_0100, 32'h3456_BEEF);
        escribir_b(IDX_INI_0, INI_0);
        store_a("sw 0x0BADF00D en 0x100", FUNCT3_SW, 32'h0000_0100, 32'h0BAD_F00D);
        chk_palabra("sw 0x0BADF00D en 0x100", 32'h0000_0100, 32'h0BAD_F00D);
        escribir_b(IDX_INI_0, INI_0);

        // READ_FIRST: el store devuelve la palabra anterior
        store_a("READ_FIRST", FUNCT3_SW, 32'h0000_0104, 32'h1357_9BDF);
        chk("READ_FIRST: el store trae la palabra vieja", "palabra", tb_o_a_dout, INI_1);
        chk_palabra("READ_FIRST: la escritura ocurrió", 32'h0000_0104, 32'h1357_9BDF);

        // Un load no escribe, aunque traiga dato
        ciclo_a("load con dato", 1'b0, 1'b1, 1'b0, 1'b1,
                FUNCT3_LW, 32'h0000_0104, 32'hFFFF_FFFF);
        chk_palabra("un load no escribe", 32'h0000_0104, 32'h1357_9BDF);
        // Un funct3 que no es sb ni sh escribe como sw, igual que el
        // modelo de referencia (no llega: decisión 024)
        store_a("store con funct3 = 011", 3'b011, 32'h0000_0104, 32'h2468_ACE0);
        chk_palabra("funct3 = 011 escribe como sw", 32'h0000_0104, 32'h2468_ACE0);

        // Avisos. Hasta acá todos los accesos fueron alineados y en rango.
        // Una burbuja y un acceso con i_a_en = 0 no los levantan
        ciclo_a("burbuja con dirección mala", 1'b0, 1'b1, 1'b0, 1'b0,
                FUNCT3_LW, 32'h0000_1003, {NB_DATA{1'b0}});
        ciclo_a("a_en = 0 con un load malo", 1'b0, 1'b0, 1'b0, 1'b1,
                FUNCT3_LW, 32'h0000_1003, {NB_DATA{1'b0}});
        ciclo_a("a_en = 0 con un store malo", 1'b0, 1'b0, 1'b1, 1'b0,
                FUNCT3_SW, 32'h0000_1003, 32'hFFFF_FFFF);
        chk("burbuja y a_en = 0 sin avisos", "o_oob",        tb_o_oob,        1'b0);
        chk("burbuja y a_en = 0 sin avisos", "o_misaligned", tb_o_misaligned, 1'b0);
        chk_palabra("a_en = 0: el store malo no escribe", 32'h0000_0000, patron(0));

        // Bytes en cualquier offset, medias y palabras alineadas, y los
        // extremos del rango: ningún aviso
        leer_a("lb 0x103", FUNCT3_LB, 32'h0000_0103);
        leer_a("lbu 0x101", FUNCT3_LBU, 32'h0000_0101);
        store_a("sb 0x302", FUNCT3_SB, 32'h0000_0302, 32'h0000_0077);
        leer_a("lh 0x102", FUNCT3_LH, 32'h0000_0102);
        leer_a("lhu 0x106", FUNCT3_LHU, 32'h0000_0106);
        store_a("sh 0x302", FUNCT3_SH, 32'h0000_0302, 32'h0000_7788);
        leer_a("lb 0x000", FUNCT3_LB, 32'h0000_0000);
        leer_a("lb 0xFFF", FUNCT3_LB, 32'h0000_0FFF);
        leer_a("lw 0xFFC", FUNCT3_LW, 32'h0000_0FFC);
        chk("alineados y en rango sin avisos", "o_oob",        tb_o_oob,        1'b0);
        chk("alineados y en rango sin avisos", "o_misaligned", tb_o_misaligned, 1'b0);

        // lw x5, 3(x0): lee la palabra 0x000 y levanta dmem_misaligned
        leer_a("lw 0x003", FUNCT3_LW, 32'h0000_0003);
        chk("lw 0x003 lee la palabra 0x000", "palabra", tb_o_a_dout, patron(0));
        chk("lw 0x003", "o_misaligned", tb_o_misaligned, 1'b1);
        chk("lw 0x003", "o_oob",        tb_o_oob,        1'b0);
        chk_palabra("dmem_misaligned persiste", 32'h0000_0004, patron(1));
        chk("dmem_misaligned persiste", "o_misaligned", tb_o_misaligned, 1'b1);
        ciclo_a("a_en = 0 no borra el aviso", 1'b0, 1'b0, 1'b0, 1'b0,
                FUNCT3_LW, {NB_ADDR{1'b0}}, {NB_DATA{1'b0}});
        reset_avisos;
        chk("i_rst borra dmem_misaligned", "o_misaligned", tb_o_misaligned, 1'b0);
        chk_palabra("i_rst no toca la memoria", 32'h0000_0104, 32'h2468_ACE0);

        for (k = 1; k < 4; k = k + 1) begin
            leer_a("lw desalineado", FUNCT3_LW, k);
            chk("lw desalineado", "o_misaligned", tb_o_misaligned, 1'b1);
            reset_avisos;
        end
        leer_a("lh 0x001", FUNCT3_LH, 32'h0000_0001);
        chk("lh 0x001", "o_misaligned", tb_o_misaligned, 1'b1);
        reset_avisos;
        leer_a("lhu 0x003", FUNCT3_LHU, 32'h0000_0003);
        chk("lhu 0x003", "o_misaligned", tb_o_misaligned, 1'b1);
        reset_avisos;

        // sh x5, 3(x0): escribe los bytes 0x002-0x003 (we = 1100)
        w = patron(0);
        store_a("sh 0x003", FUNCT3_SH, 32'h0000_0003, 32'hA5A5_7777);
        chk("sh 0x003", "o_misaligned", tb_o_misaligned, 1'b1);
        chk_palabra("sh 0x003 escribe 0x002-0x003", 32'h0000_0000, {16'h7777, w[15:0]});
        reset_avisos;
        // sh en 0x001: escribe los bytes 0x000-0x001 (we = 0011)
        store_a("sh 0x001", FUNCT3_SH, 32'h0000_0001, 32'hA5A5_BBCC);
        chk("sh 0x001", "o_misaligned", tb_o_misaligned, 1'b1);
        chk_palabra("sh 0x001 escribe 0x000-0x001", 32'h0000_0000, 32'h7777_BBCC);
        reset_avisos;
        // sw en 0x002: escribe la palabra 0x000 completa
        store_a("sw 0x002", FUNCT3_SW, 32'h0000_0002, 32'h0F0F_0F0F);
        chk("sw 0x002", "o_misaligned", tb_o_misaligned, 1'b1);
        chk_palabra("sw 0x002 escribe la palabra 0x000", 32'h0000_0000, 32'h0F0F_0F0F);
        reset_avisos;

        // sw x5, 4(x6) con x6 = 0x1000: escribe dmem[1] y levanta dmem_oob
        store_a("sw 0x1004", FUNCT3_SW, 32'h0000_1004, 32'h5555_AAAA);
        chk("sw 0x1004", "o_oob",        tb_o_oob,        1'b1);
        chk("sw 0x1004", "o_misaligned", tb_o_misaligned, 1'b0);
        chk_palabra("sw 0x1004 escribe 0x004", 32'h0000_0004, 32'h5555_AAAA);
        chk("dmem_oob persiste", "o_oob", tb_o_oob, 1'b1);
        reset_avisos;
        chk("i_rst borra dmem_oob", "o_oob", tb_o_oob, 1'b0);
        leer_a("lw 0x1FFC", FUNCT3_LW, 32'h0000_1FFC);
        chk("lw 0x1FFC lee 0xFFC", "palabra", tb_o_a_dout, INI_2);
        chk("lw 0x1FFC", "o_oob", tb_o_oob, 1'b1);
        reset_avisos;
        leer_a("lb 0xFFFFFFFF", FUNCT3_LB, 32'hFFFF_FFFF);
        chk("lb 0xFFFFFFFF lee 0xFFC", "palabra", tb_o_a_dout, INI_2);
        chk("lb 0xFFFFFFFF", "o_oob",        tb_o_oob,        1'b1);
        chk("lb 0xFFFFFFFF", "o_misaligned", tb_o_misaligned, 1'b0);
        reset_avisos;
        leer_a("lhu 0x80000106", FUNCT3_LHU, 32'h8000_0106);
        chk("lhu 0x80000106 lee 0x104", "palabra", tb_o_a_dout, 32'h2468_ACE0);
        chk("lhu 0x80000106", "o_oob", tb_o_oob, 1'b1);
        reset_avisos;

        // Los dos avisos a la vez; i_rst gana sobre un acceso malo en el
        // mismo ciclo, que igual lee la memoria
        leer_a("lw 0x1003", FUNCT3_LW, 32'h0000_1003);
        chk("lw 0x1003", "o_oob",        tb_o_oob,        1'b1);
        chk("lw 0x1003", "o_misaligned", tb_o_misaligned, 1'b1);
        ciclo_a("i_rst gana sobre un acceso malo", 1'b1, 1'b1, 1'b0, 1'b1,
                FUNCT3_LW, 32'h0000_1003, {NB_DATA{1'b0}});
        chk("i_rst gana sobre un acceso malo", "o_oob",        tb_o_oob,        1'b0);
        chk("i_rst gana sobre un acceso malo", "o_misaligned", tb_o_misaligned, 1'b0);

        // Puerto B: en sin we, we sin en, we por byte
        puerto_b("b_en = 1, b_we = 0000 no escribe", 1'b1, WE_NONE, 10'd3, 32'hFFFF_FFFF);
        leer_b("b_en = 1, b_we = 0000 no escribe", 10'd3);
        chk("b_en = 1, b_we = 0000 no escribe", "palabra", tb_o_b_dout, patron(3));
        puerto_b("b_en = 0 no escribe", 1'b0, WE_WORD, 10'd3, 32'hFFFF_FFFF);
        leer_b("b_en = 0 no escribe", 10'd3);
        chk("b_en = 0 no escribe", "palabra", tb_o_b_dout, patron(3));
        w = patron(3);
        puerto_b("b_we por byte", 1'b1, 4'b0101, 10'd3, 32'hAABB_CCDD);
        leer_b("b_we por byte", 10'd3);
        chk("b_we = 0101 escribe los bytes 0 y 2", "palabra", tb_o_b_dout,
            {w[31:24], 8'hBB, w[15:8], 8'hDD});
        chk_palabra("el puerto A ve la escritura del B", 32'h0000_000C,
                    {w[31:24], 8'hBB, w[15:8], 8'hDD});
        // b_en = 0 conserva la salida aunque cambie la dirección
        leer_b("b_en: lectura previa", 10'd10);
        for (k = 0; k < 3; k = k + 1) begin
            tb_b_addr = 11 + k;
            @(negedge tb_clk);
            chk("b_en = 0 conserva la salida", "palabra", tb_o_b_dout, patron(10));
        end

        // Estímulo aleatorio: 3/8 stores, 3/8 loads y 2/8 burbujas;
        // i_a_en en 7/8 de los ciclos, i_rst en 1/64. Las direcciones caen
        // casi siempre en una ventana de 48 bytes (la mitad alineadas a su
        // tamaño) para que los accesos se pisen; 1/8 son cualquiera.
        seed = SEED;
        for (k = 0; k < N_RANDOM; k = k + 1) begin
            r_rst = (($random(seed) & 63) == 0);
            r_en  = (($random(seed) & 7) != 0);
            r_op  = $random(seed);
            r_d   = $random(seed);
            if (r_op < 3)
                case ({$random(seed)} % 3)
                    0:       r_f3 = FUNCT3_SB;
                    1:       r_f3 = FUNCT3_SH;
                    default: r_f3 = FUNCT3_SW;
                endcase
            else if (r_op < 6)
                case ({$random(seed)} % 5)
                    0:       r_f3 = FUNCT3_LB;
                    1:       r_f3 = FUNCT3_LH;
                    2:       r_f3 = FUNCT3_LW;
                    3:       r_f3 = FUNCT3_LBU;
                    default: r_f3 = FUNCT3_LHU;
                endcase
            else
                r_f3 = $random(seed);
            if (($random(seed) & 7) == 0)
                r_addr = $random(seed);
            else begin
                r_addr = 32'h0000_00F0 + {$random(seed)} % 48;
                if ($random(seed) & 1)
                    r_addr = r_addr - r_addr % tam(r_f3);
            end
            ciclo_a("aleatorio", r_rst, r_en, r_op < 3, (r_op >= 3) && (r_op < 6),
                    r_f3, r_addr, r_d);
        end

        // Volcado final por el puerto B contra el modelo
        for (k = 0; k < DMEM_WORDS; k = k + 1)
            leer_b("volcado final, puerto B", k);

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
