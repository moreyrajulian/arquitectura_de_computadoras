`timescale 1ns / 1ps

//======================================================================
// Testbench autochequeante para la ALU.
//
// Contenido de la suite:
//   - modelo de referencia escrito de forma independiente del RTL: la
//     extension a NB_DATA+1 bits esta hecha a mano, para que el modelo
//     documente la especificacion en vez de repetir el diseno
//   - estimulos aleatorios con semilla fija (reproducible)
//   - casos de borde dirigidos, parametrizados en NB_DATA
//   - barrido exhaustivo de shamt y de los 64 opcodes
//   - barrido exhaustivo de operandos si NB_DATA <= 6
//
// Convencion del bit NB_DATA (debe coincidir con el encabezado de alu.v):
//   ADD, SUB : precision real, el resultado usa los NB_DATA+1 bits
//   SRA      : extension de signo, el bit NB_DATA replica el signo
//   logicas y SRL : el bit NB_DATA vale siempre cero
//
// La suite asume NB_DATA >= 2 (con NB_DATA=1 el RTL ni siquiera elabora,
// porque $clog2(1)=0 deja shamt con rango [-1:0]).
//======================================================================

module alu_check;

    parameter integer NB_DATA = 8;

    localparam integer NB_OP    = 6;
    localparam integer N_TESTS  = 2000;
    localparam integer NB_SHAMT = (NB_DATA > 1) ? $clog2(NB_DATA) : 1;
    localparam integer T_STEP   = 10;   // ns entre vectores

    //------------------------------------------------------------------
    // Opcodes
    //------------------------------------------------------------------
    localparam [NB_OP-1:0] OP_ADD = 6'b100000;
    localparam [NB_OP-1:0] OP_SUB = 6'b100010;
    localparam [NB_OP-1:0] OP_AND = 6'b100100;
    localparam [NB_OP-1:0] OP_OR  = 6'b100101;
    localparam [NB_OP-1:0] OP_XOR = 6'b100110;
    localparam [NB_OP-1:0] OP_NOR = 6'b100111;
    localparam [NB_OP-1:0] OP_SRA = 6'b000011;
    localparam [NB_OP-1:0] OP_SRL = 6'b000010;

    //------------------------------------------------------------------
    // Valores notables, parametrizados. Declarados signed para que %0d
    // los muestre como numeros con signo en los mensajes de error.
    //------------------------------------------------------------------
    localparam signed [NB_DATA-1:0] ZERO    = {NB_DATA{1'b0}};
    localparam signed [NB_DATA-1:0] ALL1    = {NB_DATA{1'b1}};              // -1
    localparam signed [NB_DATA-1:0] ONE     = {{(NB_DATA-1){1'b0}}, 1'b1};  // +1
    localparam signed [NB_DATA-1:0] MAX_POS = {1'b0, {(NB_DATA-1){1'b1}}};  // +2^(N-1)-1
    localparam signed [NB_DATA-1:0] MIN_NEG = {1'b1, {(NB_DATA-1){1'b0}}};  // -2^(N-1)
    localparam signed [NB_DATA-1:0] PAT_A   = {((NB_DATA+1)/2){2'b10}};     // 1010...
    localparam signed [NB_DATA-1:0] PAT_5   = ~PAT_A;                       // 0101...

    localparam [NB_SHAMT-1:0] MAX_SH = {NB_SHAMT{1'b1}};                    // shamt maximo

    //------------------------------------------------------------------
    // Interfaz con el DUT
    //------------------------------------------------------------------
    reg         [NB_DATA-1:0] tb_a;
    reg         [NB_DATA-1:0] tb_b;
    reg         [NB_OP-1:0]   tb_op;
    wire signed [NB_DATA:0]   tb_result;

    reg  [NB_OP-1:0] op_list [0:7];

    integer i, j, k;
    integer errors;
    integer checks;
    integer seed;
    reg     done;

    alu #(
        .NB_DATA (NB_DATA),
        .NB_OP   (NB_OP)
    ) u_alu (
        .i_a      (tb_a),
        .i_b      (tb_b),
        .i_op     (tb_op),
        .o_result (tb_result)
    );

    //------------------------------------------------------------------
    // Modelo de referencia.
    // La extension a NB_DATA+1 bits se construye a mano (ax, bx, au) en
    // vez de dejar que la herramienta la infiera igual que en el RTL.
    // Asi el modelo fija la especificacion y no repite el diseno: si el
    // RTL cambia de signedness por un descuido de contexto, aca no pasa.
    //------------------------------------------------------------------
    function signed [NB_DATA:0] alu_model;
        input signed [NB_DATA-1:0] a;
        input signed [NB_DATA-1:0] b;
        input        [NB_OP-1:0]   op;
        reg signed [NB_DATA:0]  ax, bx;  // operandos extendidos en signo
        reg        [NB_DATA:0]  au;      // operando A extendido en cero
        reg      [NB_SHAMT-1:0] sh;
        begin
            ax = {a[NB_DATA-1], a};
            bx = {b[NB_DATA-1], b};
            au = {1'b0, a};
            sh = b[NB_SHAMT-1:0];        // solo los NB_SHAMT bits bajos de B
            case (op)
                // Precision real: el bit NB_DATA es parte del numero
                OP_ADD : alu_model = ax + bx;
                OP_SUB : alu_model = ax - bx;
                // Resultado nativo de NB_DATA bits, bit NB_DATA en cero
                OP_AND : alu_model = {1'b0, (a & b)};
                OP_OR  : alu_model = {1'b0, (a | b)};
                OP_XOR : alu_model = {1'b0, (a ^ b)};
                OP_NOR : alu_model = {1'b0, ~(a | b)};
                // SRA: el signo se replica hasta el bit NB_DATA.
                // Nada de ternarios con una rama unsigned aca: volverian
                // unsigned toda la expresion y >>> pasaria a ser logico.
                OP_SRA : alu_model = ax >>> sh;
                // SRL: au ya trae el bit NB_DATA en cero y A sin signo
                OP_SRL : alu_model = au >> sh;
                default: alu_model = {(NB_DATA+1){1'b0}};
            endcase
        end
    endfunction

    //------------------------------------------------------------------
    // Chequeo con etiqueta, para que el log diga que caso fallo
    //------------------------------------------------------------------
    task chk;
        input        [8*32-1:0]    name;
        input signed [NB_DATA-1:0] a;
        input signed [NB_DATA-1:0] b;
        input        [NB_OP-1:0]   op;
        reg signed [NB_DATA:0] esperado;
        begin
            tb_a  = a;
            tb_b  = b;
            tb_op = op;
            #(T_STEP);
            esperado = alu_model(a, b, op);
            checks   = checks + 1;
            if (tb_result !== esperado) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s | op=%b a=%0d(0x%0h) b=%0d(0x%0h) -> dut=%0d(0x%0h) esperado=%0d(0x%0h)",
                         $time, name, op, a, a, b, b,
                         tb_result, tb_result, esperado, esperado);
            end
        end
    endtask

    //==================================================================
    // CASOS DE BORDE
    //==================================================================

    // ---- Suma: acarreos y los casos que solo caben en NB_DATA+1 bits.
    //      Aca el bit NB_DATA es precision real. ----
    task borde_add;
        begin
            chk("ADD 0+0",            ZERO,    ZERO,    OP_ADD);
            chk("ADD max+0",          MAX_POS, ZERO,    OP_ADD);
            chk("ADD 0+min",          ZERO,    MIN_NEG, OP_ADD);
            chk("ADD max+1",          MAX_POS, ONE,     OP_ADD);  // desborda NB_DATA bits
            chk("ADD max+max",        MAX_POS, MAX_POS, OP_ADD);  // 2^N-2
            chk("ADD min+min",        MIN_NEG, MIN_NEG, OP_ADD);  // -2^N, borde inferior exacto
            chk("ADD min+(-1)",       MIN_NEG, ALL1,    OP_ADD);
            chk("ADD max+min",        MAX_POS, MIN_NEG, OP_ADD);  // -1
            chk("ADD (-1)+1",         ALL1,    ONE,     OP_ADD);  // acarreo que recorre todo el ancho
            chk("ADD (-1)+(-1)",      ALL1,    ALL1,    OP_ADD);
            chk("ADD 55+AA",          PAT_5,   PAT_A,   OP_ADD);  // -1, sin acarreos internos
        end
    endtask

    // ---- Resta: los dos casos que NO caben en NB_DATA bits ----
    task borde_sub;
        begin
            chk("SUB 0-0",            ZERO,    ZERO,    OP_SUB);
            chk("SUB 0-1",            ZERO,    ONE,     OP_SUB);  // -1, prestamo total
            chk("SUB 0-min",          ZERO,    MIN_NEG, OP_SUB);  // +2^(N-1): no cabe en NB_DATA
            chk("SUB max-min",        MAX_POS, MIN_NEG, OP_SUB);  // +2^N-1: tope positivo exacto
            chk("SUB min-max",        MIN_NEG, MAX_POS, OP_SUB);  // -(2^N-1)
            chk("SUB min-1",          MIN_NEG, ONE,     OP_SUB);
            chk("SUB max-(-1)",       MAX_POS, ALL1,    OP_SUB);
            chk("SUB a-a",            PAT_A,   PAT_A,   OP_SUB);  // 0
            chk("SUB min-min",        MIN_NEG, MIN_NEG, OP_SUB);  // 0 con ambos negativos
            chk("SUB (-1)-(-1)",      ALL1,    ALL1,    OP_SUB);
        end
    endtask

    // ---- Logicas: el resultado es de NB_DATA bits y el bit NB_DATA
    //      vale cero SIEMPRE, incluso con los dos operandos negativos.
    //      Por eso AND(-1,-1) da +2^N-1 y no -1: los casos de abajo son
    //      los que fijan esa convencion. ----
    task borde_logic;
        begin
            chk("AND ones&ones",      ALL1,    ALL1,    OP_AND);  // +2^N-1, bit N en cero
            chk("AND max&min",        MAX_POS, MIN_NEG, OP_AND);  // 0
            chk("AND AA&55",          PAT_A,   PAT_5,   OP_AND);  // 0
            chk("AND AA&ones",        PAT_A,   ALL1,    OP_AND);  // identidad
            chk("AND a&0",            PAT_A,   ZERO,    OP_AND);

            chk("OR 0|0",             ZERO,    ZERO,    OP_OR);
            chk("OR max|min",         MAX_POS, MIN_NEG, OP_OR);   // +2^N-1
            chk("OR AA|55",           PAT_A,   PAT_5,   OP_OR);   // +2^N-1
            chk("OR a|0",             PAT_A,   ZERO,    OP_OR);   // identidad
            chk("OR min|min",         MIN_NEG, MIN_NEG, OP_OR);   // bit N en cero pese al signo

            chk("XOR a^a",            PAT_A,   PAT_A,   OP_XOR);  // 0
            chk("XOR min^min",        MIN_NEG, MIN_NEG, OP_XOR);  // 0 con ambos negativos
            chk("XOR a^ones",         PAT_A,   ALL1,    OP_XOR);  // complemento a 1
            chk("XOR max^min",        MAX_POS, MIN_NEG, OP_XOR);  // +2^N-1
            chk("XOR a^0",            PAT_A,   ZERO,    OP_XOR);  // identidad

            chk("NOR 0,0",            ZERO,    ZERO,    OP_NOR);  // +2^N-1, bit N en cero
            chk("NOR ones,ones",      ALL1,    ALL1,    OP_NOR);  // 0
            chk("NOR max,min",        MAX_POS, MIN_NEG, OP_NOR);  // 0
            chk("NOR AA,55",          PAT_A,   PAT_5,   OP_NOR);  // 0
            chk("NOR 0,min",          ZERO,    MIN_NEG, OP_NOR);
            chk("NOR 0,max",          ZERO,    MAX_POS, OP_NOR);  // queda solo el bit N-1
        end
    endtask

    // ---- Desplazamientos. Un shamt mayor o igual al ancho no es un
    //      error: significa que se cayeron todos los bits originales y
    //      queda solo el relleno (0 en SRL, el signo en SRA). ----
    task borde_shift;
        begin
            // SRA: replica el signo, nunca cambia de signo
            chk("SRA min>>>0",        MIN_NEG, ZERO,    OP_SRA);  // shamt=0: pasa igual
            chk("SRA min>>>1",        MIN_NEG, ONE,     OP_SRA);
            chk("SRA min>>>max",      MIN_NEG, MAX_SH,  OP_SRA);
            chk("SRA -1>>>max",       ALL1,    MAX_SH,  OP_SRA);  // -1 se mantiene
            chk("SRA max>>>1",        MAX_POS, ONE,     OP_SRA);
            chk("SRA max>>>max",      MAX_POS, MAX_SH,  OP_SRA);
            chk("SRA 1>>>1",          ONE,     ONE,     OP_SRA);  // 0
            chk("SRA 0>>>max",        ZERO,    MAX_SH,  OP_SRA);

            // SRL: A se toma sin signo, el resultado SIEMPRE es positivo
            chk("SRL min>>0",         MIN_NEG, ZERO,    OP_SRL);  // +2^(N-1), no -2^(N-1)
            chk("SRL min>>1",         MIN_NEG, ONE,     OP_SRL);
            chk("SRL ones>>0",        ALL1,    ZERO,    OP_SRL);  // +2^N-1, no -1
            chk("SRL ones>>1",        ALL1,    ONE,     OP_SRL);
            chk("SRL ones>>max",      ALL1,    MAX_SH,  OP_SRL);
            chk("SRL max>>1",         MAX_POS, ONE,     OP_SRL);
            chk("SRL 1>>1",           ONE,     ONE,     OP_SRL);  // 0
            chk("SRL 0>>max",         ZERO,    MAX_SH,  OP_SRL);

            // Solo se usan los NB_SHAMT bits bajos de B: con NB_DATA
            // potencia de dos, b=NB_DATA tiene que actuar como shamt=0.
            chk("SRA alias b=NB_DATA", MIN_NEG, NB_DATA[NB_DATA-1:0], OP_SRA);
            chk("SRL alias b=NB_DATA", MIN_NEG, NB_DATA[NB_DATA-1:0], OP_SRL);
            chk("SRA alias b=-1",      MIN_NEG, ALL1,                 OP_SRA);
            chk("SRL alias b=-1",      ALL1,    ALL1,                 OP_SRL);

            // Barrido exhaustivo de todos los shamt codificables. Con
            // NB_DATA no potencia de dos esto incluye los shamt mayores
            // que NB_DATA-1, que es donde SRA debe dar -1 y SRL cero.
            for (k = 0; k < (1 << NB_SHAMT); k = k + 1) begin
                chk("SRA barrido shamt", MIN_NEG, k[NB_DATA-1:0], OP_SRA);
                chk("SRA barrido shamt", MAX_POS, k[NB_DATA-1:0], OP_SRA);
                chk("SRA barrido shamt", ALL1,    k[NB_DATA-1:0], OP_SRA);
                chk("SRA barrido shamt", PAT_A,   k[NB_DATA-1:0], OP_SRA);
                chk("SRL barrido shamt", MIN_NEG, k[NB_DATA-1:0], OP_SRL);
                chk("SRL barrido shamt", MAX_POS, k[NB_DATA-1:0], OP_SRL);
                chk("SRL barrido shamt", ALL1,    k[NB_DATA-1:0], OP_SRL);
                chk("SRL barrido shamt", PAT_A,   k[NB_DATA-1:0], OP_SRL);
            end
        end
    endtask

    // ---- Decodificacion: los 64 opcodes posibles, para asegurar que
    //      ninguno invalido activa una operacion por accidente ----
    task borde_opcode;
        begin
            for (k = 0; k < (1 << NB_OP); k = k + 1) begin
                chk("barrido opcode", PAT_A,   PAT_5,   k[NB_OP-1:0]);
                chk("barrido opcode", MIN_NEG, ONE,     k[NB_OP-1:0]);
            end
            // Vecinos a un bit de distancia de un opcode valido
            chk("op 100001 (~ADD)",  MAX_POS, ONE, 6'b100001);
            chk("op 100011 (~SUB)",  MAX_POS, ONE, 6'b100011);
            chk("op 000001 (~SRL)",  MIN_NEG, ONE, 6'b000001);
            chk("op 000111 (~SRA)",  MIN_NEG, ONE, 6'b000111);
            chk("op 000000",         MAX_POS, ONE, 6'b000000);
            chk("op 111111",         MAX_POS, ONE, 6'b111111);
        end
    endtask

    // ---- Barrido total para anchos chicos: prueba por fuerza bruta.
    //      Correr al menos una vez con -PNB_DATA=4 y =6. ----
    task barrido_exhaustivo;
        begin
            if (NB_DATA <= 6)
                for (i = 0; i < (1 << NB_DATA); i = i + 1)
                    for (j = 0; j < (1 << NB_DATA); j = j + 1)
                        for (k = 0; k < 8; k = k + 1)
                            chk("exhaustivo", i[NB_DATA-1:0], j[NB_DATA-1:0], op_list[k]);
        end
    endtask

    // ---- Aleatorio con semilla fija ----
    task aleatorio;
        begin
            for (i = 0; i < N_TESTS; i = i + 1) begin
                tb_a = $random(seed);
                tb_b = $random(seed);
                // 1 de cada 10 vectores usa un opcode cualquiera, para
                // ejercitar tambien el camino default del case
                if (({$random(seed)} % 10) == 0)
                    tb_op = $random(seed);
                else
                    tb_op = op_list[{$random(seed)} % 8];
                // sesgo: cada tanto forzar un operando notable
                case ({$random(seed)} % 8)
                    0: tb_a = MIN_NEG;
                    1: tb_a = MAX_POS;
                    2: tb_b = MIN_NEG;
                    3: tb_b = ALL1;
                    default: ;
                endcase
                chk("aleatorio", tb_a, tb_b, tb_op);
            end
        end
    endtask

    //==================================================================
    // Secuencia
    //==================================================================
    initial begin
        done   = 1'b0;
        errors = 0;
        checks = 0;
        seed   = 32'hC0FFEE;

        op_list[0] = OP_ADD;
        op_list[1] = OP_SUB;
        op_list[2] = OP_AND;
        op_list[3] = OP_OR;
        op_list[4] = OP_XOR;
        op_list[5] = OP_NOR;
        op_list[6] = OP_SRA;
        op_list[7] = OP_SRL;

        aleatorio;
        borde_add;
        borde_sub;
        borde_logic;
        borde_shift;
        borde_opcode;
        barrido_exhaustivo;

        $display("  NB_DATA=%0d: %0d chequeos, %0d errores", NB_DATA, checks, errors);
        done = 1'b1;
    end

endmodule


//======================================================================
// Top para un solo ancho
//======================================================================
module alu_tb;

    parameter integer NB_DATA = 8;

    alu_check #(.NB_DATA(NB_DATA)) u_chk ();

    initial begin
        $dumpfile("alu_tb.vcd");
        $dumpvars(0, alu_tb);
        $display("INFO: NB_DATA=%0d NB_SHAMT=%0d MAX_POS=%0d MIN_NEG=%0d",
                 NB_DATA, u_chk.NB_SHAMT, u_chk.MAX_POS, u_chk.MIN_NEG);
        wait (u_chk.done);
        if (u_chk.errors == 0)
            $display("TEST PASSED: %0d chequeos, 0 errores", u_chk.checks);
        else
            $display("TEST FAILED: %0d errores sobre %0d chequeos", u_chk.errors, u_chk.checks);
        $finish;
    end

endmodule
