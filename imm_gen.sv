module imm_gen (
    input  logic [31:0] instr_i,
    output logic [31:0] imm_o
);
    // The opcode identifies the instruction class and therefore tells this
    // block where the immediate bits are located in the 32-bit instruction.
    // funct3 is needed here only to recognize the shift-immediate variants.
    logic [6:0] opcode;
    logic [2:0] funct3;

    assign opcode = instr_i[6:0];
    assign funct3 = instr_i[14:12];

    // Immediate generation is purely combinational. Whenever instr_i changes,
    // imm_o is reconstructed immediately from the appropriate instruction
    // fields. The output is always 32 bits so it can be used directly by the
    // execute-stage ALU, branch-target logic, or jump-target logic.
    always_comb begin
        case (opcode)
            7'b0010011: begin // I-type ALU immediates
                // SLLI uses funct3=001. SRLI and SRAI use funct3=101.
                // For these instructions, bits [24:20] are a 5-bit shift
                // amount (shamt), while bits [31:25] identify the exact shift
                // operation. Therefore, only shamt is used as the immediate.
                // A 5-bit value represents shifts from 0 through 31, which is
                // the complete shift range required by a 32-bit processor.
                // The 27 leading zeros expand shamt to a 32-bit ALU operand.
                if ((funct3 == 3'b001) || (funct3 == 3'b101)) begin
                    imm_o = {27'h0, instr_i[24:20]};
                end else begin
                    // ADDI, SLTI, SLTIU, XORI, ORI, and ANDI use the complete
                    // 12-bit immediate in instruction bits [31:20]. Bit 31 is
                    // the sign bit. Replicating it 20 times converts the signed
                    // 12-bit value into an equivalent signed 32-bit value.
                    imm_o = {{20{instr_i[31]}}, instr_i[31:20]};
                end
            end

            // Loads calculate an address as rs1 + immediate. JALR calculates
            // its target in the same way. SYSTEM and FENCE also use the I-type
            // field arrangement, so all four classes extract instruction bits
            // [31:20] and sign-extend the resulting 12-bit value to 32 bits.
            7'b0000011, // Loads
            7'b1100111, // JALR
            7'b1110011, // SYSTEM
            7'b0001111: // FENCE/FENCE.I
                imm_o = {{20{instr_i[31]}}, instr_i[31:20]};

            // S-type is used by SB, SH, and SW. A store needs both rs1 (base
            // address) and rs2 (data to store), so no rd field is required.
            // RISC-V reuses the usual rd bit positions [11:7] for imm[4:0],
            // while bits [31:25] hold imm[11:5]. Joining these fields rebuilds
            // the signed 12-bit address offset before sign extension.
            7'b0100011: // S-type
                imm_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};

            // B-type is used by conditional branches. Its signed displacement
            // is scattered across the instruction and must be reordered as:
            //   imm[12]   = instr[31]     (sign bit)
            //   imm[11]   = instr[7]
            //   imm[10:5] = instr[30:25]
            //   imm[4:1]  = instr[11:8]
            //   imm[0]    = 0
            // The final zero is implicit because branch offsets are aligned
            // and therefore always represent an even byte displacement.
            7'b1100011: // B-type
                imm_o = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};

            // LUI and AUIPC use the U-type format. Instruction bits [31:12]
            // already contain the upper 20 bits of the required value. Twelve
            // zeros are appended, which is equivalent to shifting that field
            // left by 12 positions. LUI writes this value directly; AUIPC adds
            // it to the current program counter in the execute stage.
            7'b0110111, // LUI
            7'b0010111: // AUIPC
                imm_o = {instr_i[31:12], 12'h000};

            // JAL uses the J-type format. Reorder the encoded fields as:
            //   imm[20]    = instr[31]    (sign bit)
            //   imm[19:12] = instr[19:12]
            //   imm[11]    = instr[20]
            //   imm[10:1]  = instr[30:21]
            //   imm[0]     = 0
            // The reconstructed signed displacement is added to the current
            // PC to obtain the jump target. Bit 0 is implicit alignment zero.
            7'b1101111: // J-type (JAL)
                imm_o = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};

            // R-type and the current custom security instructions do not need
            // an immediate from this block. Returning zero also gives a known,
            // deterministic value for unsupported or unrecognized opcodes.
            default:
                imm_o = 32'h0;
        endcase
    end
endmodule
