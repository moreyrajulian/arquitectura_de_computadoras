`timescale 1ns / 1ps

//======================================================================
// wb_stage_tb
//
// Testbench autoverificante de wb_stage (docs/spec/verificacion.md §3.1,
// pipeline.md §7).
//
// Casos:
//   - Extensión de lb, lbu, lh, lhu y lw con valores escritos a mano:
//     bit de signo en 0 y en 1, en cada posición del byte (offset 0..3);
//     lh/lhu ignoran offset[0] y lw ignora offset (decisión 015)
//   - Barrido de los 5 loads x 4 offsets x varias palabras contra un
//     modelo de §7.1 que elige el byte con un case (no desplaza)
//   - mem_to_reg = 0 entrega result aunque read_data cambie; mem_to_reg
//     = 1 entrega el load aunque result cambie
//   - wb_reg_write y wb_rd son copia de MEM/WB (reg_write = 0 no
//     escribe), también en una burbuja
//   - halted: se activa solo con enable & valid & halt; una burbuja con
//     halt = 1, valid sin halt o enable = 0 no lo activan; no baja hasta
//     el reset; el reset gana sobre enable y sobre la condición
//   - imem_fault: pc = 0x1000, pc con bits altos, pc[1] y pc[0] en 1 lo
//     levantan; 0x0FFC y otros pc alineados en rango no; una burbuja o
//     enable = 0 no lo levantan; persiste; el reset lo borra
//   - halted e imem_fault son independientes (un HALT con pc fuera de
//     rango levanta los dos)
//   - Estímulo aleatorio con semilla fija contra el modelo
//
// Las salidas wb_* son combinacionales: se comprueban #1 después de
// poner las entradas, antes del flanco. halted e imem_fault se
// comprueban en el flanco de bajada siguiente, después de un flanco de
// subida.
//======================================================================

module wb_stage_tb;

    localparam integer NB_PC      = 32;
    localparam integer NB_DATA    = 32;
    localparam integer NB_ADDR    = 5;
    localparam integer NB_FUNCT3  = 3;
    localparam integer T_CLK      = 10;     // ns, 100 MHz como la Basys 3
    localparam integer N_RANDOM   = 2000;   // ciclos de estímulo aleatorio
    localparam integer MAX_CYCLES = 5000;   // watchdog
    localparam integer SEED       = 47;     // semilla fija (issue #47)
    localparam integer IMEM_BYTES = 4096;   // 1024 palabras (memoria.md §1)

    `include "riscv_defs.vh"

    reg                  tb_clk;
    reg                  tb_rst;
    reg                  tb_enable;

    reg                  tb_valid;
    reg  [NB_PC-1:0]     tb_pc;
    reg  [NB_DATA-1:0]   tb_result;
    reg  [NB_DATA-1:0]   tb_read_data;
    reg  [NB_ADDR-1:0]   tb_rd;
    reg  [NB_FUNCT3-1:0] tb_funct3;
    reg  [1:0]           tb_offset;
    reg                  tb_reg_write;
    reg                  tb_mem_to_reg;
    reg                  tb_halt;

    wire                 tb_o_wb_reg_write;
    wire [NB_ADDR-1:0]   tb_o_wb_rd;
    wire [NB_DATA-1:0]   tb_o_wb_data;
    wire                 tb_o_halted;
    wire                 tb_o_imem_fault;

    integer errors;
    integer checks;
    integer seed;
    integer i;
    integer j;
    integer k;

    // Estado esperado de los dos flip-flops
    reg modelo_halted;
    reg modelo_imem_fault;

    reg [NB_FUNCT3-1:0] loads [0:4];
    reg [NB_DATA-1:0]   palabras [0:5];

    wb_stage #(
        .NB_PC     (NB_PC),
        .NB_DATA   (NB_DATA),
        .NB_ADDR   (NB_ADDR),
        .NB_FUNCT3 (NB_FUNCT3)
    ) u_dut (
        .i_clk               (tb_clk),
        .i_rst               (tb_rst),
        .i_enable            (tb_enable),
        .i_mem_wb_valid      (tb_valid),
        .i_mem_wb_pc         (tb_pc),
        .i_mem_wb_result     (tb_result),
        .i_mem_wb_read_data  (tb_read_data),
        .i_mem_wb_rd         (tb_rd),
        .i_mem_wb_funct3     (tb_funct3),
        .i_mem_wb_offset     (tb_offset),
        .i_mem_wb_reg_write  (tb_reg_write),
        .i_mem_wb_mem_to_reg (tb_mem_to_reg),
        .i_mem_wb_halt       (tb_halt),
        .o_wb_reg_write      (tb_o_wb_reg_write),
        .o_wb_rd             (tb_o_wb_rd),
        .o_wb_data           (tb_o_wb_data),
        .o_halted            (tb_o_halted),
        .o_imem_fault        (tb_o_imem_fault)
    );

    initial tb_clk = 1'b0;
    always #(T_CLK/2) tb_clk = ~tb_clk;

    //------------------------------------------------------------------
    // Modelo de §7.1, escrito a partir de la tabla: elige el byte o la
    // media palabra con un case sobre offset, sin desplazar como el RTL
    //------------------------------------------------------------------
    function [NB_DATA-1:0] modelo_load;
        input [NB_DATA-1:0]   w;
        input [NB_FUNCT3-1:0] f3;
        input [1:0]           off;
        reg   [7:0]           b;
        reg   [15:0]          h;
        begin
            case (off)
                2'd0:    b = w[7:0];
                2'd1:    b = w[15:8];
                2'd2:    b = w[23:16];
                default: b = w[31:24];
            endcase
            h = off[1] ? w[31:16] : w[15:0];
            case (f3)
                FUNCT3_LB:  modelo_load = {{24{b[7]}}, b};
                FUNCT3_LH:  modelo_load = {{16{h[15]}}, h};
                FUNCT3_LBU: modelo_load = {24'd0, b};
                FUNCT3_LHU: modelo_load = {16'd0, h};
                default:    modelo_load = w;                // lw
            endcase
        end
    endfunction

    function [NB_DATA-1:0] modelo_wb_data;
        input dummy;
        begin
            modelo_wb_data = tb_mem_to_reg ? modelo_load(tb_read_data, tb_funct3, tb_offset)
                                           : tb_result;
        end
    endfunction

    // memoria.md §6.2: instrucción válida con pc fuera de rango o desalineado
    function pc_con_falla;
        input [NB_PC-1:0] pc;
        begin
            pc_con_falla = (pc >= IMEM_BYTES) || (pc[1:0] != 2'b00);
        end
    endfunction

    //------------------------------------------------------------------
    // Chequeo con etiqueta, para que el log diga qué caso falló
    //------------------------------------------------------------------
    task chk;
        input [8*44-1:0]    name;
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

    // Salidas combinacionales contra el modelo, con las entradas actuales
    task chk_wb;
        input [8*44-1:0] name;
        begin
            #1;
            chk(name, tb_o_wb_data, modelo_wb_data(0));
            chk(name, {{(NB_DATA-1){1'b0}}, tb_o_wb_reg_write},
                      {{(NB_DATA-1){1'b0}}, tb_reg_write});
            chk(name, {{(NB_DATA-NB_ADDR){1'b0}}, tb_o_wb_rd},
                      {{(NB_DATA-NB_ADDR){1'b0}}, tb_rd});
        end
    endtask

    // halted e imem_fault contra el modelo
    task chk_regs;
        input [8*44-1:0] name;
        begin
            chk(name, {{(NB_DATA-1){1'b0}}, tb_o_halted},
                      {{(NB_DATA-1){1'b0}}, modelo_halted});
            chk(name, {{(NB_DATA-1){1'b0}}, tb_o_imem_fault},
                      {{(NB_DATA-1){1'b0}}, modelo_imem_fault});
        end
    endtask

    // Un load con mem_to_reg = 1 y su valor esperado escrito a mano
    task chk_load;
        input [8*44-1:0]      name;
        input [NB_DATA-1:0]   w;
        input [NB_FUNCT3-1:0] f3;
        input [1:0]           off;
        input [NB_DATA-1:0]   esperado;
        begin
            tb_read_data  = w;
            tb_funct3     = f3;
            tb_offset     = off;
            tb_mem_to_reg = 1'b1;
            tb_result     = ~esperado;      // no se tiene que elegir
            #1;
            chk(name, tb_o_wb_data, esperado);
            if (tb_o_wb_data !== esperado)
                $display("        funct3 = %b, offset = %0d", f3, off);
        end
    endtask

    // Un ciclo: aplica rst y enable con las entradas actuales, comprueba
    // las salidas combinacionales, actualiza el modelo y, después del
    // flanco, comprueba los dos flip-flops
    task ciclo;
        input [8*44-1:0] name;
        input            rst;
        input            en;
        begin
            tb_rst    = rst;
            tb_enable = en;
            chk_wb(name);
            if (rst) begin
                modelo_halted     = 1'b0;
                modelo_imem_fault = 1'b0;
            end
            else if (en && tb_valid) begin
                if (tb_halt)
                    modelo_halted = 1'b1;
                if (pc_con_falla(tb_pc))
                    modelo_imem_fault = 1'b1;
            end
            @(negedge tb_clk);
            chk_regs(name);
        end
    endtask

    // Instrucción válida sin halt, en un pc alineado y en rango
    task instr_comun;
        begin
            tb_valid      = 1'b1;
            tb_pc         = 32'h0000_0010;
            tb_result     = 32'h1234_5678;
            tb_read_data  = 32'h9ABC_DEF0;
            tb_rd         = 5'd7;
            tb_funct3     = FUNCT3_LW;
            tb_offset     = 2'd0;
            tb_reg_write  = 1'b1;
            tb_mem_to_reg = 1'b0;
            tb_halt       = 1'b0;
        end
    endtask

    // Burbuja: valid y control en 0 (pipeline.md §2)
    task burbuja;
        begin
            tb_valid      = 1'b0;
            tb_reg_write  = 1'b0;
            tb_mem_to_reg = 1'b0;
            tb_halt       = 1'b0;
        end
    endtask

    //------------------------------------------------------------------
    // Secuencia
    //------------------------------------------------------------------
    initial begin
        errors = 0;
        checks = 0;
        seed   = SEED;
        modelo_halted     = 1'b0;
        modelo_imem_fault = 1'b0;
        tb_rst    = 1'b1;
        tb_enable = 1'b0;
        instr_comun;

        loads[0] = FUNCT3_LB;
        loads[1] = FUNCT3_LH;
        loads[2] = FUNCT3_LW;
        loads[3] = FUNCT3_LBU;
        loads[4] = FUNCT3_LHU;
        palabras[0] = 32'h8070_FF01;
        palabras[1] = 32'h7F80_017F;
        palabras[2] = 32'h0000_0000;
        palabras[3] = 32'hFFFF_FFFF;
        palabras[4] = 32'h8000_8000;
        palabras[5] = 32'h0080_0080;

        // Reset con el core detenido: los dos flip-flops en 0
        @(negedge tb_clk);
        ciclo("reset con enable = 0", 1'b1, 1'b0);
        ciclo("reset con enable = 1", 1'b1, 1'b1);

        //--------------------------------------------------------------
        // Extensión del load (§7.1), valores calculados a mano.
        // 0x8070_FF01: bytes 01, FF, 70, 80 (offset 0..3);
        // medias FF01 (offset 0, 1) y 8070 (offset 2, 3)
        //--------------------------------------------------------------
        chk_load("lb offset 0, signo 0",  32'h8070_FF01, FUNCT3_LB,  2'd0, 32'h0000_0001);
        chk_load("lb offset 1, signo 1",  32'h8070_FF01, FUNCT3_LB,  2'd1, 32'hFFFF_FFFF);
        chk_load("lb offset 2, signo 0",  32'h8070_FF01, FUNCT3_LB,  2'd2, 32'h0000_0070);
        chk_load("lb offset 3, signo 1",  32'h8070_FF01, FUNCT3_LB,  2'd3, 32'hFFFF_FF80);
        chk_load("lbu offset 0",          32'h8070_FF01, FUNCT3_LBU, 2'd0, 32'h0000_0001);
        chk_load("lbu offset 1",          32'h8070_FF01, FUNCT3_LBU, 2'd1, 32'h0000_00FF);
        chk_load("lbu offset 2",          32'h8070_FF01, FUNCT3_LBU, 2'd2, 32'h0000_0070);
        chk_load("lbu offset 3",          32'h8070_FF01, FUNCT3_LBU, 2'd3, 32'h0000_0080);
        chk_load("lh offset 0, signo 1",  32'h8070_FF01, FUNCT3_LH,  2'd0, 32'hFFFF_FF01);
        chk_load("lh offset 2, signo 1",  32'h8070_FF01, FUNCT3_LH,  2'd2, 32'hFFFF_8070);
        chk_load("lh offset 1 = offset 0", 32'h8070_FF01, FUNCT3_LH, 2'd1, 32'hFFFF_FF01);
        chk_load("lh offset 3 = offset 2", 32'h8070_FF01, FUNCT3_LH, 2'd3, 32'hFFFF_8070);
        chk_load("lhu offset 0",          32'h8070_FF01, FUNCT3_LHU, 2'd0, 32'h0000_FF01);
        chk_load("lhu offset 2",          32'h8070_FF01, FUNCT3_LHU, 2'd2, 32'h0000_8070);
        chk_load("lhu offset 1 = offset 0", 32'h8070_FF01, FUNCT3_LHU, 2'd1, 32'h0000_FF01);
        chk_load("lhu offset 3 = offset 2", 32'h8070_FF01, FUNCT3_LHU, 2'd3, 32'h0000_8070);
        // 0x7F80_017F: bytes 7F, 01, 80, 7F; medias 017F y 7F80 (signo 0)
        chk_load("lb offset 0, 7F",       32'h7F80_017F, FUNCT3_LB,  2'd0, 32'h0000_007F);
        chk_load("lb offset 2, 80",       32'h7F80_017F, FUNCT3_LB,  2'd2, 32'hFFFF_FF80);
        chk_load("lb offset 3, 7F",       32'h7F80_017F, FUNCT3_LB,  2'd3, 32'h0000_007F);
        chk_load("lh offset 0, signo 0",  32'h7F80_017F, FUNCT3_LH,  2'd0, 32'h0000_017F);
        chk_load("lh offset 2, signo 0",  32'h7F80_017F, FUNCT3_LH,  2'd2, 32'h0000_7F80);
        chk_load("lhu offset 2, signo 0", 32'h7F80_017F, FUNCT3_LHU, 2'd2, 32'h0000_7F80);
        // lw: la palabra entera con cualquier offset
        for (k = 0; k < 4; k = k + 1) begin
            chk_load("lw ignora offset", 32'h8070_FF01, FUNCT3_LW, k[1:0], 32'h8070_FF01);
            chk_load("lw ignora offset", 32'h7F80_017F, FUNCT3_LW, k[1:0], 32'h7F80_017F);
        end

        // Barrido: 5 loads x 4 offsets x 6 palabras contra el modelo
        for (i = 0; i < 5; i = i + 1)
            for (j = 0; j < 4; j = j + 1)
                for (k = 0; k < 6; k = k + 1)
                    chk_load("barrido de loads", palabras[k], loads[i], j[1:0],
                             modelo_load(palabras[k], loads[i], j[1:0]));

        //--------------------------------------------------------------
        // Mux de write-back (§7.2)
        //--------------------------------------------------------------
        instr_comun;
        tb_mem_to_reg = 1'b0;
        chk_wb("mem_to_reg = 0: result");
        chk("mem_to_reg = 0: result", tb_o_wb_data, 32'h1234_5678);
        tb_read_data = 32'h0BAD_F00D;
        tb_funct3    = FUNCT3_LB;
        chk_wb("mem_to_reg = 0: read_data no importa");
        chk("mem_to_reg = 0: read_data no importa", tb_o_wb_data, 32'h1234_5678);
        tb_mem_to_reg = 1'b1;
        tb_funct3     = FUNCT3_LW;
        chk_wb("mem_to_reg = 1: load");
        chk("mem_to_reg = 1: load", tb_o_wb_data, 32'h0BAD_F00D);
        tb_result = 32'hFFFF_0000;
        chk_wb("mem_to_reg = 1: result no importa");
        chk("mem_to_reg = 1: result no importa", tb_o_wb_data, 32'h0BAD_F00D);

        // wb_reg_write y wb_rd son copia de MEM/WB
        instr_comun;
        for (k = 0; k < 32; k = k + 1) begin
            tb_rd        = k[NB_ADDR-1:0];
            tb_reg_write = k[0];
            chk_wb("rd y reg_write pasan");
        end
        tb_reg_write = 1'b0;
        chk_wb("reg_write = 0 no escribe");
        chk("reg_write = 0 no escribe", {{(NB_DATA-1){1'b0}}, tb_o_wb_reg_write}, 32'd0);
        burbuja;
        chk_wb("burbuja: reg_write en 0");
        chk("burbuja: reg_write en 0", {{(NB_DATA-1){1'b0}}, tb_o_wb_reg_write}, 32'd0);

        //--------------------------------------------------------------
        // Registro halted (§7.3)
        //--------------------------------------------------------------
        // Los chequeos combinacionales avanzan #1 cada uno (con rst = 1,
        // así que los flip-flops siguen en 0): se vuelve al flanco de
        // bajada para que cada ciclo tenga exactamente un flanco de subida
        @(negedge tb_clk);
        burbuja;
        tb_pc = 32'h0000_0020;
        ciclo("burbuja no activa halted", 1'b0, 1'b1);
        tb_halt = 1'b1;                     // halt en una burbuja
        ciclo("burbuja con halt = 1 no activa halted", 1'b0, 1'b1);
        instr_comun;                        // valid sin halt
        ciclo("valid sin halt no activa halted", 1'b0, 1'b1);
        tb_halt      = 1'b1;
        tb_reg_write = 1'b0;
        ciclo("enable = 0 no activa halted", 1'b0, 1'b0);
        ciclo("enable = 0 no activa halted", 1'b0, 1'b0);
        chk("halted sigue en 0", {{(NB_DATA-1){1'b0}}, tb_o_halted}, 32'd0);
        ciclo("HALT en WB activa halted", 1'b0, 1'b1);
        chk("halted en 1", {{(NB_DATA-1){1'b0}}, tb_o_halted}, 32'd1);
        burbuja;
        for (k = 0; k < 3; k = k + 1)
            ciclo("halted no baja", 1'b0, 1'b1);
        ciclo("halted no baja con enable = 0", 1'b0, 1'b0);
        ciclo("reset con enable = 0 borra halted", 1'b1, 1'b0);
        chk("halted en 0 tras reset", {{(NB_DATA-1){1'b0}}, tb_o_halted}, 32'd0);
        // El reset gana sobre la condición de activación
        instr_comun;
        tb_halt = 1'b1;
        ciclo("reset gana sobre valid & halt", 1'b1, 1'b1);
        ciclo("HALT en WB activa halted", 1'b0, 1'b1);
        ciclo("reset con enable = 1 borra halted", 1'b1, 1'b1);

        //--------------------------------------------------------------
        // Aviso imem_fault (memoria.md §6.2)
        //--------------------------------------------------------------
        instr_comun;
        tb_pc = 32'h0000_0FFC;              // última palabra: en rango
        ciclo("pc 0x0FFC no levanta imem_fault", 1'b0, 1'b1);
        tb_pc = 32'h0000_0000;
        ciclo("pc 0x0000 no levanta imem_fault", 1'b0, 1'b1);
        burbuja;
        tb_pc = 32'h0000_1000;
        ciclo("burbuja con pc 0x1000 no levanta", 1'b0, 1'b1);
        instr_comun;
        tb_pc = 32'h0000_1000;
        ciclo("enable = 0 no levanta imem_fault", 1'b0, 1'b0);
        chk("imem_fault sigue en 0", {{(NB_DATA-1){1'b0}}, tb_o_imem_fault}, 32'd0);
        ciclo("pc 0x1000 levanta imem_fault", 1'b0, 1'b1);
        chk("imem_fault en 1", {{(NB_DATA-1){1'b0}}, tb_o_imem_fault}, 32'd1);
        tb_pc = 32'h0000_0010;
        for (k = 0; k < 3; k = k + 1)
            ciclo("imem_fault persiste", 1'b0, 1'b1);
        ciclo("reset borra imem_fault", 1'b1, 1'b0);
        chk("imem_fault en 0 tras reset", {{(NB_DATA-1){1'b0}}, tb_o_imem_fault}, 32'd0);
        // Cada causa por separado, con un reset entre una y otra
        tb_pc = 32'h0000_0002;
        ciclo("pc[1] = 1 levanta imem_fault", 1'b0, 1'b1);
        ciclo("reset borra imem_fault", 1'b1, 1'b1);
        tb_pc = 32'h0000_0001;
        ciclo("pc[0] = 1 levanta imem_fault", 1'b0, 1'b1);
        ciclo("reset borra imem_fault", 1'b1, 1'b1);
        tb_pc = 32'h8000_0000;
        ciclo("pc[31] = 1 levanta imem_fault", 1'b0, 1'b1);
        ciclo("reset borra imem_fault", 1'b1, 1'b1);
        tb_pc = 32'h0000_2004;
        ciclo("pc 0x2004 levanta imem_fault", 1'b0, 1'b1);
        chk("imem_fault no activa halted", {{(NB_DATA-1){1'b0}}, tb_o_halted}, 32'd0);
        ciclo("reset borra imem_fault", 1'b1, 1'b1);
        // Un HALT con pc fuera de rango levanta los dos
        tb_pc   = 32'h0000_1000;
        tb_halt = 1'b1;
        ciclo("HALT con pc 0x1000: los dos", 1'b0, 1'b1);
        ciclo("reset borra los dos", 1'b1, 1'b1);

        //--------------------------------------------------------------
        // Estímulo aleatorio con semilla fija contra el modelo
        //--------------------------------------------------------------
        for (i = 0; i < N_RANDOM; i = i + 1) begin
            tb_valid      = (($random(seed) & 3) != 0);            // valid 3/4
            tb_pc         = (($random(seed) & 7) == 0) ? $random(seed)       // a veces fuera
                                                       : ($random(seed) & 32'h0000_0FFC);
            tb_result     = $random(seed);
            tb_read_data  = $random(seed);
            tb_rd         = $random(seed);
            tb_funct3     = loads[($random(seed) & 32'h7FFF_FFFF) % 5];
            tb_offset     = $random(seed);
            tb_reg_write  = tb_valid & $random(seed);
            tb_mem_to_reg = tb_valid & $random(seed);
            tb_halt       = tb_valid & (($random(seed) & 31) == 0);  // halt 1/32
            ciclo("aleatorio",
                  (($random(seed) & 63) == 0),                         // rst    1/64
                  (($random(seed) & 3)  != 0));                        // enable 3/4
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
