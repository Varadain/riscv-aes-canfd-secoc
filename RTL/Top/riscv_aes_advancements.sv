// ============================================================
// Top-level module for 5-stage pipelined RISC-V core
// This module connects all pipeline stages:
// IF → ID → EX → MEM → WB
// ============================================================
// ============================================================
// 5-STAGE PIPELINED RISC-V CORE (TOP MODULE)
// ============================================================
//
//                 PIPELINE OVERVIEW
//
//   ┌────────┐   ┌────────┐   ┌────────┐   ┌────────┐   ┌────────┐
//   │   IF   │→→ │   ID   │→→ │   EX   │→→ │   MEM  │→→ │   WB   │
//   └────────┘   └────────┘   └────────┘   └────────┘   └────────┘
//
//   IF  : Instruction Fetch (PC + Instruction Memory)
//   ID  : Decode + Register Read + Immediate Generation
//   EX  : ALU Operations + Branch Decision
//   MEM : Data Memory Access (Load/Store)
//   WB  : Write Back to Register File
//
// ------------------------------------------------------------
// DATA FLOW (Forward Direction):
//
//   PC → Instruction → Decode → Execute → Memory → Writeback
//
// ------------------------------------------------------------
// HAZARD HANDLING:
//
//   1. Data Hazards:
//      - Forwarding Unit (EX/MEM/WB → EX)
//      - Avoids unnecessary stalls
//
//   2. Load-Use Hazard:
//      - Hazard Unit inserts stall
//
//   3. Control Hazards:
//      - Branch resolved in EX stage
//      - Flush IF/ID pipeline on branch taken
//
// ------------------------------------------------------------
// FORWARDING PATHS:
//
//         MEM/WB ───────┐
//                       ↓
//   ID → EX → ALU → MEM → WB
//        ↑        ↑
//        └────────┘
//          Forwarding
//
// ------------------------------------------------------------
// PIPELINE REGISTERS:
//
//   IF/ID → ID/EX → EX/MEM → MEM/WB
//
// Each stage stores:
//   - Data signals
//   - Control signals
//
// ------------------------------------------------------------
// KEY DESIGN FEATURES:
//
//   - 5-stage classic RISC pipeline
//   - Hazard detection + forwarding
//   - Branch handling with flush
//   - Fully synthesizable RTL
//
// ============================================================

module riscv_aes_advancements (
    input  logic clk,     // System clock driving all pipeline stages
    input  logic rst_n,   // Active-low reset (clears pipeline)
    input  logic spi_miso, // Sensor SPI input from external sensor

    // FPGA/thesis debug outputs keep the SoC observable after synthesis.
    output logic [31:0] current_pc_debug,
    output logic        aes_done_debug,
    output logic [31:0] aes_ciphertext_debug,
    output logic        uart_tx,
    output logic        spi_mosi,
    output logic        spi_sclk,
    output logic        spi_ss_n,
    output logic        irq_debug,
    output logic        sleep_debug,
    output logic [31:0] activity_counter_debug,
    output logic        can_ids_alert_debug
);
    // ========================================================
    // IF (Instruction Fetch) Stage Signals
    // ========================================================
    logic [31:0] pc_if;       // Program Counter value in IF stage
    logic [31:0] instr_if;    // Instruction fetched from memory

    logic        stall_if;    // Stall signal (used for hazards)
    logic        flush_ifid;  // Flush IF/ID pipeline register

    // ========================================================
    // IF/ID Pipeline Registers (between IF and ID stages)
    // ========================================================
    logic [31:0] pc_id;       // PC passed to ID stage
    logic [31:0] instr_id;    // Instruction passed to ID stage

    // ========================================================
    // ID (Instruction Decode) Stage Signals
    // ========================================================
    logic [4:0]  rs1_id, rs2_id, rd_id;     // Register addresses
    logic [31:0] rs1_data_id, rs2_data_id;  // Register values
    logic [31:0] imm_id;                   // Immediate value

    // Control signals generated in ID stage
    logic reg_write_id;
    logic mem_read_id;
    logic mem_write_id;
    logic mem_to_reg_id;
    logic alu_src_id;
    logic branch_id;
    logic [3:0] alu_ctrl_id;
    logic custom_instr_id;
    logic [2:0] custom_cmd_id;

    // ========================================================
    // ID/EX Pipeline Registers (between ID and EX)
    // ========================================================
    logic [31:0] pc_ex;
    logic [4:0]  rs1_ex, rs2_ex, rd_ex;
    logic [31:0] rs1_data_ex, rs2_data_ex;
    logic [31:0] imm_ex;

    // Control signals carried into EX stage
    logic reg_write_ex;
    logic mem_read_ex;
    logic mem_write_ex;
    logic mem_to_reg_ex;
    logic alu_src_ex;
    logic branch_ex;
    logic [3:0] alu_ctrl_ex;
    logic custom_instr_ex;
    logic [2:0] custom_cmd_ex;

    // ========================================================
    // Forwarding (Data Hazard Resolution)
    // ========================================================
    logic [1:0] forward_a;   // Select signal for operand A
    logic [1:0] forward_b;   // Select signal for operand B

    // ========================================================
    // EX (Execute) Stage Outputs
    // ========================================================
    logic [31:0] alu_result_ex;      // Result from ALU
    logic [31:0] rs2_forwarded_ex;   // Forwarded rs2 value (for store)
    logic [31:0] branch_target_ex;   // Target address for branch
    logic        branch_taken_ex;    // Branch decision

    // ========================================================
    // EX/MEM Pipeline Registers
    // ========================================================
    logic [31:0] alu_result_mem;
    logic [31:0] rs2_data_mem;
    logic [4:0]  rd_mem;

    logic reg_write_mem;
    logic mem_read_mem;
    logic mem_write_mem;
    logic mem_to_reg_mem;
    logic custom_instr_mem;
    logic [2:0] custom_cmd_mem;

    // Memory read output
    logic [31:0] mem_read_data_mem;

    // ========================================================
    // MEM/WB Pipeline Registers
    // ========================================================
    logic [31:0] alu_result_wb;
    logic [31:0] mem_read_data_wb;
    logic [4:0]  rd_wb;

    logic reg_write_wb;
    logic mem_to_reg_wb;

    // Final writeback data
    logic [31:0] writeback_data;
    logic        uart_tx_mem;
    logic        spi_mosi_mem;
    logic        spi_sclk_mem;
    logic        spi_ss_n_mem;
    logic        irq_mem;
    logic        sleep_mem;
    logic        aes_done_mem;
    logic [31:0] aes_ciphertext_mem;
    logic [31:0] activity_counter_mem;
    logic        can_ids_alert_mem;

    // ========================================================
    // PROGRAM COUNTER (PC)
    // Handles sequential execution and branch redirection
    // ========================================================
    pc_reg u_pc_reg (
        .clk(clk),
        .rst_n(rst_n),
        .stall(stall_if),  // Stop PC update during hazard
        .next_pc(branch_taken_ex ? branch_target_ex : (pc_if + 32'd4)),
        .current_pc(pc_if)
    );

    // ========================================================
    // IF STAGE: Fetch instruction from memory
    // ========================================================
    if_stage u_if_stage (
        .pc_i(pc_if),
        .instr_o(instr_if)
    );

    // ========================================================
    // IF → ID Pipeline Register
    // Handles flush (branch) and stall conditions
    // ========================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pc_id    <= 32'h0;
        instr_id <= 32'h00000013;
    end
    else if (flush_ifid || branch_taken_ex) begin
        // Insert NOP
        pc_id    <= 32'h0;
        instr_id <= 32'h00000013;
    end
    else if (!stall_if) begin
        pc_id    <= pc_if;
        instr_id <= instr_if;
    end
end

    // ========================================================
    // ID STAGE: Decode instruction + read register file
    // ========================================================
    id_stage u_id_stage (
        .clk(clk),
		          .rst_n(rst_n),
        .instr_i(instr_id),

        // Register outputs
        .rs1_data_o(rs1_data_id),
        .rs2_data_o(rs2_data_id),
        .imm_o(imm_id),

        .rs1_o(rs1_id),
        .rs2_o(rs2_id),
        .rd_o(rd_id),

        // Control signals
        .reg_write_o(reg_write_id),
        .mem_read_o(mem_read_id),
        .mem_write_o(mem_write_id),
        .mem_to_reg_o(mem_to_reg_id),
        .alu_src_o(alu_src_id),
        .branch_o(branch_id),
        .alu_ctrl_o(alu_ctrl_id),
        .custom_instr_o(custom_instr_id),
        .custom_cmd_o(custom_cmd_id),

        // Writeback connection
        .wb_en_i(reg_write_wb),
        .wb_rd_i(rd_wb),
        .wb_data_i(writeback_data)
    );

    // ========================================================
    // HAZARD UNIT
    // Detects load-use hazards and stalls pipeline
    // ========================================================
    hazard_unit u_hazard_unit (
        .id_rs1_i(rs1_id),
        .id_rs2_i(rs2_id),
        .ex_rd_i(rd_ex),
        .ex_mem_read_i(mem_read_ex),

        .stall_o(stall_if),
        .flush_ifid_o(flush_ifid)
    );

    // ========================================================
    // ID → EX Pipeline Register
    // ========================================================
   always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

        pc_ex         <= 0;
        rs1_ex        <= 0;
        rs2_ex        <= 0;
        rd_ex         <= 0;

        rs1_data_ex   <= 0;
        rs2_data_ex   <= 0;
        imm_ex        <= 0;

        reg_write_ex  <= 0;
        mem_read_ex   <= 0;
        mem_write_ex  <= 0;
        mem_to_reg_ex <= 0;
        alu_src_ex    <= 0;
        branch_ex     <= 0;
        alu_ctrl_ex   <= 0;
        custom_instr_ex <= 0;
        custom_cmd_ex   <= 0;

    end
    else if (branch_taken_ex) begin

        // Flush pipeline stage
        pc_ex         <= 0;
        rs1_ex        <= 0;
        rs2_ex        <= 0;
        rd_ex         <= 0;

        rs1_data_ex   <= 0;
        rs2_data_ex   <= 0;
        imm_ex        <= 0;

        reg_write_ex  <= 0;
        mem_read_ex   <= 0;
        mem_write_ex  <= 0;
        mem_to_reg_ex <= 0;
        alu_src_ex    <= 0;
        branch_ex     <= 0;
        alu_ctrl_ex   <= 0;
        custom_instr_ex <= 0;
        custom_cmd_ex   <= 0;

    end
    else if (!stall_if) begin

        pc_ex         <= pc_id;
        rs1_ex        <= rs1_id;
        rs2_ex        <= rs2_id;
        rd_ex         <= rd_id;

        rs1_data_ex   <= rs1_data_id;
        rs2_data_ex   <= rs2_data_id;
        imm_ex        <= imm_id;

        reg_write_ex  <= reg_write_id;
        mem_read_ex   <= mem_read_id;
        mem_write_ex  <= mem_write_id;
        mem_to_reg_ex <= mem_to_reg_id;
        alu_src_ex    <= alu_src_id;
        branch_ex     <= branch_id;
        alu_ctrl_ex   <= alu_ctrl_id;
        custom_instr_ex <= custom_instr_id;
        custom_cmd_ex   <= custom_cmd_id;

    end
end
    // ========================================================
    // FORWARDING UNIT
    // Resolves data hazards without stalling
    // ========================================================
    forwarding_unit u_forwarding_unit (
        .ex_rs1_i(rs1_ex),
        .ex_rs2_i(rs2_ex),
        .mem_rd_i(rd_mem),
        .wb_rd_i(rd_wb),

        .mem_reg_write_i(reg_write_mem),
        .wb_reg_write_i(reg_write_wb),

        .forward_a_o(forward_a),
        .forward_b_o(forward_b)
    );

    // ========================================================
    // EX STAGE: ALU operations + branch decision
    // ========================================================
    ex_stage u_ex_stage (
        .pc_i(pc_ex),
        .rs1_data_i(rs1_data_ex),
        .rs2_data_i(rs2_data_ex),
        .imm_i(imm_ex),

        .alu_src_i(alu_src_ex),
        .branch_i(branch_ex),
        .alu_ctrl_i(alu_ctrl_ex),
        .custom_instr_i(custom_instr_ex),

        // Forwarding inputs
        .forward_a_i(forward_a),
        .forward_b_i(forward_b),

        .mem_alu_result_i(alu_result_mem),
        .wb_data_i(writeback_data),

        // Outputs
        .alu_result_o(alu_result_ex),
        .rs2_forwarded_o(rs2_forwarded_ex),
        .branch_target_o(branch_target_ex),
        .branch_taken_o(branch_taken_ex)
    );

    // ========================================================
    // EX → MEM Pipeline Register
    // ========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alu_result_mem <= 0;
            rs2_data_mem   <= 0;
            rd_mem         <= 0;

            reg_write_mem  <= 0;
            mem_read_mem   <= 0;
            mem_write_mem  <= 0;
            mem_to_reg_mem <= 0;
            custom_instr_mem <= 0;
            custom_cmd_mem   <= 0;
        end 
        else begin
            alu_result_mem <= alu_result_ex;
            rs2_data_mem   <= rs2_forwarded_ex;
            rd_mem         <= rd_ex;

            reg_write_mem  <= reg_write_ex;
            mem_read_mem   <= mem_read_ex;
            mem_write_mem  <= mem_write_ex;
            mem_to_reg_mem <= mem_to_reg_ex;
            custom_instr_mem <= custom_instr_ex;
            custom_cmd_mem   <= custom_cmd_ex;
        end
    end

    // ========================================================
    // MEM STAGE: Data memory access
    // ========================================================
    mem_stage u_mem_stage (
        .clk(clk),
        .rst_n(rst_n),
        .addr_i(alu_result_mem),
        .write_data_i(rs2_data_mem),

        .mem_read_i(mem_read_mem),
        .mem_write_i(mem_write_mem),
        .custom_valid_i(custom_instr_mem),
        .custom_cmd_i(custom_cmd_mem),

        .read_data_o(mem_read_data_mem),
        .uart_tx_o(uart_tx_mem),
        .spi_miso_i(spi_miso),
        .spi_mosi_o(spi_mosi_mem),
        .spi_sclk_o(spi_sclk_mem),
        .spi_ss_n_o(spi_ss_n_mem),
        .irq_o(irq_mem),
        .sleep_o(sleep_mem),
        .aes_done_o(aes_done_mem),
        .aes_ciphertext_debug_o(aes_ciphertext_mem),
        .activity_counter_debug_o(activity_counter_mem),
        .can_ids_alert_debug_o(can_ids_alert_mem)
    );

    // ========================================================
    // MEM → WB Pipeline Register
    // ========================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alu_result_wb    <= 0;
            mem_read_data_wb <= 0;
            rd_wb            <= 0;

            reg_write_wb     <= 0;
            mem_to_reg_wb    <= 0;
        end 
        else begin
            alu_result_wb    <= alu_result_mem;
            mem_read_data_wb <= mem_read_data_mem;
            rd_wb            <= rd_mem;

            reg_write_wb     <= reg_write_mem;
            mem_to_reg_wb    <= mem_to_reg_mem;
        end
    end

    // ========================================================
    // WB STAGE: Select final result and write back to register
    // ========================================================
    wb_stage u_wb_stage (
        .alu_result_i(alu_result_wb),
        .mem_read_data_i(mem_read_data_wb),
        .mem_to_reg_i(mem_to_reg_wb),

        .wb_data_o(writeback_data)
    );

    assign current_pc_debug       = pc_if;
    assign aes_done_debug         = aes_done_mem;
    assign aes_ciphertext_debug   = aes_ciphertext_mem;
    assign uart_tx                = uart_tx_mem;
    assign spi_mosi               = spi_mosi_mem;
    assign spi_sclk               = spi_sclk_mem;
    assign spi_ss_n               = spi_ss_n_mem;
    assign irq_debug              = irq_mem;
    assign sleep_debug            = sleep_mem;
    assign activity_counter_debug = activity_counter_mem;
    assign can_ids_alert_debug    = can_ids_alert_mem;

endmodule
