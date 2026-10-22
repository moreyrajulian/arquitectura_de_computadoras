`timescale 1ns / 1ps

//======================================================================
// alu_tb
//
// Testbench autoverificante de la ALU RV32I (docs/spec/verificacion.md
// §3.1, fila de I-28; pipeline.md §4.5 y §5.2).
//
// Oráculos, los dos escritos aparte del RTL (verificacion.md §2):
//   - Casos dirigidos: el resultado esperado está escrito a mano, no
//     calculado. Cada uno verifica también el modelo.
//   - Modelo propio, sin los operadores que usa el RTL: suma y resta con
//     un sumador de acarreo serie, slt y sltu a partir de esa resta, y
//     desplazamientos armados bit a bit, para que el modelo documente la
//     especificación en vez de repetir el diseño.
// Los códigos de alu_ctrl son literales copiados de §4.5: el testbench
// no incluye riscv_defs.vh, así que también verifica los ALU_* que usa
// la ALU.
//
// Casos:
//   - Las 10 operaciones de §4.5 con 0, 1, -1, máximo, mínimo y patrones
//   - slt contra sltu con operandos negativos, y los casos en que la
//     resta desborda (mínimo contra 1, máximo contra -1)
//   - sra con negativos; desplazamientos de 0, 1 y 31
//   - Solo cuentan los 5 bits bajos de i_b: i_b = 32, 33, 0xFFFF_FFE0, -1
//   - Barrido de shamt de 0 a 31 en sll, srl y sra, con patrones y los
//     bits altos de i_b al azar
//   - Aleatorio con semilla fija sobre las 10 operaciones
//   - o_zero en cada vector: vale 1 si y solo si el resultado es 0
// Los códigos de alu_ctrl que no están en §4.5 no se prueban: su
// resultado no está especificado (decisión 024).
//
// Es combinacional: cada vector se aplica y se comprueba T_STEP después.
//======================================================================

module alu_tb;

    localparam integer NB_DATA     = 32;
    localparam integer NB_ALU_CTRL = 4;
    localparam integer NB_SHAMT    = 5;       // pipeline.md §5.2: solo alu_b[4:0]
    localparam integer T_STEP      = 1;       // ns entre vectores
    localparam integer N_RANDOM    = 10000;   // vectores aleatorios
    localparam integer MAX_TIME    = 100000;  // ns, watchdog
    localparam integer SEED        = 40;      // semilla fija (issue #40)

    // alu_ctrl (pipeline.md §4.5)
    localparam [3:0] SPEC_ALU_ADD  = 4'b0000;
    localparam [3:0] SPEC_ALU_SUB  = 4'b1000;
    localparam [3:0] SPEC_ALU_SLL  = 4'b0001;
    localparam [3:0] SPEC_ALU_SLT  = 4'b0010;
    localparam [3:0] SPEC_ALU_SLTU = 4'b0011;
    localparam [3:0] SPEC_ALU_XOR  = 4'b0100;
    localparam [3:0] SPEC_ALU_SRL  = 4'b0101;
    localparam [3:0] SPEC_ALU_SRA  = 4'b1101;
    localparam [3:0] SPEC_ALU_OR   = 4'b0110;
    localparam [3:0] SPEC_ALU_AND  = 4'b0111;

    // Valores notables
    localparam [NB_DATA-1:0] ZERO    = 32'h0000_0000;
    localparam [NB_DATA-1:0] ONE     = 32'h0000_0001;
    localparam [NB_DATA-1:0] ALL1    = 32'hFFFF_FFFF;   // -1
    localparam [NB_DATA-1:0] MAX_POS = 32'h7FFF_FFFF;
    localparam [NB_DATA-1:0] MIN_NEG = 32'h8000_0000;
    localparam [NB_DATA-1:0] PAT_A   = 32'hAAAA_AAAA;
    localparam [NB_DATA-1:0] PAT_5   = 32'h5555_5555;

    reg  [NB_DATA-1:0]     tb_a;
    reg  [NB_DATA-1:0]     tb_b;
    reg  [NB_ALU_CTRL-1:0] tb_alu_ctrl;
    wire [NB_DATA-1:0]     tb_o_result;
    wire                   tb_o_zero;

    reg  [NB_ALU_CTRL-1:0] op_list [0:9];
    reg  [NB_DATA-1:0]     pat_list [0:5];

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer k;

    reg [NB_DATA-1:0] r;
    reg [NB_DATA-1:0] a_rnd;
    reg [NB_DATA-1:0] b_rnd;

    alu #(
        .NB_DATA     (NB_DATA),
        .NB_ALU_CTRL (NB_ALU_CTRL)
    ) u_dut (
        .i_a        (tb_a),
        .i_b        (tb_b),
        .i_alu_ctrl (tb_alu_ctrl),
        .o_result   (tb_o_result),
        .o_zero     (tb_o_zero)
    );

    //------------------------------------------------------------------
    // Modelo de §4.5 y §5.2, escrito sin los operadores del RTL
    //------------------------------------------------------------------

    // a + b + cin con un sumador de acarreo serie; el bit NB_DATA es el
    // acarreo de salida
    function [NB_DATA:0] sumar;
        input [NB_DATA-1:0] a;
        input [NB_DATA-1:0] b;
        input               cin;
        integer n;
        reg     c;
        begin
            c = cin;
            for (n = 0; n < NB_DATA; n = n + 1) begin
                sumar[n] = a[n] ^ b[n] ^ c;
                c        = (a[n] & b[n]) | (c & (a[n] ^ b[n]));
            end
            sumar[NB_DATA] = c;
        end
    endfunction

    // a - b = a + ~b + 1. Sin signo, a < b si y solo si la resta no da
    // acarreo de salida (hay préstamo)
    function menor_sin_signo;
        input [NB_DATA-1:0] a;
        input [NB_DATA-1:0] b;
        reg   [NB_DATA:0]   d;
        begin
            d               = sumar(a, ~b, 1'b1);
            menor_sin_signo = ~d[NB_DATA];
        end
    endfunction

    // Con signo: si los signos difieren, el menor es el negativo; si son
    // iguales, la resta no desborda y decide su signo
    function menor_con_signo;
        input [NB_DATA-1:0] a;
        input [NB_DATA-1:0] b;
        reg   [NB_DATA:0]   d;
        begin
            d = sumar(a, ~b, 1'b1);
            if (a[NB_DATA-1] != b[NB_DATA-1])
                menor_con_signo = a[NB_DATA-1];
            else
                menor_con_signo = d[NB_DATA-1];
        end
    endfunction

    // El bit n del resultado es el bit n - sh de a, o 0 si no existe
    function [NB_DATA-1:0] desplazar_izq;
        input [NB_DATA-1:0]  a;
        input [NB_SHAMT-1:0] sh;
        integer n;
        begin
            for (n = 0; n < NB_DATA; n = n + 1)
                desplazar_izq[n] = (n >= sh) ? a[n - sh] : 1'b0;
        end
    endfunction

    // El bit n del resultado es el bit n + sh de a; si no existe, el
    // relleno es 0 (lógico) o el signo de a (aritmético)
    function [NB_DATA-1:0] desplazar_der;
        input [NB_DATA-1:0]  a;
        input [NB_SHAMT-1:0] sh;
        input                aritmetico;
        integer n;
        begin
            for (n = 0; n < NB_DATA; n = n + 1)
                desplazar_der[n] = (n + sh < NB_DATA) ? a[n + sh]
                                                      : (aritmetico & a[NB_DATA-1]);
        end
    endfunction

    function [NB_DATA-1:0] modelo;
        input [NB_ALU_CTRL-1:0] ctrl;
        input [NB_DATA-1:0]     a;
        input [NB_DATA-1:0]     b;
        reg   [NB_SHAMT-1:0]    sh;
        reg   [NB_DATA:0]       s;
        begin
            sh = b[NB_SHAMT-1:0];
            case (ctrl)
                SPEC_ALU_ADD:  begin s = sumar(a, b, 1'b0);  modelo = s[NB_DATA-1:0]; end
                SPEC_ALU_SUB:  begin s = sumar(a, ~b, 1'b1); modelo = s[NB_DATA-1:0]; end
                SPEC_ALU_SLL:  modelo = desplazar_izq(a, sh);
                SPEC_ALU_SLT:  modelo = {{(NB_DATA-1){1'b0}}, menor_con_signo(a, b)};
                SPEC_ALU_SLTU: modelo = {{(NB_DATA-1){1'b0}}, menor_sin_signo(a, b)};
                SPEC_ALU_XOR:  modelo = a ^ b;
                SPEC_ALU_SRL:  modelo = desplazar_der(a, sh, 1'b0);
                SPEC_ALU_SRA:  modelo = desplazar_der(a, sh, 1'b1);
                SPEC_ALU_OR:   modelo = a | b;
                SPEC_ALU_AND:  modelo = a & b;
                default:       modelo = {NB_DATA{1'bx}};   // no especificado (decisión 024)
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // Aplica un vector y compara o_result y o_zero, con etiqueta para el log
    //------------------------------------------------------------------
    task comparar;
        input [8*40-1:0]        name;
        input [NB_ALU_CTRL-1:0] ctrl;
        input [NB_DATA-1:0]     a;
        input [NB_DATA-1:0]     b;
        input [NB_DATA-1:0]     esperado;
        reg                     zero_esp;
        begin
            tb_alu_ctrl = ctrl;
            tb_a        = a;
            tb_b        = b;
            #(T_STEP);
            zero_esp = (esperado == {NB_DATA{1'b0}});
            checks   = checks + 1;
            if (tb_o_result !== esperado || tb_o_zero !== zero_esp) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | alu_ctrl=%b a=0x%08h b=0x%08h -> dut=0x%08h zero=%b, esperado=0x%08h zero=%b",
                         $time, name, ctrl, a, b, tb_o_result, tb_o_zero, esperado, zero_esp);
            end
        end
    endtask

    // Caso dirigido: el esperado está escrito a mano. También lo compara
    // con el modelo, que después se usa solo en el barrido y el aleatorio
    task dirigido;
        input [8*40-1:0]        name;
        input [NB_ALU_CTRL-1:0] ctrl;
        input [NB_DATA-1:0]     a;
        input [NB_DATA-1:0]     b;
        input [NB_DATA-1:0]     esperado;
        reg   [NB_DATA-1:0]     m;
        begin
            m = modelo(ctrl, a, b);
            if (m !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR modelo del testbench, %0s | modelo=0x%08h esperado=0x%08h",
                         $time, name, m, esperado);
            end
            comparar(name, ctrl, a, b, esperado);
        end
    endtask

    task contra_modelo;
        input [8*40-1:0]        name;
        input [NB_ALU_CTRL-1:0] ctrl;
        input [NB_DATA-1:0]     a;
        input [NB_DATA-1:0]     b;
        begin
            comparar(name, ctrl, a, b, modelo(ctrl, a, b));
        end
    endtask

    //==================================================================
    // CASOS DIRIGIDOS
    //==================================================================

    // add, addi, loads, stores, jalr, lui: el resultado se queda con los
    // 32 bits bajos, sin acarreo ni desborde
    task casos_suma;
        begin
            dirigido("add 0 + 0",                  SPEC_ALU_ADD, ZERO,         ZERO,         32'h0000_0000);
            dirigido("add 1 + 2",                  SPEC_ALU_ADD, 32'h0000_0001, 32'h0000_0002, 32'h0000_0003);
            dirigido("add con acarreos internos",  SPEC_ALU_ADD, 32'h1234_5678, 32'h0FED_CBA9, 32'h2222_2221);
            dirigido("add max + 1 desborda",       SPEC_ALU_ADD, MAX_POS,      ONE,          32'h8000_0000);
            dirigido("add -1 + 1 acarreo total",   SPEC_ALU_ADD, ALL1,         ONE,          32'h0000_0000);
            dirigido("add -1 + -1",                SPEC_ALU_ADD, ALL1,         ALL1,         32'hFFFF_FFFE);
            dirigido("add min + min",              SPEC_ALU_ADD, MIN_NEG,      MIN_NEG,      32'h0000_0000);
            dirigido("add AA + 55",                SPEC_ALU_ADD, PAT_A,        PAT_5,        32'hFFFF_FFFF);
            dirigido("add 0 + imm de lui",         SPEC_ALU_ADD, ZERO,         32'hFFFF_F000, 32'hFFFF_F000);
            dirigido("add 0x100 + imm -4",         SPEC_ALU_ADD, 32'h0000_0100, 32'hFFFF_FFFC, 32'h0000_00FC);
        end
    endtask

    // sub, beq, bne: zero tiene que mirar los 32 bits
    task casos_resta;
        begin
            dirigido("sub 5 - 3",                  SPEC_ALU_SUB, 32'h0000_0005, 32'h0000_0003, 32'h0000_0002);
            dirigido("sub 3 - 5",                  SPEC_ALU_SUB, 32'h0000_0003, 32'h0000_0005, 32'hFFFF_FFFE);
            dirigido("sub 0 - 1",                  SPEC_ALU_SUB, ZERO,         ONE,          32'hFFFF_FFFF);
            dirigido("sub min - 1 desborda",       SPEC_ALU_SUB, MIN_NEG,      ONE,          32'h7FFF_FFFF);
            dirigido("sub 0 - min",                SPEC_ALU_SUB, ZERO,         MIN_NEG,      32'h8000_0000);
            dirigido("sub max - (-1)",             SPEC_ALU_SUB, MAX_POS,      ALL1,         32'h8000_0000);
            dirigido("sub a - a (beq tomado)",     SPEC_ALU_SUB, 32'hDEAD_BEEF, 32'hDEAD_BEEF, 32'h0000_0000);
            dirigido("sub min - min",              SPEC_ALU_SUB, MIN_NEG,      MIN_NEG,      32'h0000_0000);
            dirigido("sub -1 - (-1)",              SPEC_ALU_SUB, ALL1,         ALL1,         32'h0000_0000);
            dirigido("sub 1 - 0 (zero mira bit 0)", SPEC_ALU_SUB, ONE,          ZERO,         32'h0000_0001);
            dirigido("sub min - 0 (zero mira bit 31)", SPEC_ALU_SUB, MIN_NEG,   ZERO,         32'h8000_0000);
        end
    endtask

    // slt contra sltu con los mismos operandos: difieren cuando los signos
    // difieren. sltiu compara sin signo contra el inmediato ya extendido
    // con signo (pipeline.md §4.3)
    task casos_comparacion;
        begin
            dirigido("slt -1 < 1",                 SPEC_ALU_SLT,  ALL1,        ONE,          32'h0000_0001);
            dirigido("sltu 0xFFFFFFFF < 1",        SPEC_ALU_SLTU, ALL1,        ONE,          32'h0000_0000);
            dirigido("slt 1 < -1",                 SPEC_ALU_SLT,  ONE,         ALL1,         32'h0000_0000);
            dirigido("sltu 1 < 0xFFFFFFFF",        SPEC_ALU_SLTU, ONE,         ALL1,         32'h0000_0001);
            dirigido("slt min < max",              SPEC_ALU_SLT,  MIN_NEG,     MAX_POS,      32'h0000_0001);
            dirigido("sltu 0x80000000 < 0x7FFFFFFF", SPEC_ALU_SLTU, MIN_NEG,   MAX_POS,      32'h0000_0000);
            dirigido("slt max < min",              SPEC_ALU_SLT,  MAX_POS,     MIN_NEG,      32'h0000_0000);
            dirigido("sltu 0x7FFFFFFF < 0x80000000", SPEC_ALU_SLTU, MAX_POS,   MIN_NEG,      32'h0000_0001);
            dirigido("slt -2 < -1",                SPEC_ALU_SLT,  32'hFFFF_FFFE, ALL1,       32'h0000_0001);
            dirigido("sltu 0xFFFFFFFE < 0xFFFFFFFF", SPEC_ALU_SLTU, 32'hFFFF_FFFE, ALL1,     32'h0000_0001);
            dirigido("slt -1 < -2",                SPEC_ALU_SLT,  ALL1,        32'hFFFF_FFFE, 32'h0000_0000);
            dirigido("sltu 0xFFFFFFFF < 0xFFFFFFFE", SPEC_ALU_SLTU, ALL1,      32'hFFFF_FFFE, 32'h0000_0000);
            dirigido("slt 5 < 5",                  SPEC_ALU_SLT,  32'h0000_0005, 32'h0000_0005, 32'h0000_0000);
            dirigido("sltu 5 < 5",                 SPEC_ALU_SLTU, 32'h0000_0005, 32'h0000_0005, 32'h0000_0000);
            dirigido("slt 0 < 1",                  SPEC_ALU_SLT,  ZERO,        ONE,          32'h0000_0001);
            dirigido("sltu 0 < 1",                 SPEC_ALU_SLTU, ZERO,        ONE,          32'h0000_0001);
            // La resta desborda: su signo sola daría la respuesta contraria
            dirigido("slt min < 1 (resta desborda)", SPEC_ALU_SLT, MIN_NEG,    ONE,          32'h0000_0001);
            dirigido("sltu 0x80000000 < 1",        SPEC_ALU_SLTU, MIN_NEG,     ONE,          32'h0000_0000);
            dirigido("slt max < -1 (resta desborda)", SPEC_ALU_SLT, MAX_POS,   ALL1,         32'h0000_0000);
            dirigido("sltu 0x7FFFFFFF < 0xFFFFFFFF", SPEC_ALU_SLTU, MAX_POS,   ALL1,         32'h0000_0001);
            // sltiu x, -1: 1 salvo que x sea 0xFFFF_FFFF
            dirigido("sltiu 0 < imm -1",           SPEC_ALU_SLTU, ZERO,        ALL1,         32'h0000_0001);
            dirigido("sltiu -1 < imm -1",          SPEC_ALU_SLTU, ALL1,        ALL1,         32'h0000_0000);
        end
    endtask

    task casos_logicas;
        begin
            dirigido("and FFFF0000 & 0F0F0F0F",    SPEC_ALU_AND, 32'hFFFF_0000, 32'h0F0F_0F0F, 32'h0F0F_0000);
            dirigido("and AA & 55",                SPEC_ALU_AND, PAT_A,        PAT_5,        32'h0000_0000);
            dirigido("andi con imm -16",           SPEC_ALU_AND, 32'h1234_5678, 32'hFFFF_FFF0, 32'h1234_5670);
            dirigido("and -1 & -1",                SPEC_ALU_AND, ALL1,         ALL1,         32'hFFFF_FFFF);
            dirigido("or AA | 55",                 SPEC_ALU_OR,  PAT_A,        PAT_5,        32'hFFFF_FFFF);
            dirigido("or 0 | 0",                   SPEC_ALU_OR,  ZERO,         ZERO,         32'h0000_0000);
            dirigido("or 12000034 | 00567800",     SPEC_ALU_OR,  32'h1200_0034, 32'h0056_7800, 32'h1256_7834);
            dirigido("xor -1 ^ 12345678",          SPEC_ALU_XOR, ALL1,         32'h1234_5678, 32'hEDCB_A987);
            dirigido("xor a ^ a",                  SPEC_ALU_XOR, 32'hDEAD_BEEF, 32'hDEAD_BEEF, 32'h0000_0000);
            dirigido("xor AA ^ 55",                SPEC_ALU_XOR, PAT_A,        PAT_5,        32'hFFFF_FFFF);
        end
    endtask

    // Desplazamientos de 0, 1 y 31; sra con negativos; solo cuentan los
    // 5 bits bajos de i_b (32 desplaza 0, 33 desplaza 1, -1 desplaza 31)
    task casos_desplazamiento;
        begin
            dirigido("sll 1 << 0",                 SPEC_ALU_SLL, ONE,          ZERO,         32'h0000_0001);
            dirigido("sll 1 << 1",                 SPEC_ALU_SLL, ONE,          ONE,          32'h0000_0002);
            dirigido("sll 1 << 31",                SPEC_ALU_SLL, ONE,          32'h0000_001F, 32'h8000_0000);
            dirigido("sll -1 << 31",               SPEC_ALU_SLL, ALL1,         32'h0000_001F, 32'h8000_0000);
            dirigido("sll 12345678 << 4",          SPEC_ALU_SLL, 32'h1234_5678, 32'h0000_0004, 32'h2345_6780);
            dirigido("sll 1 << b=32 (shamt 0)",    SPEC_ALU_SLL, ONE,          32'h0000_0020, 32'h0000_0001);
            dirigido("sll 1 << b=33 (shamt 1)",    SPEC_ALU_SLL, ONE,          32'h0000_0021, 32'h0000_0002);
            dirigido("sll 1 << b=-1 (shamt 31)",   SPEC_ALU_SLL, ONE,          ALL1,         32'h8000_0000);
            dirigido("sll -1 << b=FFFFFFE0",       SPEC_ALU_SLL, ALL1,         32'hFFFF_FFE0, 32'hFFFF_FFFF);
            dirigido("sll 80000000 << 1",          SPEC_ALU_SLL, MIN_NEG,      ONE,          32'h0000_0000);

            dirigido("srl min >> 0",               SPEC_ALU_SRL, MIN_NEG,      ZERO,         32'h8000_0000);
            dirigido("srl min >> 1 (sin signo)",   SPEC_ALU_SRL, MIN_NEG,      ONE,          32'h4000_0000);
            dirigido("srl min >> 31",              SPEC_ALU_SRL, MIN_NEG,      32'h0000_001F, 32'h0000_0001);
            dirigido("srl -1 >> 31",               SPEC_ALU_SRL, ALL1,         32'h0000_001F, 32'h0000_0001);
            dirigido("srl -1 >> 4",                SPEC_ALU_SRL, ALL1,         32'h0000_0004, 32'h0FFF_FFFF);
            dirigido("srl 1 >> 1",                 SPEC_ALU_SRL, ONE,          ONE,          32'h0000_0000);
            dirigido("srl min >> b=33 (shamt 1)",  SPEC_ALU_SRL, MIN_NEG,      32'h0000_0021, 32'h4000_0000);
            dirigido("srl min >> b=FFFFFFE0",      SPEC_ALU_SRL, MIN_NEG,      32'hFFFF_FFE0, 32'h8000_0000);
            dirigido("srl -1 >> b=-1 (shamt 31)",  SPEC_ALU_SRL, ALL1,         ALL1,         32'h0000_0001);

            dirigido("sra min >>> 0",              SPEC_ALU_SRA, MIN_NEG,      ZERO,         32'h8000_0000);
            dirigido("sra min >>> 1",              SPEC_ALU_SRA, MIN_NEG,      ONE,          32'hC000_0000);
            dirigido("sra min >>> 31",             SPEC_ALU_SRA, MIN_NEG,      32'h0000_001F, 32'hFFFF_FFFF);
            dirigido("sra -8 >>> 1",               SPEC_ALU_SRA, 32'hFFFF_FFF8, ONE,         32'hFFFF_FFFC);
            dirigido("sra -1 >>> 31",              SPEC_ALU_SRA, ALL1,         32'h0000_001F, 32'hFFFF_FFFF);
            dirigido("sra F0000000 >>> 4",         SPEC_ALU_SRA, 32'hF000_0000, 32'h0000_0004, 32'hFF00_0000);
            dirigido("sra max >>> 1",              SPEC_ALU_SRA, MAX_POS,      ONE,          32'h3FFF_FFFF);
            dirigido("sra max >>> 31",             SPEC_ALU_SRA, MAX_POS,      32'h0000_001F, 32'h0000_0000);
            dirigido("sra min >>> b=33 (shamt 1)", SPEC_ALU_SRA, MIN_NEG,      32'h0000_0021, 32'hC000_0000);
            dirigido("sra min >>> b=-1 (shamt 31)", SPEC_ALU_SRA, MIN_NEG,     ALL1,         32'hFFFF_FFFF);
            dirigido("sra -8 >>> b=32 (shamt 0)",  SPEC_ALU_SRA, 32'hFFFF_FFF8, 32'h0000_0020, 32'hFFFF_FFF8);
        end
    endtask

    //==================================================================
    // BARRIDO Y ALEATORIO, CONTRA EL MODELO
    //==================================================================

    // Los 32 shamt en sll, srl y sra, con los bits altos de i_b al azar
    task barrido_shamt;
        begin
            for (k = 0; k < (1 << NB_SHAMT); k = k + 1) begin
                for (i = 0; i < 6; i = i + 1) begin
                    r     = $random(seed);
                    b_rnd = {r[NB_DATA-1:NB_SHAMT], k[NB_SHAMT-1:0]};
                    contra_modelo("barrido sll",  SPEC_ALU_SLL, pat_list[i], b_rnd);
                    contra_modelo("barrido srl",  SPEC_ALU_SRL, pat_list[i], b_rnd);
                    contra_modelo("barrido sra",  SPEC_ALU_SRA, pat_list[i], b_rnd);
                end
            end
        end
    endtask

    task aleatorio;
        begin
            for (i = 0; i < N_RANDOM; i = i + 1) begin
                a_rnd = $random(seed);
                b_rnd = $random(seed);
                // Sesgo: cada tanto un operando notable, o b = a para que
                // sub dé 0 y zero valga 1
                case ({$random(seed)} % 8)
                    0:       a_rnd = MIN_NEG;
                    1:       a_rnd = MAX_POS;
                    2:       b_rnd = MIN_NEG;
                    3:       b_rnd = ALL1;
                    4:       b_rnd = a_rnd;
                    default: ;
                endcase
                contra_modelo("aleatorio", op_list[{$random(seed)} % 10], a_rnd, b_rnd);
            end
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors      = 0;
        checks      = 0;
        seed        = SEED;
        tb_a        = {NB_DATA{1'b0}};
        tb_b        = {NB_DATA{1'b0}};
        tb_alu_ctrl = SPEC_ALU_ADD;

        op_list[0] = SPEC_ALU_ADD;
        op_list[1] = SPEC_ALU_SUB;
        op_list[2] = SPEC_ALU_SLL;
        op_list[3] = SPEC_ALU_SLT;
        op_list[4] = SPEC_ALU_SLTU;
        op_list[5] = SPEC_ALU_XOR;
        op_list[6] = SPEC_ALU_SRL;
        op_list[7] = SPEC_ALU_SRA;
        op_list[8] = SPEC_ALU_OR;
        op_list[9] = SPEC_ALU_AND;

        pat_list[0] = MIN_NEG;
        pat_list[1] = MAX_POS;
        pat_list[2] = ALL1;
        pat_list[3] = ONE;
        pat_list[4] = PAT_A;
        pat_list[5] = 32'h1234_5678;

        casos_suma;
        casos_resta;
        casos_comparacion;
        casos_logicas;
        casos_desplazamiento;
        barrido_shamt;
        aleatorio;

        if (errors == 0)
            $display("TEST PASSED: %0d chequeos, 0 errores", checks);
        else
            $display("TEST FAILED: %0d errores sobre %0d chequeos", errors, checks);
        $finish;
    end

    // Watchdog: si la secuencia no termina, falla en vez de colgarse
    initial begin
        #(MAX_TIME);
        $display("TEST FAILED: timeout de %0d ns", MAX_TIME);
        $finish;
    end

endmodule
