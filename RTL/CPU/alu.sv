// ============================================================
// ALU (Arithmetic Logic Unit)
// ============================================================
//
// PURPOSE:
// Performs arithmetic, logical, comparison, and shift operations
// based on control signal (alu_ctrl_i)
//
// ============================================================
//
//                ALU ARCHITECTURE (Conceptual)
//
//                +------------------------+
//   a_i -------->|                        |
//                |        ALU CORE        |----> result_o
//   b_i -------->|                        |
//                |                        |
// alu_ctrl_i --->|  Operation Selector    |
//                +------------------------+
//                              |
//                              v
//                          zero_o
//
// ------------------------------------------------------------
// OPERATION FLOW:
//
//   Inputs:
//     a_i → Operand A (usually rs1)
//     b_i → Operand B (rs2 or immediate)
//     alu_ctrl_i → selects operation
//
//   Output:
//     result_o → computed result
//     zero_o   → 1 if result == 0 (used for branches)
//
// ------------------------------------------------------------
// CONTROL ENCODING (alu_ctrl_i):
//
//   0  → ADD    (a + b)
//   1  → SUB    (a - b)
//   2  → AND    (a & b)
//   3  → OR     (a | b)
//   4  → XOR    (a ^ b)
//   5  → SLL    (a << shamt)
//   6  → SLT    (signed compare)
//   7  → SLTU   (unsigned compare)
//   8  → SRL    (logical right shift)
//   9  → SRA    (arithmetic right shift)
//   A  → LUI    (load upper immediate)
//
// ------------------------------------------------------------
// NOTES:
//
// - Shift operations use only lower 5 bits of b_i (RV32 standard)
// - SLT uses signed comparison
// - SLTU uses unsigned comparison
// - zero_o is mainly used for branch decisions (BEQ, BNE)
//
// ============================================================

module alu (
    input  logic [31:0] a_i,         // Operand A (from register file or forwarding)
    input  logic [31:0] b_i,         // Operand B (register or immediate)
    input  logic [3:0]  alu_ctrl_i,  // ALU operation selector

    output logic [31:0] result_o,    // Result of ALU operation
    output logic        zero_o       // Flag: 1 if result is zero
);

    // ========================================================
    // ALU Operation Encoding (matches control_unit)
    // ========================================================
    localparam logic [3:0] ALU_ADD   = 4'h0; // Addition
    localparam logic [3:0] ALU_SUB   = 4'h1; // Subtraction
    localparam logic [3:0] ALU_AND   = 4'h2; // Bitwise AND
    localparam logic [3:0] ALU_OR    = 4'h3; // Bitwise OR
    localparam logic [3:0] ALU_XOR   = 4'h4; // Bitwise XOR
    localparam logic [3:0] ALU_SLL   = 4'h5; // Shift Left Logical
    localparam logic [3:0] ALU_SLT   = 4'h6; // Set Less Than (signed)
    localparam logic [3:0] ALU_SLTU  = 4'h7; // Set Less Than (unsigned)
    localparam logic [3:0] ALU_SRL   = 4'h8; // Shift Right Logical
    localparam logic [3:0] ALU_SRA   = 4'h9; // Shift Right Arithmetic
    localparam logic [3:0] ALU_LUI   = 4'hA; // Load Upper Immediate

    // ========================================================
    // COMBINATIONAL ALU LOGIC
    // Executes operation based on alu_ctrl_i
    // ========================================================
    always_comb begin
        case (alu_ctrl_i)

            // Arithmetic operations
            ALU_ADD:  result_o = a_i + b_i;   // Addition
            ALU_SUB:  result_o = a_i - b_i;   // Subtraction

            // Logical operations
            ALU_AND:  result_o = a_i & b_i;   // Bitwise AND
            ALU_OR:   result_o = a_i | b_i;   // Bitwise OR
            ALU_XOR:  result_o = a_i ^ b_i;   // Bitwise XOR

            // Shift operations (use only lower 5 bits for shift amount)
            ALU_SLL:  result_o = a_i << b_i[4:0];  // Logical left shift
            ALU_SRL:  result_o = a_i >> b_i[4:0];  // Logical right shift
            ALU_SRA:  result_o = $signed(a_i) >>> b_i[4:0]; // Arithmetic right shift

            // Comparison operations
            ALU_SLT:  result_o = ($signed(a_i) < $signed(b_i)) ? 32'd1 : 32'd0; // signed
            ALU_SLTU: result_o = (a_i < b_i) ? 32'd1 : 32'd0;                   // unsigned

            // Special operation
            ALU_LUI:  result_o = b_i; // Load upper immediate (pass-through)

            // Default safety case
            default:  result_o = a_i + b_i;

        endcase
    end

    // ========================================================
    // ZERO FLAG LOGIC
    // Used for branch decisions (e.g., BEQ checks zero)
    // ========================================================
    assign zero_o = (result_o == 32'h0);

endmodule
