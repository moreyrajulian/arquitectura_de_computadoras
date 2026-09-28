## Instructions Set Architecture

| Instruccion | Description | Type | opcode | f3 | f7 | Operation (C type) |
| --- | --- | --- | --- | --- | --- | --- | 
| add | add | R-type | 0110011 | 000 | 0000000 | rd = rs1 + rs2 |
| sub | substract | R-type | 0110011 | 000 | 0100000 | rd = rs1 - rs2 |
| sll | shfit left logical | R-type | 0110011 | 001 | 0000000 | rd = rs1 << rs2[4:0] |
| sra | shift right arithmetic | R-type | 0110011 | 101 | 0100000 | rd = rs1 >>a rs2[4:0] |
| and | and | R-type | 0110011 | 111 | 0000000 | rd = rs1 & rs2 |
| or | or | R-type | 0110011 | 110 | 0000000 | rd = rs1 | rs2 |
| xor | exclusive or | R-type | 0110011 | 100 | 0000000 | rd = rs1 ^ rs2 |
| slt | set if less than | R-type | 0110011 | 010 | 0000000 | rd = (rs1 < rs2) ? 1 : 0 |
| sltu | set if less than unsigned | R-type | 0110011 | 011 | 0000000 |  rd = (rs1 <u rs2) ? 1 : 0 |
| lb | load byte | I-type | 0000011 | 000 | - | rd = SignExt(MEM[rs1+imm][7:0]) |
| lh | load half | I-type | 0000011 | 001 | - | rd = SignExt(MEM[rs1+imm][15:0]) |
| lw | load word | I-type | 0000011 | 010 | - | rd = MEM[rs1 + SignExt(imm)] |
| lbu | load byte, unsigned | I-type | 0000011 | 100 | - | rd = ZeroExt(MEM[rs1+imm][7:0]) |
| lhu | load half, unsigned | I-type | 0000011 | 101 | - | rd = SignExt(MEM[rs1+imm][15:0]) |
| addi | add immediate | I-type | 0010011 | 000 | - | rd = rs1 + SignExt(imm) |
| andi | and immediate | I-type | 0010011 | 111 | - | rd = rs1 & SignExt(imm) |
| ori | or immediate | I-type | 0010011 | 110 | - | rd = rs1 | SignExt(imm) |
| xori | exclusive or imm. | I-type | 0010011 | 100 | - | rd = rs1 ^ SignExt(imm) |
| slti | set if less than imm. | I-type | 0010011 | 010 | - | rd = (rs1 < SignExt(imm)) ? 1 : 0 |
| sltiu | set if less than imm. unsigned | I-type | 0010011 | 011 | - | rd = (rs1 < ZeroExt(imm)) ? 1 : 0 |
| slli | shfit left log. imm. | I-type | 0010011 | 001 | 0000000 | rd = rs1 << shamt |
| srli | shfit right log. imm. | I-type | 0010011 | 101 | 0000000 |  rd = rs1 >> shamt |
| srai | shift right arith. imm | I-type | 0010011 | 101 | 0100000 | rd = rs1 >>a shamt |
| jalr | jump and link register | I-type | 1100111 | 000 | - | rd = PC + 4; PC = (rs1+imm) & ~1 |
| jal | jump and link | J-type | 1101111 | - | - | rd = PC + 4; PC += imm |
| sb | store byte | S-type | 0100011 | 000 | - | MEM[rs1+imm][7:0] = rs2[7:0] |
| sh | store half | S-type | 0100011 | 001 | - | MEM[rs1+imm][15:0] = rs2[15:0] |
| sw | store word | S-type | 0100011 | 010 | - | MEM[rs1 + SignExt(imm)] = rs2 |
| beq | branch if equal | B-type | 1100011 | 000 | - | if (rs1 == rs2) PC += imm |
| bne | branch if not equal | B-type | 1100011 | 001 | - | if (rs1 != rs2) PC += imm |
| lui | load upper immediate | U-type | 0110111 | - | - | rd = imm << 12 |
| #TBD | halt | - | #TBD | #TBD | #TBD | - |