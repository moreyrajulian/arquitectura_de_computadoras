//======================================================================
// riscv_defs.vh
//
// Codificaciones compartidas del RV32I soportado (docs/spec/isa.md), del
// control de la ALU (docs/spec/pipeline.md §4.5), del formato del
// inmediato (docs/spec/pipeline.md §4.3), de los selectores de
// forwarding (docs/spec/pipeline.md §5.1) y del protocolo de la Debug Unit
// (docs/spec/protocolo_debug.md §2, §3 y §5). Es el único
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
// Si cambia isa.md, pipeline.md §4.3, §4.5 o §5.1, o protocolo_debug.md
// §2, §3 o §5, actualizar este archivo.
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

// imm_sel: formato del inmediato (pipeline.md §4.3). Lo genera control_unit
// y lo usa imm_gen. Donde la tabla de §4.4 dice "x" vale 0 (IMM_I).
localparam [2:0] IMM_I = 3'b000;               // aritméticas con inmediato, loads, jalr
localparam [2:0] IMM_S = 3'b001;               // sb, sh, sw
localparam [2:0] IMM_B = 3'b010;               // beq, bne
localparam [2:0] IMM_U = 3'b011;               // lui
localparam [2:0] IMM_J = 3'b100;               // jal

// fwd_a / fwd_b: valor de rs1 / rs2 que entra a EX (pipeline.md §5.1). Los
// genera la unidad de forwarding (§10.2, I-39) y los usa ex_stage.
localparam [1:0] FWD_ID_EX  = 2'b00;            // lo leído en ID (id_ex_rs*_data)
localparam [1:0] FWD_EX_MEM = 2'b10;            // ex_mem_result
localparam [1:0] FWD_WB     = 2'b01;            // wb_data

// Protocolo de la Debug Unit (protocolo_debug.md). Los usan la FSM de
// protocolo (debug_unit, I-45) y la de ejecución (I-47).
// Inicio de trama (§2)
localparam [7:0] DBG_SOF_REQ = 8'hA5;           // petición, PC -> FPGA
localparam [7:0] DBG_SOF_RSP = 8'h5A;           // respuesta y evento, FPGA -> PC

// CMD (§3)
localparam [7:0] DBG_CMD_INFO           = 8'h01;
localparam [7:0] DBG_CMD_STATUS         = 8'h02;
localparam [7:0] DBG_CMD_LOAD           = 8'h10;
localparam [7:0] DBG_CMD_RESET          = 8'h11;
localparam [7:0] DBG_CMD_RUN            = 8'h20;
localparam [7:0] DBG_CMD_STEP           = 8'h21;
localparam [7:0] DBG_CMD_STOP           = 8'h22;
localparam [7:0] DBG_CMD_READ_REGS      = 8'h30;
localparam [7:0] DBG_CMD_READ_LATCHES   = 8'h31;
localparam [7:0] DBG_CMD_READ_DMEM      = 8'h32;
localparam [7:0] DBG_CMD_READ_DMEM_USED = 8'h33;
localparam [7:0] DBG_CMD_READ_ALL       = 8'h34;
localparam [7:0] DBG_CMD_EVT_HALTED     = 8'hE0;  // solo FPGA -> PC

// STATUS (§5)
localparam [7:0] DBG_OK              = 8'h00;
localparam [7:0] DBG_ERR_UNKNOWN_CMD = 8'h01;
localparam [7:0] DBG_ERR_CHECKSUM    = 8'h02;
localparam [7:0] DBG_ERR_LENGTH      = 8'h03;
localparam [7:0] DBG_ERR_STATE       = 8'h04;
localparam [7:0] DBG_ERR_ADDR        = 8'h05;
localparam [7:0] DBG_ERR_TIMEOUT     = 8'h06;

// Estado de ejecución del core: campo state del bloque de estado (§3.1)
localparam [2:0] DBG_ST_NO_PROG = 3'd0;
localparam [2:0] DBG_ST_READY   = 3'd1;
localparam [2:0] DBG_ST_RUNNING = 3'd2;
localparam [2:0] DBG_ST_PAUSED  = 3'd3;
localparam [2:0] DBG_ST_HALTED  = 3'd4;
