// ============================================================
// REGISTER FILE (32 x 32-bit)
// ============================================================
//
// ARCHITECTURE OVERVIEW:
//
//                +-------------------------+
//   rs1_i -----> |                         | -----> rs1_data_o
//                |                         |
//   rs2_i -----> |     REGISTER FILE       | -----> rs2_data_o
//                |        (32 x 32)        |
//   rd_i  -----> |                         |
//   rd_data_i -->|                         |
//   rd_we_i ---->|                         |
//                +-------------------------+
//
// ------------------------------------------------------------
// DESCRIPTION:
//
// - Contains 32 registers (x0 to x31), each 32 bits wide
// - Supports:
//     * Two simultaneous reads (rs1, rs2)
//     * One write (rd)
//
// ------------------------------------------------------------
// SPECIAL RISC-V RULE:
//
// - Register x0 is hardwired to zero
// - Any read from x0 returns 0
// - Writes to x0 are ignored
//
// ------------------------------------------------------------
// BYPASS (WRITE-FORWARDING) LOGIC:
//
// This module implements "same-cycle bypass":
//
//   If instruction writes to rd and reads same register:
//     → return rd_data_i directly (no need to wait for clock)
//
// Example:
//   ADD x1, x2, x3
//   SUB x4, x1, x5   (same cycle read of x1)
//
// Without bypass → wrong value
// With bypass    → correct value
//
// ------------------------------------------------------------
// READ PRIORITY:
//
//   1. If rs == x0 → return 0
//   2. Else if bypass condition → return write data
//   3. Else → return stored register value
//
// ------------------------------------------------------------
// WRITE BEHAVIOR:
//
// - Happens on positive clock edge
// - Only if:
//     rd_we_i = 1 AND rd_i != 0
//
// ============================================================

module reg_file (
    input  logic        clk,         // Clock signal for synchronous write
	 
    input  logic        rst_n,       // Active-low synchronous reset
    input  logic [4:0]  rs1_i,       // Source register 1 address
    input  logic [4:0]  rs2_i,       // Source register 2 address
    input  logic [4:0]  rd_i,        // Destination register address
    input  logic [31:0] rd_data_i,   // Data to be written into rd
    input  logic        rd_we_i,     // Write enable signal

    output logic [31:0] rs1_data_o,  // Output data for rs1
    output logic [31:0] rs2_data_o   // Output data for rs2
);

    // ========================================================
    // REGISTER STORAGE ARRAY
    // 32 registers, each 32-bit wide
    // regs[0] corresponds to x0
    // ========================================================
    logic [31:0] regs [0:31];

    // ========================================================
    // BYPASS LOGIC (WRITE-FORWARDING)
    //
    // Detect if current read register is same as write register
    // AND write is happening in same cycle
    //
    // Conditions:
    //   - Write enabled
    //   - rd is not x0
    //   - rd matches rs1 or rs2
    // ========================================================
    logic rs1_bypass;
    logic rs2_bypass;

    assign rs1_bypass = rd_we_i && (rd_i != 5'h0) && (rd_i == rs1_i);
    assign rs2_bypass = rd_we_i && (rd_i != 5'h0) && (rd_i == rs2_i);

    // ========================================================
    // READ LOGIC (COMBINATIONAL)
    //
    // Priority:
    //   1. If register is x0 → return 0
    //   2. If bypass condition → return rd_data_i
    //   3. Otherwise → return stored value
    // ========================================================
    assign rs1_data_o =
        (rs1_i == 5'h0) ? 32'h0 :
        (rs1_bypass     ? rd_data_i : regs[rs1_i]);

    assign rs2_data_o =
        (rs2_i == 5'h0) ? 32'h0 :
        (rs2_bypass     ? rd_data_i : regs[rs2_i]);

    // ========================================================
    // WRITE LOGIC (SEQUENTIAL)
    //
    // - Triggered on rising clock edge
    // - Writes only if:
    //     rd_we_i = 1 AND rd_i != 0
    //
    // - Prevents writing into x0
    // ========================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int reset_idx = 0; reset_idx < 32; reset_idx = reset_idx + 1) begin
                regs[reset_idx] <= 32'h0;
            end
        end
        else if (rd_we_i && (rd_i != 5'h0)) begin
            regs[rd_i] <= rd_data_i;
        end
    end

endmodule
