// ============================================================
// ID STAGE (Instruction Decode Stage)
// ============================================================
//
// PIPELINE POSITION:
//
//   IF → ID → EX → MEM → WB
//
// This stage is responsible for:
//   1. Decoding the instruction
//   2. Extracting register addresses (rs1, rs2, rd)
//   3. Reading register values from register file
//   4. Generating immediate values
//   5. Generating control signals for later stages
//
// ------------------------------------------------------------
// DATA FLOW:
//
//   instr_i
//      |
//      |--> opcode, funct3, funct7 (instruction decoding)
//      |
//      |--> rs1, rs2, rd (register indices)
//      |
//      |--> reg_file → rs1_data_o, rs2_data_o
//      |
//      |--> imm_gen → imm_o
//      |
//      |--> control_unit → control signals
//
// ------------------------------------------------------------
// WRITEBACK PATH:
//
//   WB Stage → (wb_rd_i, wb_data_i, wb_en_i)
//           → Register File → updated register values
//
// This enables correct data propagation across pipeline stages.
//
// ============================================================

module id_stage (
    input  logic        clk,          // Clock for register file write operations
	 
    input  logic        rst_n,        // Active-low reset for register file
    input  logic [31:0] instr_i,      // Instruction from IF/ID pipeline register

    // Outputs to EX stage
    output logic [31:0] rs1_data_o,   // Value of source register rs1
    output logic [31:0] rs2_data_o,   // Value of source register rs2
    output logic [31:0] imm_o,        // Immediate value (decoded based on instruction type)

    // Register indices extracted from instruction
    output logic [4:0]  rs1_o,        // Source register 1 index
    output logic [4:0]  rs2_o,        // Source register 2 index
    output logic [4:0]  rd_o,         // Destination register index

    // Control signals propagated to EX stage
    output logic        reg_write_o,  // Enable register write in WB stage
    output logic        mem_read_o,   // Enable memory read (load)
    output logic        mem_write_o,  // Enable memory write (store)
    output logic        mem_to_reg_o, // Select memory data for writeback
    output logic        alu_src_o,    // Select immediate vs register for ALU input
    output logic        branch_o,     // Branch instruction indicator
    output logic [3:0]  alu_ctrl_o,   // ALU operation selector
    output logic        custom_instr_o,
    output logic [2:0]  custom_cmd_o,

    // Writeback interface from WB stage
    input  logic        wb_en_i,      // Write enable signal
    input  logic [4:0]  wb_rd_i,      // Destination register index (WB stage)
    input  logic [31:0] wb_data_i     // Data to be written back
);

    // ========================================================
    // Instruction Field Extraction
    // ========================================================
    // RISC-V instruction format fields:
    // [6:0]   → opcode
    // [14:12] → funct3
    // [31:25] → funct7

    logic [6:0] opcode;   // Determines instruction type
    logic [2:0] funct3;   // Further opcode refinement
    logic [6:0] funct7;   // Used for ALU operations (e.g., ADD vs SUB)

    // Extract fields from instruction
    assign opcode = instr_i[6:0];
    assign funct3 = instr_i[14:12];
    assign funct7 = instr_i[31:25];

    // ========================================================
    // Register Address Extraction
    // ========================================================
    // These fields determine which registers are read/written

    assign rs1_o = instr_i[19:15];   // First source register
    assign rs2_o = instr_i[24:20];   // Second source register
    assign rd_o  = instr_i[11:7];    // Destination register
    assign custom_cmd_o = funct3;

    // ========================================================
    // Register File
    // ========================================================
    // Provides register read and write functionality
    //
    // Read:
    //   rs1_o → rs1_data_o
    //   rs2_o → rs2_data_o
    //
    // Write (from WB stage):
    //   wb_rd_i ← wb_data_i (if wb_en_i is asserted)

    reg_file u_reg_file (
        .clk      (clk),            // Clock for synchronous write
		  
        .rst_n    (rst_n),          // Register file reset
        .rs1_i    (rs1_o),          // Read address 1
        .rs2_i    (rs2_o),          // Read address 2
        .rd_i     (wb_rd_i),        // Write address from WB stage
        .rd_data_i(wb_data_i),      // Data to write
        .rd_we_i  (wb_en_i),        // Write enable signal

        // Outputs
        .rs1_data_o(rs1_data_o),    // Data from rs1
        .rs2_data_o(rs2_data_o)     // Data from rs2
    );

    // ========================================================
    // Immediate Generator
    // ========================================================
    // Generates sign-extended immediate values based on
    // instruction type (I, S, B, U, J formats)

    imm_gen u_imm_gen (
        .instr_i(instr_i),   // Full instruction input
        .imm_o  (imm_o)      // Decoded immediate output
    );

    // ========================================================
    // Control Unit
    // ========================================================
    // Generates control signals required by later pipeline stages
    //
    // Based on:
    //   opcode → instruction class
    //   funct3 → operation subtype
    //   funct7 → ALU variant (e.g., ADD vs SUB)

    control_unit u_control_unit (
        .opcode_o    (opcode),       // Instruction opcode
        .funct3_o    (funct3),       // Function field
        .funct7_o    (funct7),       // Function field

        // Control outputs
        .reg_write_o (reg_write_o),  // Enable register write
        .mem_read_o  (mem_read_o),   // Load instruction
        .mem_write_o (mem_write_o),  // Store instruction
        .mem_to_reg_o(mem_to_reg_o), // Select memory output for WB
        .alu_src_o   (alu_src_o),    // Immediate or register operand
        .branch_o    (branch_o),     // Branch control
        .alu_ctrl_o  (alu_ctrl_o),   // ALU operation code
        .custom_instr_o(custom_instr_o)
    );

endmodule
