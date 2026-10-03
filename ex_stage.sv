// ============================================================
// EXECUTE (EX) STAGE
// ============================================================
//
// This stage performs:
//  - ALU operations (ADD, SUB, shifts, etc.)
//  - Branch decision (BEQ, BNE, BLT, etc.)
//  - Branch target calculation
//  - Operand forwarding (hazard resolution)
//  - Special operations (LUI, AUIPC, JAL, JALR)
//
// ------------------------------------------------------------
// EX STAGE DATAFLOW (SIMPLIFIED)
//
//        rs1 --------┐
//                    │        ┌────────────┐
//        rs2 ----┐   ├------→ │ FORWARDING │
//                │   │        └─────┬──────┘
//                │   │              │
//                │   │              ↓
//                │   │         ┌────────┐
//                │   └--------→│  ALU   │────→ alu_result
//                │             └────────┘
//                │
//                └→ store data (forwarded)
//
// ------------------------------------------------------------
// FORWARDING PATHS:
//
//   MEM stage ────────────────┐
//                             ↓
//   WB stage ───────────────→ MUX → ALU inputs
//
// Avoids pipeline stalls for data hazards
//
// ------------------------------------------------------------
// BRANCH LOGIC:
//
//   - Compare operands (zero / signed compare)
//   - Compute target:
//       PC + imm        (normal branch)
//       rs1 + imm       (JALR)
//   - Decide branch_taken
//
// ------------------------------------------------------------
// LOAD/STORE SPECIAL HANDLING:
//
//   Some ALU control signals are reused as "tags"
//   to encode load/store type (byte/halfword/unsigned)
//
//   These tags are embedded into upper bits of ALU result
//
// ============================================================

module ex_stage (
    input  logic [31:0] pc_i,             // PC carried in the ID/EX register
    input  logic [31:0] rs1_data_i,       // Register-file value selected by rs1
    input  logic [31:0] rs2_data_i,       // Register-file value selected by rs2
    input  logic [31:0] imm_i,            // 32-bit immediate generated in ID
    input  logic        alu_src_i,        // 0: operand B=rs2, 1: operand B=imm
    input  logic        branch_i,         // 1 for branch, JAL, or JALR
    input  logic [3:0]  alu_ctrl_i,       // Exact arithmetic/control operation
    input  logic        custom_instr_i,   // 1 for a custom-0 security command
    input  logic [1:0]  forward_a_i,      // Select newest available rs1 value
    input  logic [1:0]  forward_b_i,      // Select newest available rs2 value
    input  logic [31:0] mem_alu_result_i, // Result available in EX/MEM pipeline
    input  logic [31:0] wb_data_i,        // Final result available in WB

    output logic [31:0] alu_result_o,     // ALU result, address tag, or custom rs1
    output logic [31:0] rs2_forwarded_o,  // Newest rs2 value sent toward MEM
    output logic [31:0] branch_target_o,  // Candidate next PC for control transfer
    output logic        branch_taken_o    // 1 requests PC redirection and flush
);

    // ========================================================
    // ALU CONTROL DEFINITIONS
    // These values must match control_unit.sv and alu.sv. Values C through F
    // have two uses: branch functions when branch_i=1 and load/store type tags
    // when branch_i=0. is_mem_variant below separates those interpretations.
    // ========================================================
    localparam logic [3:0] ALU_ADD   = 4'h0;
    localparam logic [3:0] ALU_SUB   = 4'h1;
    localparam logic [3:0] ALU_LUI   = 4'hA;
    localparam logic [3:0] ALU_AUIPC = 4'hB;
    localparam logic [3:0] ALU_BNE   = 4'hC;
    localparam logic [3:0] ALU_BLT   = 4'hD;
    localparam logic [3:0] ALU_BGE   = 4'hE;
    localparam logic [3:0] ALU_LINK  = 4'hF;

    // ========================================================
    // INTERNAL SIGNALS
    // ========================================================
    logic [31:0] op_a_raw;       // Newest rs1 value after forwarding
    logic [31:0] op_b_raw;       // Newest rs2 value after forwarding
    logic [31:0] op_a;           // Final ALU A input after special handling
    logic [31:0] op_b;           // Final ALU B input after immediate selection

    logic [3:0]  alu_ctrl_eff;   // Effective ALU control
    logic [31:0] alu_result_raw; // Raw ALU output

    logic [2:0]  ls_tag;         // Width/sign tag carried in result bits [31:29]
    logic        is_mem_variant; // 1 when control value represents a memory type

    logic        zero;           // ALU result equals zero; used by BEQ/BNE
    logic        cmp_lt_signed;  // Signed rs1<rs2 result used by BLT/BGE

    // ========================================================
    // FORWARDING MUXES (DATA HAZARD RESOLUTION)
    // ========================================================
    always_comb begin
        // Forwarding selector convention for both source operands:
        //   2'b00 (and unused values): use value read from register file
        //   2'b10: use newer result from the instruction currently in MEM
        //   2'b01: use final writeback data from the instruction in WB
        // Forwarding changes the data value, not the rs1/rs2 register number.

        // Select the newest available value for source operand rs1.
        case (forward_a_i)
            2'b10: op_a_raw = mem_alu_result_i; // Forward from MEM
            2'b01: op_a_raw = wb_data_i;        // Forward from WB
            default: op_a_raw = rs1_data_i;     // Normal case
        endcase

        // Select the newest available value for source operand rs2.
        case (forward_b_i)
            2'b10: op_b_raw = mem_alu_result_i;
            2'b01: op_b_raw = wb_data_i;
            default: op_b_raw = rs2_data_i;
        endcase
    end

    // ========================================================
    // OPERAND SELECTION + SPECIAL CASE HANDLING
    // ========================================================
    always_comb begin
        op_a = op_a_raw;

        // R-type operations use forwarded rs2. Immediate ALU, load, and store
        // instructions set alu_src_i so that imm_i becomes operand B instead.
        op_b = alu_src_i ? imm_i : op_b_raw;

        // The control unit reuses ALU_BNE/BLT/BGE/LINK to identify byte,
        // halfword, unsigned-byte, and unsigned-halfword memory operations.
        // branch_i must be zero here; otherwise these values describe actual
        // branch or jump operations rather than memory-access variants.
        is_mem_variant = !branch_i && (
            (alu_ctrl_i == ALU_BNE) ||
            (alu_ctrl_i == ALU_BLT) ||
            (alu_ctrl_i == ALU_BGE) ||
            (alu_ctrl_i == ALU_LINK)
        );

        // For memory ops → ALU always does address = base + offset
        // Every load/store requires address = forwarded rs1 + immediate.
        // Force ALU_ADD but preserve alu_ctrl_i separately to create ls_tag.
        alu_ctrl_eff = is_mem_variant ? ALU_ADD : alu_ctrl_i;

        // Special cases for different instructions

        // LUI result is 0 plus the already shifted U-type immediate.
        if (alu_ctrl_i == ALU_LUI) begin
            op_a = 32'h0;
            op_b = imm_i;
        end

        // AUIPC result is this instruction's PC plus its U-type immediate.
        else if (alu_ctrl_i == ALU_AUIPC) begin
            op_a = pc_i;
            op_b = imm_i;
        end

        // JAL/JALR write PC+4 to rd as the return address. Their destination
        // PC is calculated independently by the branch-target block below.
        else if (branch_i && (alu_ctrl_i == ALU_LINK)) begin
            op_a = pc_i;
            op_b = 32'd4;
        end

        // Encode the load/store formatting required later by load_store_unit.
        // Tag 000 is the normal 32-bit word case. Byte and halfword tags also
        // apply to stores; unsigned tags are meaningful for load results.
        ls_tag = 3'b000;
        if (is_mem_variant) begin
            case (alu_ctrl_i)
                ALU_BNE:  ls_tag = 3'b001; // byte
                ALU_BLT:  ls_tag = 3'b010; // half
                ALU_BGE:  ls_tag = 3'b011; // byte unsigned
                ALU_LINK: ls_tag = 3'b100; // half unsigned
                default:  ls_tag = 3'b000;
            endcase
        end
    end

    // A store needs two independent values: the ALU uses rs1+imm to calculate
    // the address, while the newest rs2 value is the data written there. Keep
    // op_b_raw because the ALU's op_b may have been replaced by imm_i.
    assign rs2_forwarded_o = op_b_raw;

    // Compare forwarded values rather than potentially stale ID-stage data.
    // $signed makes bit 31 the sign bit for BLT and BGE comparisons.
    assign cmp_lt_signed = ($signed(op_a_raw) < $signed(op_b_raw));

    // ========================================================
    // BRANCH TARGET COMPUTATION
    // ========================================================
    always_comb begin
        if (branch_i && alu_src_i && (alu_ctrl_i == ALU_LINK)) begin
            // JALR target = forwarded rs1 + I-type immediate. Clearing bit 0
            // satisfies the RISC-V rule for an aligned JALR destination.
            branch_target_o = (op_a_raw + imm_i) & 32'hFFFF_FFFE;
        end else begin
            // Conditional branches and JAL use a PC-relative target. This
            // candidate value is ignored when branch_taken_o remains zero.
            branch_target_o = pc_i + imm_i;
        end
    end

    // ========================================================
    // ALU INSTANCE
    // ========================================================
    alu u_alu (
        .a_i(op_a),
        .b_i(op_b),
        .alu_ctrl_i(alu_ctrl_eff),
        .result_o(alu_result_raw),
        .zero_o(zero)
    );

    // ========================================================
    // OUTPUT FORMATTING
    // Select what the EX/MEM alu-result field carries:
    //   normal instruction: raw arithmetic/logic result
    //   memory operation:   type tag plus effective address
    //   custom instruction: forwarded rs1 operand for the MEM command handler
    // ========================================================
    always_comb begin
        if (custom_instr_i) begin
            // AES is not executed directly in EX. For a custom command, EX
            // transports both register operands into MEM. Forwarded rs1 travels
            // through alu_result_o/addr_i; forwarded rs2 travels separately
            // through rs2_forwarded_o/write_data_i. MEM uses custom_cmd_i to
            // perform the requested command or return a security result.
            alu_result_o = op_a_raw;
        end else if (is_mem_variant) begin
            // Preserve 29 address bits and place the load/store tag in [31:29].
            // mem_stage.sv extracts the tag and effective address again.
            alu_result_o = {ls_tag, alu_result_raw[28:0]};
        end else begin
            alu_result_o = alu_result_raw;
        end
    end

    // ========================================================
    // BRANCH DECISION LOGIC
    // ========================================================
    always_comb begin
        branch_taken_o = 1'b0;

        // Non-control instructions retain zero, selecting sequential PC+4.
        // For a branch or jump, alu_ctrl_i identifies the required condition.
        if (branch_i) begin
             case (alu_ctrl_i)
                ALU_SUB:  branch_taken_o = zero;             // BEQ: rs1-rs2 == 0
                ALU_BNE:  branch_taken_o = !zero;            // BNE: rs1-rs2 != 0
                ALU_BLT:  branch_taken_o = cmp_lt_signed;    // BLT: signed rs1<rs2
                ALU_BGE:  branch_taken_o = !cmp_lt_signed;   // BGE: signed rs1>=rs2
                ALU_LINK: branch_taken_o = 1'b1;             // JAL/JALR always jump
                default:  branch_taken_o = 1'b0;
            endcase
        end
    end



endmodule
