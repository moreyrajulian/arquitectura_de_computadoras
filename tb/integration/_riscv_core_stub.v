`timescale 1ns / 1ps
`default_nettype none

//======================================================================
// riscv_core (stub para probar pipeline_tb)
//
// NO es el procesador. Sirve para verificar el banco de pruebas
// incremental antes de que exista el core (I-22), decisión 021. El
// prefijo "_" lo deja fuera del proyecto de Vivado
// (scripts/create_project.tcl): se compila a mano junto con
// pipeline_tb.v (ver verificacion.md §8).
//
// Tiene todos los puertos de la interfaz completa: el banco conecta solo
// los de las etapas integradas y el resto queda flotante.
//
// Comportamiento:
//   - Reproduce la traza del modelo (+DIR, los mismos archivos que lee el
//     banco): en cada ciclo con enable = 1 avanza una línea.
//   - if_id_instr de una instrucción válida sale de la imem que cargó el
//     banco por el puerto B, no de la traza: así también se prueba la carga.
//   - La dmem y el banco de registros son arreglos: el banco los carga, y
//     cuando el HALT llega a WB el stub copia el estado final esperado
//     (exp_*.hex) para probar el modo +FINAL.
//
// Fallas a propósito (plusargs):
//   +STUB_ERROR=<ciclo>  invierte el bit 2 de if_id_pc en ese ciclo
//   +STUB_SIN_HALT       nunca activa halted (prueba el watchdog con +FINAL)
//======================================================================

module riscv_core (
    input  wire        i_clk,
    input  wire        i_rst,
    input  wire        i_enable,
    input  wire        i_imem_b_en,
    input  wire        i_imem_b_we,
    input  wire [9:0]  i_imem_b_addr,
    input  wire [31:0] i_imem_b_din,
    input  wire        i_dmem_b_en,
    input  wire [3:0]  i_dmem_b_we,
    input  wire [9:0]  i_dmem_b_addr,
    input  wire [31:0] i_dmem_b_din,
    output reg  [31:0] o_dmem_b_dout,
    output wire        o_imem_fault,
    output wire        o_dmem_oob,
    output wire        o_dmem_misaligned,
    output wire        o_halted
);

    localparam integer MAX_LINES = 4096;

    reg [64:0]  ref_if_id  [0:MAX_LINES-1];
    reg [160:0] ref_id_ex  [0:MAX_LINES-1];
    reg [108:0] ref_ex_mem [0:MAX_LINES-1];
    reg [109:0] ref_mem_wb [0:MAX_LINES-1];
    reg [31:0]  corte      [0:5];
    reg [31:0]  exp_misc   [0:3];
    reg [31:0]  imem       [0:1023];
    reg [31:0]  dmem       [0:1023];

    // Mismo camino que el banco usa por defecto (`REGFILE = u_dut.u_regfile.regs)
    regfile_stub u_regfile ();

    reg [8*512-1:0] dir;
    reg [8*600-1:0] fname;
    integer lineas;
    integer error_ciclo;
    reg     sin_halt;
    integer t_reg;                              // línea de la traza (0 = ciclo 1)
    integer b;

    initial begin
        if (!$value$plusargs("DIR=%s", dir)) dir = 0;
        if (!$value$plusargs("STUB_ERROR=%d", error_ciclo)) error_ciclo = 0;
        sin_halt = $test$plusargs("STUB_SIN_HALT");
        $sformat(fname, "%0s/corte.hex", dir);              $readmemh(fname, corte);
        lineas = corte[0];
        $sformat(fname, "%0s/modelo.ciclo.if_id.hex", dir);  $readmemh(fname, ref_if_id,  0, lineas-1);
        $sformat(fname, "%0s/modelo.ciclo.id_ex.hex", dir);  $readmemh(fname, ref_id_ex,  0, lineas-1);
        $sformat(fname, "%0s/modelo.ciclo.ex_mem.hex", dir); $readmemh(fname, ref_ex_mem, 0, lineas-1);
        $sformat(fname, "%0s/modelo.ciclo.mem_wb.hex", dir); $readmemh(fname, ref_mem_wb, 0, lineas-1);
        exp_misc[2] = 0;
    end

    // Avanza una línea por ciclo con enable; el reset vuelve a la primera
    always @(posedge i_clk) begin
        if (i_rst)
            t_reg <= 0;
        else if (i_enable && t_reg < lineas - 1 && !(sin_halt && t_reg == lineas - 2))
            t_reg <= t_reg + 1;
    end

    // Al llegar el HALT a WB, el estado final esperado
    always @(posedge i_clk) begin
        if (!i_rst && i_enable && !sin_halt && t_reg == lineas - 2) begin
            $sformat(fname, "%0s/exp_regs.hex", dir); $readmemh(fname, u_regfile.regs);
            $sformat(fname, "%0s/exp_dmem.hex", dir); $readmemh(fname, dmem);
            $sformat(fname, "%0s/exp_misc.hex", dir); $readmemh(fname, exp_misc);
        end
    end

    // Puertos B
    always @(posedge i_clk)
        if (i_imem_b_en && i_imem_b_we)
            imem[i_imem_b_addr] <= i_imem_b_din;
    always @(posedge i_clk)
        if (i_dmem_b_en === 1'b1) begin
            for (b = 0; b < 4; b = b + 1)
                if (i_dmem_b_we[b])
                    dmem[i_dmem_b_addr][8*b +: 8] <= i_dmem_b_din[8*b +: 8];
            o_dmem_b_dout <= dmem[i_dmem_b_addr];
        end

    assign o_halted = !sin_halt && (t_reg == lineas - 1);
    assign o_imem_fault      = o_halted & exp_misc[2][2];
    assign o_dmem_oob        = o_halted & exp_misc[2][1];
    assign o_dmem_misaligned = o_halted & exp_misc[2][0];

    //------------------------------------------------------------------
    // Campos de los latches, con los nombres que lee el banco
    //------------------------------------------------------------------
    wire [64:0]  l_if_id  = ref_if_id[t_reg];
    wire [160:0] l_id_ex  = ref_id_ex[t_reg];
    wire [108:0] l_ex_mem = ref_ex_mem[t_reg];
    wire [109:0] l_mem_wb = ref_mem_wb[t_reg];

    wire        if_id_valid = l_if_id[64];
    wire [31:0] if_id_pc    = l_if_id[63:32] ^ ((t_reg + 1 == error_ciclo) ? 32'h4 : 32'h0);
    wire [31:0] if_id_instr = if_id_valid ? imem[l_if_id[43:34]] : l_if_id[31:0];

    wire        id_ex_valid      = l_id_ex[160];
    wire [31:0] id_ex_pc         = l_id_ex[159:128];
    wire [31:0] id_ex_rs1_data   = l_id_ex[127:96];
    wire [31:0] id_ex_rs2_data   = l_id_ex[95:64];
    wire [31:0] id_ex_imm        = l_id_ex[63:32];
    wire [4:0]  id_ex_rs1        = l_id_ex[31:27];
    wire [4:0]  id_ex_rs2        = l_id_ex[26:22];
    wire [4:0]  id_ex_rd         = l_id_ex[21:17];
    wire [2:0]  id_ex_funct3     = l_id_ex[16:14];
    wire [3:0]  id_ex_alu_ctrl   = l_id_ex[13:10];
    wire        id_ex_alu_src_a  = l_id_ex[9];
    wire        id_ex_alu_src_b  = l_id_ex[8];
    wire        id_ex_branch     = l_id_ex[7];
    wire        id_ex_jal        = l_id_ex[6];
    wire        id_ex_jalr       = l_id_ex[5];
    wire        id_ex_mem_read   = l_id_ex[4];
    wire        id_ex_mem_write  = l_id_ex[3];
    wire        id_ex_reg_write  = l_id_ex[2];
    wire        id_ex_mem_to_reg = l_id_ex[1];
    wire        id_ex_halt       = l_id_ex[0];

    wire        ex_mem_valid      = l_ex_mem[108];
    wire [31:0] ex_mem_pc         = l_ex_mem[107:76];
    wire [31:0] ex_mem_result     = l_ex_mem[75:44];
    wire [31:0] ex_mem_store_data = l_ex_mem[43:12];
    wire [4:0]  ex_mem_rd         = l_ex_mem[11:7];
    wire [2:0]  ex_mem_funct3     = l_ex_mem[6:4];
    wire        ex_mem_mem_write  = l_ex_mem[3];
    wire        ex_mem_reg_write  = l_ex_mem[2];
    wire        ex_mem_mem_to_reg = l_ex_mem[1];
    wire        ex_mem_halt       = l_ex_mem[0];

    wire        mem_wb_valid      = l_mem_wb[109];
    wire [31:0] mem_wb_pc         = l_mem_wb[108:77];
    wire [31:0] mem_wb_result     = l_mem_wb[76:45];
    wire [31:0] mem_wb_read_data  = l_mem_wb[44:13];
    wire [4:0]  mem_wb_rd         = l_mem_wb[12:8];
    wire [2:0]  mem_wb_funct3     = l_mem_wb[7:5];
    wire [1:0]  mem_wb_offset     = l_mem_wb[4:3];
    wire        mem_wb_reg_write  = l_mem_wb[2];
    wire        mem_wb_mem_to_reg = l_mem_wb[1];
    wire        mem_wb_halt       = l_mem_wb[0];

endmodule

// Arreglo de registros que carga y lee el banco por jerarquía
module regfile_stub;
    reg [31:0] regs [0:31];
endmodule

`default_nettype wire
