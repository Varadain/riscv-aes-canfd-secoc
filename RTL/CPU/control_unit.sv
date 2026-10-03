// ============================================================
// CONTROL UNIT (RISC-V)
// ============================================================
//
// PURPOSE:
// --------
// This module decodes instruction fields (opcode, funct3, funct7)
// and generates control signals for the entire pipeline.
//
// ============================================================
//
// CONTROL FLOW DIAGRAM:
//
//                Instruction (opcode, funct3, funct7)
//                               │
//                               ▼
//                     ┌──────────────────┐
//                     │   CONTROL UNIT   │
//                     └──────────────────┘
//                               │
//        ┌───────────────┬───────────────┬───────────────┐
//        ▼               ▼               ▼               ▼
//   reg_write       mem_read       mem_write       alu_ctrl
//        │               │               │               │
//        └──────► Controls datapath behavior ◄───────────┘
//
// ------------------------------------------------------------
// SIGNAL MEANING:
//
// reg_write  → write result to register file
// mem_read   → read from data memory
// mem_write  → write to data memory
// mem_to_reg → select memory data for writeback
// alu_src    → choose between register or immediate
// branch     → enable branch logic
// alu_ctrl   → tells ALU which operation to perform
//
// ============================================================

module control_unit (
    input  logic [6:0] opcode_o,   // Instruction opcode (determines type)
    input  logic [2:0] funct3_o,   // Sub-operation selector
    input  logic [6:0] funct7_o,   // Extended operation selector

    // Control outputs
    output logic       reg_write_o,
    output logic       mem_read_o,
    output logic       mem_write_o,
    output logic       mem_to_reg_o,
    output logic       alu_src_o,
    output logic       branch_o,
    output logic [3:0] alu_ctrl_o,
    output logic       custom_instr_o
);

    // ========================================================
    // ALU OPERATION ENCODING
    // Each value corresponds to a specific ALU operation
    // ========================================================
    localparam logic [3:0] ALU_ADD   = 4'h0; // Addition
    localparam logic [3:0] ALU_SUB   = 4'h1; // Subtraction
    localparam logic [3:0] ALU_AND   = 4'h2; // Bitwise AND
    localparam logic [3:0] ALU_OR    = 4'h3; // Bitwise OR
    localparam logic [3:0] ALU_XOR   = 4'h4; // Bitwise XOR
    localparam logic [3:0] ALU_SLL   = 4'h5; // Shift Left Logical
    localparam logic [3:0] ALU_SLT   = 4'h6; // Signed Compare
    localparam logic [3:0] ALU_SLTU  = 4'h7; // Unsigned Compare
    localparam logic [3:0] ALU_SRL   = 4'h8; // Shift Right Logical
    localparam logic [3:0] ALU_SRA   = 4'h9; // Shift Right Arithmetic
    localparam logic [3:0] ALU_LUI   = 4'hA; // Load Upper Immediate
    localparam logic [3:0] ALU_AUIPC = 4'hB; // PC + Immediate
    localparam logic [3:0] ALU_BNE   = 4'hC; // Branch Not Equal / Load tag reuse
    localparam logic [3:0] ALU_BLT   = 4'hD; // Branch Less Than / Load tag reuse
    localparam logic [3:0] ALU_BGE   = 4'hE; // Branch Greater Equal / Load tag reuse
    localparam logic [3:0] ALU_LINK  = 4'hF; // Used for JAL/JALR (PC+4)

    // ========================================================
    // MAIN CONTROL LOGIC
    // Combinational logic: output depends only on inputs
    // ========================================================
    always_comb begin

        // ----------------------------------------------------
        // DEFAULT VALUES (Safe fallback)
        // ----------------------------------------------------
        reg_write_o  = 1'b0;
        mem_read_o   = 1'b0;
        mem_write_o  = 1'b0;
        mem_to_reg_o = 1'b0;
        alu_src_o    = 1'b0;
        branch_o     = 1'b0;
        alu_ctrl_o   = ALU_ADD;
        custom_instr_o = 1'b0;

        // ====================================================
        // OPCODE DECODING
        // ====================================================
        case (opcode_o)

            // ------------------------------------------------
            // R-TYPE (Register-Register Operations)
            // Example: ADD, SUB, AND, OR
            // ------------------------------------------------
            7'b0110011: begin
                reg_write_o = 1'b1; // result written to register

                // Combine funct7 + funct3 for precise decode
                case ({funct7_o, funct3_o})
                    10'b0000000_000: alu_ctrl_o = ALU_ADD; // ADD
                    10'b0100000_000: alu_ctrl_o = ALU_SUB; // SUB
                    10'b0000000_001: alu_ctrl_o = ALU_SLL; // Shift left
                    10'b0000000_010: alu_ctrl_o = ALU_SLT; // Signed compare
                    10'b0000000_011: alu_ctrl_o = ALU_SLTU;// Unsigned compare
                    10'b0000000_100: alu_ctrl_o = ALU_XOR; // XOR
                    10'b0000000_101: alu_ctrl_o = ALU_SRL; // Shift right logical
                    10'b0100000_101: alu_ctrl_o = ALU_SRA; // Shift right arithmetic
                    10'b0000000_110: alu_ctrl_o = ALU_OR;  // OR
                    10'b0000000_111: alu_ctrl_o = ALU_AND; // AND
                    default:         alu_ctrl_o = ALU_ADD;
                endcase
            end

            // ------------------------------------------------
            // I-TYPE (Immediate Arithmetic)
            // Example: ADDI, ANDI, ORI
            // ------------------------------------------------
            7'b0010011: begin
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1; // use immediate instead of rs2

                case (funct3_o)
                    3'b000: alu_ctrl_o = ALU_ADD;  // ADDI
                    3'b010: alu_ctrl_o = ALU_SLT;  // SLTI
                    3'b011: alu_ctrl_o = ALU_SLTU; // SLTIU
                    3'b100: alu_ctrl_o = ALU_XOR;  // XORI
                    3'b110: alu_ctrl_o = ALU_OR;   // ORI
                    3'b111: alu_ctrl_o = ALU_AND;  // ANDI
                    3'b001: alu_ctrl_o = ALU_SLL;  // SLLI

                    // Shift right immediate
                    3'b101: alu_ctrl_o = funct7_o[5] ? ALU_SRA : ALU_SRL;

                    default: alu_ctrl_o = ALU_ADD;
                endcase
            end

            // ------------------------------------------------
            // LOAD INSTRUCTIONS
            // Example: LB, LH, LW
            // ------------------------------------------------
            7'b0000011: begin
                reg_write_o  = 1'b1;
                mem_read_o   = 1'b1;
                mem_to_reg_o = 1'b1;
                alu_src_o    = 1'b1; // address = rs1 + imm

                // funct3 used as LOAD TYPE tag
                 case (funct3_o)
                    3'b000: alu_ctrl_o = ALU_BNE;  // LB
                    3'b001: alu_ctrl_o = ALU_BLT;  // LH
                    3'b010: alu_ctrl_o = ALU_ADD;  // LW
                    3'b100: alu_ctrl_o = ALU_BGE;  // LBU
                    3'b101: alu_ctrl_o = ALU_LINK; // LHU
                    default: alu_ctrl_o = ALU_ADD;
                endcase
            end

            // ------------------------------------------------
            // STORE INSTRUCTIONS
            // Example: SB, SH, SW
            // ------------------------------------------------
            7'b0100011: begin
                mem_write_o = 1'b1;
                alu_src_o   = 1'b1;

                 case (funct3_o)
                    3'b000: alu_ctrl_o = ALU_BNE; // SB
                    3'b001: alu_ctrl_o = ALU_BLT; // SH
                    3'b010: alu_ctrl_o = ALU_ADD; // SW
                    default: alu_ctrl_o = ALU_ADD;
                endcase
            end

            // ------------------------------------------------
            // BRANCH INSTRUCTIONS
            // ------------------------------------------------
            7'b1100011: begin
                branch_o = 1'b1;

                 case (funct3_o)
                    3'b000: alu_ctrl_o = ALU_SUB; // BEQ
                    3'b001: alu_ctrl_o = ALU_BNE; // BNE
                    3'b100: alu_ctrl_o = ALU_BLT; // BLT
                    3'b101: alu_ctrl_o = ALU_BGE; // BGE
                    3'b110: alu_ctrl_o = ALU_BLT; // BLTU
                    3'b111: alu_ctrl_o = ALU_BGE; // BGEU
                    default: alu_ctrl_o = ALU_SUB;
                endcase
            end

            // ------------------------------------------------
            // U-TYPE (Immediate upper)
            // ------------------------------------------------
            7'b0110111: begin // LUI
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                alu_ctrl_o  = ALU_LUI;
            end

            7'b0010111: begin // AUIPC
                reg_write_o = 1'b1;
                alu_src_o   = 1'b1;
                alu_ctrl_o  = ALU_AUIPC;
            end

            // ------------------------------------------------
            // JUMP INSTRUCTIONS
            // ------------------------------------------------
            7'b1101111: begin // JAL
                reg_write_o = 1'b1;
                branch_o    = 1'b1;
                alu_ctrl_o  = ALU_LINK;
            end

            7'b1100111: begin // JALR
                reg_write_o = 1'b1;
                branch_o    = 1'b1;
                alu_src_o   = 1'b1;
                alu_ctrl_o  = ALU_LINK;
            end

            // ------------------------------------------------
            // CUSTOM-0 SECURITY INSTRUCTIONS
            // opcode = 0001011, funct3 selects the command.
            // These instructions return data through the WB path, so they
            // behave like a lightweight custom load from the hazard unit's
            // point of view.
            // ------------------------------------------------
            7'b0001011: begin
                custom_instr_o = 1'b1;
                reg_write_o    = 1'b1;
                mem_read_o     = 1'b1;
                mem_to_reg_o   = 1'b1;
                alu_ctrl_o     = ALU_ADD;
            end

            default: begin
                // No operation (NOP)
            end
        endcase
    end



endmodule
