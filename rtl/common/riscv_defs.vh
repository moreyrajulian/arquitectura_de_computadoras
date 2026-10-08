//======================================================================
// riscv_defs.vh
//
// Codificaciones compartidas del RV32I soportado (docs/spec/isa.md) y del
// control de la ALU (docs/spec/pipeline.md §4.5). Es el único
// include de codificaciones de la decisión 010: ningún módulo repite estas
// constantes.
//
// Uso: incluir DENTRO del cuerpo del módulo, después de la lista de puertos:
//     `include "riscv_defs.vh"
//   - Sin guarda de inclusión: son localparam, cada módulo necesita su copia.
//   - Sin `timescale ni `default_nettype: es un fragmento, no un módulo.
//   - Solo codificaciones. Los anchos de los puertos son parameter NB_* de
//     cada módulo, porque un localparam del cuerpo no se ve en la lista de
//     puertos ANSI. Por lo mismo, no declarar un parameter con un nombre de
//     este archivo.
//
// Si cambia isa.md o pipeline.md §4.5, actualizar este archivo.
//======================================================================

// Opcodes (instr[6:0])
localparam [6:0] OPCODE_OP     = 7'b0110011;   // R-type
localparam [6:0] OPCODE_OP_IMM = 7'b0010011;   // I aritmética
localparam [6:0] OPCODE_LOAD   = 7'b0000011;
localparam [6:0] OPCODE_STORE  = 7'b0100011;
localparam [6:0] OPCODE_BRANCH = 7'b1100011;
localparam [6:0] OPCODE_JAL    = 7'b1101111;
localparam [6:0] OPCODE_JALR   = 7'b1100111;
localparam [6:0] OPCODE_LUI    = 7'b0110111;
localparam [6:0] OPCODE_SYSTEM = 7'b1110011;   // solo HALT (decisión 001)

// funct3 (instr[14:12]): operaciones de R-type e I aritmética
localparam [2:0] FUNCT3_ADD_SUB = 3'b000;      // add, sub, addi
localparam [2:0] FUNCT3_SLL     = 3'b001;
localparam [2:0] FUNCT3_SLT     = 3'b010;
localparam [2:0] FUNCT3_SLTU    = 3'b011;
localparam [2:0] FUNCT3_XOR     = 3'b100;
localparam [2:0] FUNCT3_SRL_SRA = 3'b101;      // srl, sra, srli, srai
localparam [2:0] FUNCT3_OR      = 3'b110;
localparam [2:0] FUNCT3_AND     = 3'b111;

// funct3: loads (tamaño y signo, pipeline.md §7.1)
localparam [2:0] FUNCT3_LB  = 3'b000;
localparam [2:0] FUNCT3_LH  = 3'b001;
localparam [2:0] FUNCT3_LW  = 3'b010;
localparam [2:0] FUNCT3_LBU = 3'b100;
localparam [2:0] FUNCT3_LHU = 3'b101;

// funct3: stores
localparam [2:0] FUNCT3_SB = 3'b000;
localparam [2:0] FUNCT3_SH = 3'b001;
localparam [2:0] FUNCT3_SW = 3'b010;

// funct3: saltos
localparam [2:0] FUNCT3_BEQ  = 3'b000;
localparam [2:0] FUNCT3_BNE  = 3'b001;
localparam [2:0] FUNCT3_JALR = 3'b000;

// funct3: HALT (ebreak)
localparam [2:0] FUNCT3_HALT = 3'b000;

// funct7 (instr[31:25])
localparam [6:0] FUNCT7_BASE = 7'b0000000;
localparam [6:0] FUNCT7_ALT  = 7'b0100000;     // sub, sra, srai: instr[30] = 1

// Palabras completas
localparam [31:0] INSTR_HALT = 32'h0010_0073;  // ebreak (decisión 001)
localparam [31:0] INSTR_NOP  = 32'h0000_0013;  // addi x0, x0, 0

// alu_ctrl = {instr[30], funct3} (pipeline.md §4.5)
localparam [3:0] ALU_ADD  = 4'b0000;
localparam [3:0] ALU_SUB  = 4'b1000;
localparam [3:0] ALU_SLL  = 4'b0001;
localparam [3:0] ALU_SLT  = 4'b0010;
localparam [3:0] ALU_SLTU = 4'b0011;
localparam [3:0] ALU_XOR  = 4'b0100;
localparam [3:0] ALU_SRL  = 4'b0101;
localparam [3:0] ALU_SRA  = 4'b1101;
localparam [3:0] ALU_OR   = 4'b0110;
localparam [3:0] ALU_AND  = 4'b0111;

