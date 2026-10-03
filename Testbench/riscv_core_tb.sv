`timescale 1ns/1ps
// ============================================================
// RISC-V 5-STAGE PIPELINE OVERVIEW
// ============================================================
//
// Each instruction flows through 5 stages:
//
//   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐
//   │  IF  │→→ │  ID   │→→│  EX  │→→ │ MEM  │→→ │  WB  │
//   └──────┘   └──────┘   └──────┘   └──────┘   └──────┘
//
// IF  (Instruction Fetch)   : Fetch instruction from memory
// ID  (Instruction Decode)  : Decode + read registers
// EX  (Execute)             : Perform ALU operation
// MEM (Memory Access)       : Load/store memory
// WB  (Write Back)          : Write result to register
//
// Example (ADD x3, x1, x2):
//
// Cycle 1: IF  → fetch ADD
// Cycle 2: ID  → read x1, x2
// Cycle 3: EX  → compute x1 + x2
// Cycle 4: MEM → (not used)
// Cycle 5: WB  → write result into x3
//
// Multiple instructions run in parallel (pipeline overlap)
// ============================================================
module riscv_core_tb;
`ifdef SYNTHESIS
    // Quartus-friendly stub (no behavioral stimulus in synthesis/elaboration mode).
    logic clk;
    logic rst_n;
    logic [31:0] current_pc_debug_tb;
    logic        aes_done_debug_tb;
    logic [31:0] aes_ciphertext_debug_tb;
    logic        uart_tx_tb;
    logic        spi_miso_tb;
    logic        spi_mosi_tb;
    logic        spi_sclk_tb;
    logic        spi_ss_n_tb;
    logic        irq_debug_tb;
    logic        sleep_debug_tb;
    logic [31:0] activity_counter_debug_tb;
    logic        can_ids_alert_debug_tb;

    assign clk   = 1'b0;
    assign rst_n = 1'b1;
    assign spi_miso_tb = 1'b0;

    riscv_aes_advancements dut (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .spi_miso              (spi_miso_tb),
        .current_pc_debug      (current_pc_debug_tb),
        .aes_done_debug        (aes_done_debug_tb),
        .aes_ciphertext_debug  (aes_ciphertext_debug_tb),
        .uart_tx               (uart_tx_tb),
        .spi_mosi              (spi_mosi_tb),
        .spi_sclk              (spi_sclk_tb),
        .spi_ss_n              (spi_ss_n_tb),
        .irq_debug             (irq_debug_tb),
        .sleep_debug           (sleep_debug_tb),
        .activity_counter_debug(activity_counter_debug_tb),
        .can_ids_alert_debug   (can_ids_alert_debug_tb)
    );

`else
    // -------------------------------------------------------------------------
    // Testbench controls
    // -------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    logic [31:0] current_pc_debug_tb;
    logic        aes_done_debug_tb;
    logic [31:0] aes_ciphertext_debug_tb;
    logic        uart_tx_tb;
    logic        spi_miso_tb;
    logic        spi_mosi_tb;
    logic        spi_sclk_tb;
    logic        spi_ss_n_tb;
    logic        irq_debug_tb;
    logic        sleep_debug_tb;
    logic [31:0] activity_counter_debug_tb;
    logic        can_ids_alert_debug_tb;

    int pass_count;
    int fail_count;
    int if_stall_seen_count;
    int if_flush_seen_count;
    int aes_sel_seen_count;
    int aes_write_seen_count;
    int aes_read_seen_count;
    int uart_done_seen_count;
    int irq_seen_count;
    int spi_sclk_toggle_count;
    logic spi_sclk_prev;
    logic [7:0] verification_phase_id;

    localparam int CLK_HALF   = 5;
    localparam int PIPE_DRAIN = 12;

    assign spi_miso_tb = spi_mosi_tb; // simple loopback for SPI waveform visibility

    riscv_aes_advancements dut (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .spi_miso              (spi_miso_tb),
        .current_pc_debug      (current_pc_debug_tb),
        .aes_done_debug        (aes_done_debug_tb),
        .aes_ciphertext_debug  (aes_ciphertext_debug_tb),
        .uart_tx               (uart_tx_tb),
        .spi_mosi              (spi_mosi_tb),
        .spi_sclk              (spi_sclk_tb),
        .spi_ss_n              (spi_ss_n_tb),
        .irq_debug             (irq_debug_tb),
        .sleep_debug           (sleep_debug_tb),
        .activity_counter_debug(activity_counter_debug_tb),
        .can_ids_alert_debug   (can_ids_alert_debug_tb)
    );

    // Focused security-extension harnesses. These instances exercise the same
    // synthesizable peripheral RTL with direct MMIO transactions, allowing
    // precise ground-truth labels and key-lifecycle checks without making the
    // CPU-directed application program unnecessarily long.
    logic [31:0] ids_eval_addr;
    logic [31:0] ids_eval_wdata;
    logic        ids_eval_we;
    logic        ids_eval_re;
    logic [31:0] ids_eval_rdata;
    logic        ids_eval_irq;
    logic        ids_eval_alert;
    logic        ids_eval_active;

    can_ids_mmio u_can_ids_eval (
        .clk          (clk),
        .rst_n        (rst_n),
        .clk_en_i     (1'b1),
        .addr_i       (ids_eval_addr),
        .write_data_i (ids_eval_wdata),
        .write_en_i   (ids_eval_we),
        .read_en_i    (ids_eval_re),
        .hw_submit_i  (1'b0),
        .hw_frame_id_i(11'h0),
        .hw_frame_dlc_i(4'h0),
        .hw_frame_payload_i(64'h0),
        .hw_frame_fd_i(1'b0),
        .hw_ready_o   (),
        .read_data_o  (ids_eval_rdata),
        .alert_irq_o  (ids_eval_irq),
        .alert_debug_o(ids_eval_alert),
        .active_o     (ids_eval_active)
    );

    logic [31:0] aes_sec_addr;
    logic [31:0] aes_sec_wdata;
    logic        aes_sec_we;
    logic        aes_sec_re;
    logic [31:0] aes_sec_rdata;
    logic [31:0] aes_sec_custom_result;
    logic        aes_sec_irq;
    logic [31:0] aes_sec_ciphertext;
    logic        aes_sec_active;

    aes_mmio u_aes_security_eval (
        .clk               (clk),
        .rst_n             (rst_n),
        .clk_en_i          (1'b1),
        .addr_i            (aes_sec_addr),
        .write_data_i      (aes_sec_wdata),
        .write_en_i        (aes_sec_we),
        .read_en_i         (aes_sec_re),
        .custom_valid_i    (1'b0),
        .custom_cmd_i      (3'b000),
        .custom_rs1_i      (32'h0),
        .custom_rs2_i      (32'h0),
        .custom_result_o   (aes_sec_custom_result),
        .read_data_o       (aes_sec_rdata),
        .aes_done_irq_o    (aes_sec_irq),
        .ciphertext_debug_o(aes_sec_ciphertext),
        .active_o          (aes_sec_active)
    );

    logic [31:0] canfd_soc_addr;
    logic [31:0] canfd_soc_wdata;
    logic        canfd_soc_mem_read;
    logic        canfd_soc_mem_write;
    logic [31:0] canfd_soc_rdata;
    logic        canfd_soc_irq;

    // Directly driven MEM-stage harness verifies the complete CAN-FD page,
    // SecOC-to-IDS connection, interrupt routing, and shared RAM DMA path.
    mem_stage u_canfd_soc_eval (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .addr_i                  (canfd_soc_addr),
        .write_data_i            (canfd_soc_wdata),
        .mem_read_i              (canfd_soc_mem_read),
        .mem_write_i             (canfd_soc_mem_write),
        .custom_valid_i          (1'b0),
        .custom_cmd_i            (3'b000),
        .read_data_o             (canfd_soc_rdata),
        .uart_tx_o               (),
        .spi_miso_i              (1'b0),
        .spi_mosi_o              (),
        .spi_sclk_o              (),
        .spi_ss_n_o              (),
        .irq_o                   (canfd_soc_irq),
        .sleep_o                 (),
        .aes_done_o              (),
        .aes_ciphertext_debug_o  (),
        .activity_counter_debug_o(),
        .can_ids_alert_debug_o   ()
    );

    // -------------------------------------------------------------------------
    // Waveform observation aliases
    // -------------------------------------------------------------------------
    wire [31:0] obs_if_pc              = dut.pc_if;
    wire [31:0] obs_if_instr           = dut.instr_if;
    wire        obs_if_stall           = dut.stall_if;
    wire        obs_if_flush           = dut.flush_ifid;

    wire [31:0] obs_id_pc              = dut.pc_id;
    wire [31:0] obs_id_instr           = dut.instr_id;
    wire [4:0]  obs_id_rs1             = dut.rs1_id;
    wire [4:0]  obs_id_rs2             = dut.rs2_id;
    wire [4:0]  obs_id_rd              = dut.rd_id;
    wire [31:0] obs_id_rs1_data        = dut.rs1_data_id;
    wire [31:0] obs_id_rs2_data        = dut.rs2_data_id;
    wire [31:0] obs_id_imm             = dut.imm_id;
    wire        obs_id_reg_write       = dut.reg_write_id;
    wire        obs_id_mem_read        = dut.mem_read_id;
    wire        obs_id_mem_write       = dut.mem_write_id;
    wire        obs_id_mem_to_reg      = dut.mem_to_reg_id;
    wire        obs_id_alu_src         = dut.alu_src_id;
    wire        obs_id_branch          = dut.branch_id;
    wire [3:0]  obs_id_alu_ctrl        = dut.alu_ctrl_id;

    wire [31:0] obs_ex_pc              = dut.pc_ex;
    wire [4:0]  obs_ex_rs1             = dut.rs1_ex;
    wire [4:0]  obs_ex_rs2             = dut.rs2_ex;
    wire [4:0]  obs_ex_rd              = dut.rd_ex;
    wire [31:0] obs_ex_rs1_data        = dut.rs1_data_ex;
    wire [31:0] obs_ex_rs2_data        = dut.rs2_data_ex;
    wire [31:0] obs_ex_imm             = dut.imm_ex;
    wire        obs_ex_reg_write       = dut.reg_write_ex;
    wire        obs_ex_mem_read        = dut.mem_read_ex;
    wire        obs_ex_mem_write       = dut.mem_write_ex;
    wire        obs_ex_mem_to_reg      = dut.mem_to_reg_ex;
    wire        obs_ex_alu_src         = dut.alu_src_ex;
    wire        obs_ex_branch          = dut.branch_ex;
    wire [3:0]  obs_ex_alu_ctrl        = dut.alu_ctrl_ex;
    wire [1:0]  obs_forward_a          = dut.forward_a;
    wire [1:0]  obs_forward_b          = dut.forward_b;
    wire [31:0] obs_ex_op_a            = dut.u_ex_stage.op_a;
    wire [31:0] obs_ex_op_b            = dut.u_ex_stage.op_b;
    wire [31:0] obs_ex_alu_result_raw  = dut.u_ex_stage.alu_result_raw;
    wire [31:0] obs_ex_alu_result      = dut.alu_result_ex;
    wire [31:0] obs_ex_rs2_forwarded   = dut.rs2_forwarded_ex;
    wire [31:0] obs_ex_branch_target   = dut.branch_target_ex;
    wire        obs_ex_branch_taken    = dut.branch_taken_ex;

    wire [31:0] obs_mem_alu_result     = dut.alu_result_mem;
    wire [31:0] obs_mem_write_data     = dut.rs2_data_mem;
    wire [4:0]  obs_mem_rd             = dut.rd_mem;
    wire        obs_mem_reg_write      = dut.reg_write_mem;
    wire        obs_mem_read           = dut.mem_read_mem;
    wire        obs_mem_write          = dut.mem_write_mem;
    wire        obs_mem_to_reg         = dut.mem_to_reg_mem;
    wire [31:0] obs_mem_eff_addr       = dut.u_mem_stage.eff_addr;
    wire [2:0]  obs_mem_ls_tag         = dut.u_mem_stage.ls_tag;
    wire [31:0] obs_mem_raw_word       = dut.u_mem_stage.raw_mem_word;
    wire [31:0] obs_mem_merged_store   = dut.u_mem_stage.merged_store_word;
    wire [31:0] obs_mem_read_data      = dut.mem_read_data_mem;

    wire [31:0] obs_wb_alu_result      = dut.alu_result_wb;
    wire [31:0] obs_wb_mem_read_data   = dut.mem_read_data_wb;
    wire [4:0]  obs_wb_rd              = dut.rd_wb;
    wire        obs_wb_reg_write       = dut.reg_write_wb;
    wire        obs_wb_mem_to_reg      = dut.mem_to_reg_wb;
    wire [31:0] obs_wb_data            = dut.writeback_data;

    wire [31:0] obs_x0                 = dut.u_id_stage.u_reg_file.regs[0];
    wire [31:0] obs_x1                 = dut.u_id_stage.u_reg_file.regs[1];
    wire [31:0] obs_x2                 = dut.u_id_stage.u_reg_file.regs[2];
    wire [31:0] obs_x3                 = dut.u_id_stage.u_reg_file.regs[3];
    wire [31:0] obs_x4                 = dut.u_id_stage.u_reg_file.regs[4];
    wire [31:0] obs_x5                 = dut.u_id_stage.u_reg_file.regs[5];
    wire [31:0] obs_x6                 = dut.u_id_stage.u_reg_file.regs[6];
    wire [31:0] obs_x7                 = dut.u_id_stage.u_reg_file.regs[7];
    wire [31:0] obs_x8                 = dut.u_id_stage.u_reg_file.regs[8];
    wire [31:0] obs_x9                 = dut.u_id_stage.u_reg_file.regs[9];
    wire [31:0] obs_x10                = dut.u_id_stage.u_reg_file.regs[10];
    wire [31:0] obs_x11                = dut.u_id_stage.u_reg_file.regs[11];
    wire [31:0] obs_x12                = dut.u_id_stage.u_reg_file.regs[12];
    wire [31:0] obs_x13                = dut.u_id_stage.u_reg_file.regs[13];
    wire [31:0] obs_x14                = dut.u_id_stage.u_reg_file.regs[14];
    wire [31:0] obs_x15                = dut.u_id_stage.u_reg_file.regs[15];
    wire [31:0] obs_x16                = dut.u_id_stage.u_reg_file.regs[16];
    wire [31:0] obs_x17                = dut.u_id_stage.u_reg_file.regs[17];
    wire [31:0] obs_x18                = dut.u_id_stage.u_reg_file.regs[18];
    wire [31:0] obs_x19                = dut.u_id_stage.u_reg_file.regs[19];
    wire [31:0] obs_x20                = dut.u_id_stage.u_reg_file.regs[20];
    wire [31:0] obs_x21                = dut.u_id_stage.u_reg_file.regs[21];
    wire [31:0] obs_x22                = dut.u_id_stage.u_reg_file.regs[22];
    wire [31:0] obs_x23                = dut.u_id_stage.u_reg_file.regs[23];
    wire [31:0] obs_x24                = dut.u_id_stage.u_reg_file.regs[24];
    wire [31:0] obs_x25                = dut.u_id_stage.u_reg_file.regs[25];
    wire [31:0] obs_x26                = dut.u_id_stage.u_reg_file.regs[26];
    wire [31:0] obs_x27                = dut.u_id_stage.u_reg_file.regs[27];
    wire [31:0] obs_x28                = dut.u_id_stage.u_reg_file.regs[28];
    wire [31:0] obs_x29                = dut.u_id_stage.u_reg_file.regs[29];
    wire [31:0] obs_x30                = dut.u_id_stage.u_reg_file.regs[30];
    wire [31:0] obs_x31                = dut.u_id_stage.u_reg_file.regs[31];

    wire [31:0] obs_dmem0              = dut.u_mem_stage.u_data_mem.ram[0];
    wire [31:0] obs_dmem1              = dut.u_mem_stage.u_data_mem.ram[1];
    wire [31:0] obs_dmem2              = dut.u_mem_stage.u_data_mem.ram[2];
    wire [31:0] obs_dmem3              = dut.u_mem_stage.u_data_mem.ram[3];
    wire [31:0] obs_dmem4              = dut.u_mem_stage.u_data_mem.ram[4];
    wire [31:0] obs_dmem5              = dut.u_mem_stage.u_data_mem.ram[5];
    wire [31:0] obs_dmem6              = dut.u_mem_stage.u_data_mem.ram[6];
    wire [31:0] obs_dmem7              = dut.u_mem_stage.u_data_mem.ram[7];

    wire        obs_aes_sel            = dut.u_mem_stage.aes_sel;
    wire        obs_aes_write_en       = dut.u_mem_stage.aes_write_en;
    wire        obs_aes_read_en        = dut.u_mem_stage.aes_read_en;
    wire [7:0]  obs_aes_reg_offset     = dut.u_mem_stage.u_aes_mmio.reg_offset;
    wire        obs_aes_start          = dut.u_mem_stage.u_aes_mmio.aes_start_pulse;
    wire        obs_aes_busy           = dut.u_mem_stage.u_aes_mmio.busy_reg;
    wire        obs_aes_done           = dut.u_mem_stage.u_aes_mmio.done_reg;
    wire [127:0] obs_aes_key           = dut.u_mem_stage.u_aes_mmio.key_reg;
    wire [127:0] obs_aes_plaintext     = dut.u_mem_stage.u_aes_mmio.pt_reg;
    wire [127:0] obs_aes_ciphertext    = dut.u_mem_stage.u_aes_mmio.ct_reg;
    wire [3:0]  obs_aes_round          = dut.u_mem_stage.u_aes_mmio.u_aes128_lowpower.u_reusable_aes.round;
    wire [127:0] obs_aes_state         = dut.u_mem_stage.u_aes_mmio.u_aes128_lowpower.u_reusable_aes.state_reg;
    wire [127:0] obs_aes_round_key     = dut.u_mem_stage.u_aes_mmio.u_aes128_lowpower.u_reusable_aes.round_key;
    wire        obs_uart_busy          = dut.u_mem_stage.u_uart_mmio.tx_busy_o;
    wire        obs_uart_done          = dut.u_mem_stage.u_uart_mmio.done_latched;
    wire        obs_irq                = dut.irq_debug;
    wire        obs_sleep              = dut.sleep_debug;
    wire        obs_custom_id          = dut.custom_instr_id;
    wire        obs_custom_ex          = dut.custom_instr_ex;
    wire        obs_custom_mem         = dut.custom_instr_mem;
    wire [2:0]  obs_custom_cmd_mem     = dut.custom_cmd_mem;
    wire [31:0] obs_custom_result      = dut.u_mem_stage.custom_result;

    always @(posedge clk) begin
        if (dut.stall_if) begin
            if_stall_seen_count++;
        end
        if (dut.flush_ifid) begin
            if_flush_seen_count++;
        end
        if (dut.u_mem_stage.aes_sel) begin
            aes_sel_seen_count++;
        end
        if (dut.u_mem_stage.aes_write_en) begin
            aes_write_seen_count++;
        end
        if (dut.u_mem_stage.aes_read_en) begin
            aes_read_seen_count++;
        end
        if (dut.u_mem_stage.u_uart_mmio.done_latched) begin
            uart_done_seen_count++;
        end
        if (dut.irq_debug) begin
            irq_seen_count++;
        end
        if (spi_sclk_tb !== spi_sclk_prev) begin
            spi_sclk_toggle_count++;
            spi_sclk_prev <= spi_sclk_tb;
        end
    end

    // -------------------------------------------------------------------------
    // Clock and reset
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #CLK_HALF clk = ~clk;

    initial begin
        ids_eval_addr  = 32'h0;
        ids_eval_wdata = 32'h0;
        ids_eval_we    = 1'b0;
        ids_eval_re    = 1'b0;
        aes_sec_addr   = 32'h0;
        aes_sec_wdata  = 32'h0;
        aes_sec_we     = 1'b0;
        aes_sec_re     = 1'b0;
        canfd_soc_addr = 32'h0;
        canfd_soc_wdata = 32'h0;
        canfd_soc_mem_read = 1'b0;
        canfd_soc_mem_write = 1'b0;
    end

    task automatic apply_reset();
        begin
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (1) @(posedge clk);
        end
    endtask

    task automatic run_cycles(input int cycles);
        int i;
        begin
            for (i = 0; i < cycles; i++) begin
                @(posedge clk);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Encoders
    // -------------------------------------------------------------------------
    function automatic [31:0] enc_rtype(
        input [6:0] funct7,
        input [4:0] rs2,
        input [4:0] rs1,
        input [2:0] funct3,
        input [4:0] rd,
        input [6:0] opcode
    );
        enc_rtype = {funct7, rs2, rs1, funct3, rd, opcode};
    endfunction

    function automatic [31:0] enc_custom(
        input [2:0] cmd,
        input [4:0] rs2,
        input [4:0] rs1,
        input [4:0] rd
    );
        enc_custom = {7'b0000000, rs2, rs1, cmd, rd, 7'b0001011};
    endfunction

    function automatic [31:0] enc_itype(
        input signed [11:0] imm,
        input [4:0] rs1,
        input [2:0] funct3,
        input [4:0] rd,
        input [6:0] opcode
    );
        enc_itype = {imm[11:0], rs1, funct3, rd, opcode};
    endfunction

    function automatic [31:0] enc_stype(
        input signed [11:0] imm,
        input [4:0] rs2,
        input [4:0] rs1,
        input [2:0] funct3,
        input [6:0] opcode
    );
        enc_stype = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
    endfunction

    function automatic [31:0] enc_btype(
        input signed [12:0] imm,
        input [4:0] rs2,
        input [4:0] rs1,
        input [2:0] funct3,
        input [6:0] opcode
    );
        enc_btype = {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode};
    endfunction

    function automatic [31:0] enc_utype(
        input [19:0] imm20,
        input [4:0] rd,
        input [6:0] opcode
    );
        enc_utype = {imm20, rd, opcode};
    endfunction

    function automatic [31:0] enc_jtype(
        input signed [20:0] imm,
        input [4:0] rd,
        input [6:0] opcode
    );
        enc_jtype = {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
    endfunction

    // -------------------------------------------------------------------------
    // Test utilities
    // -------------------------------------------------------------------------
    task automatic clear_mem_and_regs();
        int i;
        begin
            // Fill instruction memory with NOP
            for (i = 0; i < 256; i++) begin
                dut.u_if_stage.u_instr_mem.rom[i] = 32'h00000013; // addi x0,x0,0
                dut.u_mem_stage.u_data_mem.ram[i] = 32'h0;
            end

            // Clear architectural register file
            for (i = 0; i < 32; i++) begin
                dut.u_id_stage.u_reg_file.regs[i] = 32'h0;
            end
        end
    endtask

    task automatic check_and_report(
        input string itype,
        input string mnemonic,
        input string op_text,
        input logic [31:0] got,
        input logic [31:0] exp
    );
        begin
            if (got !== exp) begin
                $display("[%s] %s: %s -> got=0x%08x expected=0x%08x -> FAIL", itype, mnemonic, op_text, got, exp);
                fail_count++;
            end else begin
                $display("[%s] %s: %s -> got=0x%08x expected=0x%08x -> PASS", itype, mnemonic, op_text, got, exp);
                pass_count++;
            end
        end
    endtask

    task automatic ids_eval_write(input logic [7:0] offset,
                                  input logic [31:0] value);
        begin
            @(negedge clk);
            ids_eval_addr  = 32'h0000_0900 + offset;
            ids_eval_wdata = value;
            ids_eval_we    = 1'b1;
            @(negedge clk);
            ids_eval_we    = 1'b0;
        end
    endtask

    task automatic ids_eval_set_frame(input logic [10:0] frame_id,
                                      input logic [3:0] frame_dlc,
                                      input logic [63:0] payload);
        begin
            ids_eval_write(8'h08, {21'h0, frame_id});
            ids_eval_write(8'h0C, {28'h0, frame_dlc});
            ids_eval_write(8'h10, payload[31:0]);
            ids_eval_write(8'h14, payload[63:32]);
        end
    endtask

    task automatic ids_eval_label_submit(input logic expected_attack,
                                         input logic [2:0] expected_class);
        begin
            // EVAL_LABEL[4] enables metrics, [3:1] carries the class and [0]
            // identifies attack versus normal ground truth.
            ids_eval_write(8'h4C, {27'h0, 1'b1, expected_class,
                                   expected_attack});
            ids_eval_write(8'h00, 32'h0000_0001);
        end
    endtask

    task automatic aes_sec_write(input logic [7:0] offset,
                                 input logic [31:0] value);
        begin
            @(negedge clk);
            aes_sec_addr  = 32'h0000_0300 + offset;
            aes_sec_wdata = value;
            aes_sec_we    = 1'b1;
            @(negedge clk);
            aes_sec_we    = 1'b0;
        end
    endtask

    task automatic aes_sec_read(input logic [7:0] offset,
                                output logic [31:0] value);
        begin
            @(negedge clk);
            aes_sec_addr = 32'h0000_0300 + offset;
            aes_sec_re   = 1'b1;
            #1 value = aes_sec_rdata;
            @(negedge clk);
            aes_sec_re   = 1'b0;
        end
    endtask

    task automatic canfd_soc_write(input logic [31:0] address,
                                   input logic [31:0] value);
        begin
            @(negedge clk);
            canfd_soc_addr = address;
            canfd_soc_wdata = value;
            canfd_soc_mem_write = 1'b1;
            canfd_soc_mem_read = 1'b0;
            @(negedge clk);
            canfd_soc_mem_write = 1'b0;
            canfd_soc_addr = 32'h0;
            canfd_soc_wdata = 32'h0;
        end
    endtask

    task automatic canfd_soc_read(input logic [31:0] address,
                                  output logic [31:0] value);
        begin
            @(negedge clk);
            canfd_soc_addr = address;
            canfd_soc_mem_write = 1'b0;
            canfd_soc_mem_read = 1'b1;
            #1 value = canfd_soc_rdata;
            @(negedge clk);
            canfd_soc_mem_read = 1'b0;
            canfd_soc_addr = 32'h0;
        end
    endtask

    task automatic check_seen(
        input string signal_name,
        input int seen_count
    );
        begin
            if (seen_count <= 0) begin
                $display("[SIGNAL] %s: expected at least one assertion -> count=%0d -> FAIL", signal_name, seen_count);
                fail_count++;
            end else begin
                $display("[SIGNAL] %s: observed assertion count=%0d -> PASS", signal_name, seen_count);
                pass_count++;
            end
        end
    endtask

    task automatic reset_activity_counters();
        begin
            if_stall_seen_count = 0;
            if_flush_seen_count = 0;
            aes_sel_seen_count = 0;
            aes_write_seen_count = 0;
            aes_read_seen_count = 0;
            uart_done_seen_count = 0;
            irq_seen_count = 0;
            spi_sclk_toggle_count = 0;
            spi_sclk_prev = spi_sclk_tb;
        end
    endtask

    function automatic [7:0] hex_ascii(input logic [3:0] value);
        begin
            hex_ascii = (value < 4'd10) ? (8'h30 + {4'h0, value}) : (8'h41 + ({4'h0, value} - 8'd10));
        end
    endfunction

    task automatic aes_ctr_encrypt_direct(
        input  logic [127:0] key,
        input  logic [127:0] plaintext,
        input  logic [63:0]  nonce,
        input  logic [63:0]  counter,
        output logic [127:0] ciphertext
    );
        int timeout;
        begin
            dut.u_mem_stage.u_aes_mmio.key_reg      = key;
            dut.u_mem_stage.u_aes_mmio.pt_reg       = plaintext;
            dut.u_mem_stage.u_aes_mmio.nonce_reg    = nonce;
            dut.u_mem_stage.u_aes_mmio.counter_reg  = counter;
            dut.u_mem_stage.u_aes_mmio.mode_ctr_reg = 1'b1;

            @(negedge clk);
            dut.u_mem_stage.u_aes_mmio.aes_start_pulse = 1'b1;
            dut.u_mem_stage.u_aes_mmio.busy_reg        = 1'b1;
            dut.u_mem_stage.u_aes_mmio.done_reg        = 1'b0;
            @(negedge clk);
            dut.u_mem_stage.u_aes_mmio.aes_start_pulse = 1'b0;

            timeout = 0;
            while ((dut.u_mem_stage.u_aes_mmio.done_reg !== 1'b1) && (timeout < 500)) begin
                @(posedge clk);
                timeout++;
            end
            ciphertext = dut.u_mem_stage.u_aes_mmio.ct_reg;
        end
    endtask

    task automatic uart_send_byte_direct(input logic [7:0] value);
        int timeout;
        begin
            while (dut.u_mem_stage.u_uart_mmio.tx_busy_o) begin
                @(posedge clk);
            end

            @(negedge clk);
            dut.u_mem_stage.u_uart_mmio.tx_data_reg      = value;
            dut.u_mem_stage.u_uart_mmio.tx_start_pulse   = 1'b1;
            dut.u_mem_stage.u_uart_mmio.done_latched     = 1'b0;
            dut.u_mem_stage.u_uart_mmio.enable_reg       = 1'b1;
            dut.u_mem_stage.u_uart_mmio.baud_div_reg     = 16'd1;
            @(negedge clk);
            dut.u_mem_stage.u_uart_mmio.tx_start_pulse   = 1'b0;

            timeout = 0;
            while ((dut.u_mem_stage.u_uart_mmio.done_latched !== 1'b1) && (timeout < 80)) begin
                @(posedge clk);
                timeout++;
            end
            $write("%c", value);
        end
    endtask

    task automatic uart_print_string(input string msg);
        int i;
        begin
            for (i = 0; i < msg.len(); i++) begin
                uart_send_byte_direct(msg[i]);
            end
        end
    endtask

    task automatic uart_print_hex128(input logic [127:0] value);
        int nib;
        begin
            for (nib = 31; nib >= 0; nib--) begin
                uart_send_byte_direct(hex_ascii(value[nib*4 +: 4]));
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // R-type group (10 instructions)
    // -------------------------------------------------------------------------
    task automatic run_rtype_tests();
        begin
            $display("\n=== R-type tests ===");
            clear_mem_and_regs();

            // Input setup: x1=20, x2=6
            dut.u_if_stage.u_instr_mem.rom[0]  = enc_itype(12'd20, 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[1]  = enc_itype(12'd6,  5'd0, 3'b000, 5'd2, 7'b0010011);

            // RV32I R-type operations
            dut.u_if_stage.u_instr_mem.rom[2]  = enc_rtype(7'b0000000,5'd2,5'd1,3'b000,5'd3, 7'b0110011); // ADD
            dut.u_if_stage.u_instr_mem.rom[3]  = enc_rtype(7'b0100000,5'd2,5'd1,3'b000,5'd4, 7'b0110011); // SUB
            dut.u_if_stage.u_instr_mem.rom[4]  = enc_rtype(7'b0000000,5'd2,5'd1,3'b001,5'd5, 7'b0110011); // SLL
            dut.u_if_stage.u_instr_mem.rom[5]  = enc_rtype(7'b0000000,5'd1,5'd2,3'b010,5'd6, 7'b0110011); // SLT
            dut.u_if_stage.u_instr_mem.rom[6]  = enc_rtype(7'b0000000,5'd1,5'd2,3'b011,5'd7, 7'b0110011); // SLTU
            dut.u_if_stage.u_instr_mem.rom[7]  = enc_rtype(7'b0000000,5'd2,5'd1,3'b100,5'd8, 7'b0110011); // XOR
            dut.u_if_stage.u_instr_mem.rom[8]  = enc_rtype(7'b0000000,5'd2,5'd1,3'b101,5'd9, 7'b0110011); // SRL
            dut.u_if_stage.u_instr_mem.rom[9]  = enc_rtype(7'b0100000,5'd2,5'd1,3'b101,5'd10,7'b0110011); // SRA
            dut.u_if_stage.u_instr_mem.rom[10] = enc_rtype(7'b0000000,5'd2,5'd1,3'b110,5'd11,7'b0110011); // OR
            dut.u_if_stage.u_instr_mem.rom[11] = enc_rtype(7'b0000000,5'd2,5'd1,3'b111,5'd12,7'b0110011); // AND

            apply_reset();
            run_cycles(30);

            check_and_report("R-TYPE", "ADD",  "x3 = x1 + x2; 20 + 6 = 26",        dut.u_id_stage.u_reg_file.regs[3],  32'd26);
            check_and_report("R-TYPE", "SUB",  "x4 = x1 - x2; 20 - 6 = 14",        dut.u_id_stage.u_reg_file.regs[4],  32'd14);
            check_and_report("R-TYPE", "SLL",  "x5 = x1 << x2[4:0]; 20 << 6 = 1280",dut.u_id_stage.u_reg_file.regs[5],  32'd1280);
            check_and_report("R-TYPE", "SLT",  "x6 = (x2 < x1) signed; 6<20 => 1", dut.u_id_stage.u_reg_file.regs[6],  32'd1);
            check_and_report("R-TYPE", "SLTU", "x7 = (x2 < x1) unsigned; 6<20 =>1",dut.u_id_stage.u_reg_file.regs[7],  32'd1);
            check_and_report("R-TYPE", "XOR",  "x8 = x1 ^ x2; 0x14 ^ 0x06 = 0x12", dut.u_id_stage.u_reg_file.regs[8],  32'h12);
            check_and_report("R-TYPE", "SRL",  "x9 = x1 >> x2[4:0]; 20 >> 6 = 0",   dut.u_id_stage.u_reg_file.regs[9],  32'd0);
            check_and_report("R-TYPE", "SRA",  "x10 = x1 >>> x2[4:0]; 20>>>6 = 0",  dut.u_id_stage.u_reg_file.regs[10], 32'd0);
            check_and_report("R-TYPE", "OR",   "x11 = x1 | x2; 0x14 | 0x06 = 0x16",dut.u_id_stage.u_reg_file.regs[11], 32'h16);
            check_and_report("R-TYPE", "AND",  "x12 = x1 & x2; 0x14 & 0x06 = 0x04",dut.u_id_stage.u_reg_file.regs[12], 32'h04);
        end
    endtask

    // -------------------------------------------------------------------------
    // I-type ALU/immediate group (9 instructions)
    // -------------------------------------------------------------------------
    task automatic run_itype_tests();
        begin
            $display("\n=== I-type tests ===");
            clear_mem_and_regs();

            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'd9, 5'd0, 3'b000, 5'd1, 7'b0010011); // ADDI base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'd7, 5'd1, 3'b010, 5'd2, 7'b0010011); // SLTI
            dut.u_if_stage.u_instr_mem.rom[2] = enc_itype(12'd7, 5'd1, 3'b011, 5'd3, 7'b0010011); // SLTIU
            dut.u_if_stage.u_instr_mem.rom[3] = enc_itype(12'h0F0,5'd1, 3'b100, 5'd4, 7'b0010011); // XORI
            dut.u_if_stage.u_instr_mem.rom[4] = enc_itype(12'h003,5'd1, 3'b110, 5'd5, 7'b0010011); // ORI
            dut.u_if_stage.u_instr_mem.rom[5] = enc_itype(12'h003,5'd1, 3'b111, 5'd6, 7'b0010011); // ANDI
            dut.u_if_stage.u_instr_mem.rom[6] = enc_itype(12'b000000000010,5'd1,3'b001,5'd7,7'b0010011); // SLLI
            dut.u_if_stage.u_instr_mem.rom[7] = enc_itype(12'b000000000001,5'd1,3'b101,5'd8,7'b0010011); // SRLI
            dut.u_if_stage.u_instr_mem.rom[8] = enc_itype(12'b010000000001,5'd1,3'b101,5'd9,7'b0010011); // SRAI

            apply_reset();
            run_cycles(25);

            check_and_report("I-TYPE", "ADDI",  "x1 = x0 + 9; 0 + 9 = 9",            dut.u_id_stage.u_reg_file.regs[1], 32'd9);
            check_and_report("I-TYPE", "SLTI",  "x2 = (x1 < 7) signed; 9<7 => 0",     dut.u_id_stage.u_reg_file.regs[2], 32'd0);
            check_and_report("I-TYPE", "SLTIU", "x3 = (x1 < 7) unsigned; 9<7 => 0",   dut.u_id_stage.u_reg_file.regs[3], 32'd0);
            check_and_report("I-TYPE", "XORI",  "x4 = x1 ^ 0xF0; 0x09^0xF0 = 0xF9",   dut.u_id_stage.u_reg_file.regs[4], 32'hF9);
            check_and_report("I-TYPE", "ORI",   "x5 = x1 | 0x3; 0x09|0x03 = 0x0B",    dut.u_id_stage.u_reg_file.regs[5], 32'h0B);
            check_and_report("I-TYPE", "ANDI",  "x6 = x1 & 0x3; 0x09&0x03 = 0x01",    dut.u_id_stage.u_reg_file.regs[6], 32'h01);
            check_and_report("I-TYPE", "SLLI",  "x7 = x1 << 2; 9 << 2 = 36",          dut.u_id_stage.u_reg_file.regs[7], 32'd36);
            check_and_report("I-TYPE", "SRLI",  "x8 = x1 >> 1; 9 >> 1 = 4",           dut.u_id_stage.u_reg_file.regs[8], 32'd4);
            check_and_report("I-TYPE", "SRAI",  "x9 = x1 >>> 1; 9 >>> 1 = 4",         dut.u_id_stage.u_reg_file.regs[9], 32'd4);
        end
    endtask

    // -------------------------------------------------------------------------
    // Load/Store group
    // 5 loads + 3 stores = 8 instructions
    // -------------------------------------------------------------------------
    task automatic run_load_store_tests();
        begin
            $display("\n=== S-type/I-type load-store tests ===");
            clear_mem_and_regs();

            // x1 = base address 0, x7 = store data 0x55
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'd0,  5'd0,3'b000,5'd1,7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'h55, 5'd0,3'b000,5'd7,7'b0010011);

            // Loads
            dut.u_if_stage.u_instr_mem.rom[2] = enc_itype(12'd0,5'd1,3'b000,5'd2,7'b0000011); // LB
            dut.u_if_stage.u_instr_mem.rom[3] = enc_itype(12'd0,5'd1,3'b001,5'd3,7'b0000011); // LH
            dut.u_if_stage.u_instr_mem.rom[4] = enc_itype(12'd0,5'd1,3'b010,5'd4,7'b0000011); // LW
            dut.u_if_stage.u_instr_mem.rom[5] = enc_itype(12'd0,5'd1,3'b100,5'd5,7'b0000011); // LBU
            dut.u_if_stage.u_instr_mem.rom[6] = enc_itype(12'd0,5'd1,3'b101,5'd6,7'b0000011); // LHU

            // Stores to addresses 4,8,12 (RAM[1], RAM[2], RAM[3])
            dut.u_if_stage.u_instr_mem.rom[7] = enc_stype(12'd4, 5'd7,5'd1,3'b000,7'b0100011); // SB
            dut.u_if_stage.u_instr_mem.rom[8] = enc_stype(12'd8, 5'd7,5'd1,3'b001,7'b0100011); // SH
            dut.u_if_stage.u_instr_mem.rom[9] = enc_stype(12'd12,5'd7,5'd1,3'b010,7'b0100011); // SW

            apply_reset();

            // Data pattern at RAM[0]; preload after reset because data_mem clears RAM.
            dut.u_mem_stage.u_data_mem.ram[0] = 32'hAABBCCDD;

            run_cycles(40);

            check_and_report("I-TYPE", "LB",  "x2 = signext(mem8[0]);  0xDD -> 0xFFFFFFDD",  dut.u_id_stage.u_reg_file.regs[2], 32'hFFFFFFDD);
            check_and_report("I-TYPE", "LH",  "x3 = signext(mem16[0]); 0xCCDD -> 0xFFFFCCDD",dut.u_id_stage.u_reg_file.regs[3], 32'hFFFFCCDD);
            check_and_report("I-TYPE", "LW",  "x4 = mem32[0]; 0xAABBCCDD",                     dut.u_id_stage.u_reg_file.regs[4], 32'hAABBCCDD);
            check_and_report("I-TYPE", "LBU", "x5 = zeroext(mem8[0]); 0xDD -> 0x000000DD",     dut.u_id_stage.u_reg_file.regs[5], 32'h000000DD);
            check_and_report("I-TYPE", "LHU", "x6 = zeroext(mem16[0]);0xCCDD->0x0000CCDD",     dut.u_id_stage.u_reg_file.regs[6], 32'h0000CCDD);

            check_and_report("S-TYPE", "SB",  "mem8 [4]  = x7[7:0];  0x55",                    dut.u_mem_stage.u_data_mem.ram[1], 32'h00000055);
            check_and_report("S-TYPE", "SH",  "mem16[8]  = x7[15:0]; 0x0055",                  dut.u_mem_stage.u_data_mem.ram[2], 32'h00000055);
            check_and_report("S-TYPE", "SW",  "mem32[12] = x7;       0x00000055",              dut.u_mem_stage.u_data_mem.ram[3], 32'h00000055);
        end
    endtask

    // -------------------------------------------------------------------------
    // B-type branch group (6 instructions)
    // -------------------------------------------------------------------------
    task automatic run_branch_tests();
        begin
            $display("\n=== B-type tests ===");
            clear_mem_and_regs();

            dut.u_if_stage.u_instr_mem.rom[0]  = enc_itype(12'd1,5'd0,3'b000,5'd1,7'b0010011); // x1=1
            dut.u_if_stage.u_instr_mem.rom[1]  = enc_itype(12'd2,5'd0,3'b000,5'd2,7'b0010011); // x2=2

            dut.u_if_stage.u_instr_mem.rom[2]  = enc_btype(13'd8,5'd2,5'd1,3'b000,7'b1100011); // BEQ (not taken)
            dut.u_if_stage.u_instr_mem.rom[3]  = enc_itype(12'd1,5'd0,3'b000,5'd20,7'b0010011);

            dut.u_if_stage.u_instr_mem.rom[4]  = enc_btype(13'd8,5'd2,5'd1,3'b001,7'b1100011); // BNE (taken)
            dut.u_if_stage.u_instr_mem.rom[5]  = enc_itype(12'd1,5'd0,3'b000,5'd21,7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[6]  = enc_itype(12'd1,5'd0,3'b000,5'd22,7'b0010011);

            dut.u_if_stage.u_instr_mem.rom[7]  = enc_btype(13'd8,5'd2,5'd1,3'b100,7'b1100011); // BLT (taken)
            dut.u_if_stage.u_instr_mem.rom[8]  = enc_itype(12'd1,5'd0,3'b000,5'd23,7'b0010011);

            dut.u_if_stage.u_instr_mem.rom[9]  = enc_btype(13'd8,5'd2,5'd1,3'b101,7'b1100011); // BGE (not taken)
            dut.u_if_stage.u_instr_mem.rom[10] = enc_itype(12'd1,5'd0,3'b000,5'd24,7'b0010011);

            dut.u_if_stage.u_instr_mem.rom[11] = enc_btype(13'd8,5'd2,5'd1,3'b110,7'b1100011); // BLTU (taken)
            dut.u_if_stage.u_instr_mem.rom[12] = enc_itype(12'd1,5'd0,3'b000,5'd25,7'b0010011);

            dut.u_if_stage.u_instr_mem.rom[13] = enc_btype(13'd8,5'd2,5'd1,3'b111,7'b1100011); // BGEU (not taken)
            dut.u_if_stage.u_instr_mem.rom[14] = enc_itype(12'd1,5'd0,3'b000,5'd26,7'b0010011);

            apply_reset();
            run_cycles(55);

            check_and_report("B-TYPE", "BEQ",  "x1==x2? 1==2 false -> fall-through", dut.u_id_stage.u_reg_file.regs[20], 32'd1);
            check_and_report("B-TYPE", "BNE",  "x1!=x2? 1!=2 true  -> branch",       dut.u_id_stage.u_reg_file.regs[21], 32'd0);
            check_and_report("B-TYPE", "BLT",  "x1<x2 signed? 1<2 true -> branch",    dut.u_id_stage.u_reg_file.regs[23], 32'd0);
            check_and_report("B-TYPE", "BGE",  "x1>=x2 signed? 1>=2 false",           dut.u_id_stage.u_reg_file.regs[24], 32'd1);
            check_and_report("B-TYPE", "BLTU", "x1<x2 unsigned? 1<2 true -> branch",   dut.u_id_stage.u_reg_file.regs[25], 32'd0);
            check_and_report("B-TYPE", "BGEU", "x1>=x2 unsigned? 1>=2 false",         dut.u_id_stage.u_reg_file.regs[26], 32'd1);
        end
    endtask

    // -------------------------------------------------------------------------
    // U-type/J-type group
    // U: LUI, AUIPC (2)
    // J: JAL, JALR (2)
    // -------------------------------------------------------------------------
    task automatic run_u_jtype_tests();
        begin
            $display("\n=== U-type and J-type tests ===");
            clear_mem_and_regs();

            dut.u_if_stage.u_instr_mem.rom[0]  = enc_utype(20'h12345,5'd1,7'b0110111); // LUI
            dut.u_if_stage.u_instr_mem.rom[1]  = enc_utype(20'h00010,5'd2,7'b0010111); // AUIPC

            dut.u_if_stage.u_instr_mem.rom[2]  = enc_jtype(21'd8,5'd3,7'b1101111);      // JAL x3,+8
            dut.u_if_stage.u_instr_mem.rom[3]  = enc_itype(12'd1,5'd0,3'b000,5'd4,7'b0010011); // skipped
            dut.u_if_stage.u_instr_mem.rom[4]  = enc_itype(12'd2,5'd0,3'b000,5'd5,7'b0010011); // target

            dut.u_if_stage.u_instr_mem.rom[5]  = enc_itype(12'd32,5'd0,3'b000,5'd6,7'b1100111); // JALR x6,32(x0)
            dut.u_if_stage.u_instr_mem.rom[6]  = enc_itype(12'd99,5'd0,3'b000,5'd7,7'b0010011); // skipped
            dut.u_if_stage.u_instr_mem.rom[7]  = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[8]  = enc_itype(12'd7,5'd0,3'b000,5'd29,7'b0010011); // landing pad

            apply_reset();
            run_cycles(60);

            check_and_report("U-TYPE", "LUI",   "x1 = 0x12345 << 12 = 0x12345000", dut.u_id_stage.u_reg_file.regs[1], 32'h12345000);
            check_and_report("U-TYPE", "AUIPC", "x2 = PC(0x4) + 0x00010<<12 = 0x00010004", dut.u_id_stage.u_reg_file.regs[2], 32'h00010004);
            check_and_report("J-TYPE", "JAL",   "x3 = return addr (PC+4) = 12",      dut.u_id_stage.u_reg_file.regs[3], 32'd12);
            check_and_report("J-TYPE", "JALR",  "x6 = return addr (PC+4) = 24",      dut.u_id_stage.u_reg_file.regs[6], 32'd24);
        end
    endtask

    // -------------------------------------------------------------------------
    // SYSTEM / FENCE / PSEUDO group
    // 2 + 2 + 6 = 10 instructions
    // -------------------------------------------------------------------------
    task automatic run_system_fence_pseudo_tests();
        begin
            $display("\n=== SYSTEM/FENCE/PSEUDO tests ===");
            clear_mem_and_regs();

            // Sentinel values to verify no destructive side effects
            dut.u_if_stage.u_instr_mem.rom[0]  = enc_itype(12'd7,5'd0,3'b000,5'd29,7'b0010011); // x29=7
            dut.u_if_stage.u_instr_mem.rom[1]  = enc_itype(12'd5,5'd0,3'b000,5'd31,7'b0010011); // x31=5

            // SYSTEM
            dut.u_if_stage.u_instr_mem.rom[2]  = 32'h00000073; // ECALL
            dut.u_if_stage.u_instr_mem.rom[3]  = 32'h00100073; // EBREAK

            // FENCE
            dut.u_if_stage.u_instr_mem.rom[4]  = 32'h0000000F; // FENCE
            dut.u_if_stage.u_instr_mem.rom[5]  = 32'h0000100F; // FENCE.I

            // Pseudo instruction forms
            dut.u_if_stage.u_instr_mem.rom[6]  = enc_itype(12'd0,5'd0,3'b000,5'd0,7'b0010011); // NOP
            dut.u_if_stage.u_instr_mem.rom[7]  = enc_itype(12'd2,5'd0,3'b000,5'd5,7'b0010011); // seed x5=2
            dut.u_if_stage.u_instr_mem.rom[8]  = enc_itype(12'd0,5'd5,3'b000,5'd8,7'b0010011); // MV x8,x5
            dut.u_if_stage.u_instr_mem.rom[8]  = enc_itype(12'd0,5'd5,3'b000,5'd8,7'b0010011); // MV x8,x5
            dut.u_if_stage.u_instr_mem.rom[9]  = enc_itype(12'd9,5'd0,3'b000,5'd9,7'b0010011); // LI x9,9
            dut.u_if_stage.u_instr_mem.rom[10] = enc_jtype(21'd8,5'd0,7'b1101111);             // J +8
            dut.u_if_stage.u_instr_mem.rom[11] = enc_itype(12'd1,5'd0,3'b000,5'd27,7'b0010011); // skipped
            dut.u_if_stage.u_instr_mem.rom[12] = enc_itype(12'd1,5'd0,3'b000,5'd28,7'b0010011); // target
            dut.u_if_stage.u_instr_mem.rom[13] = enc_itype(12'd0,5'd0,3'b000,5'd10,7'b0010011); // ADDI x10,x0,0
            dut.u_if_stage.u_instr_mem.rom[14] = enc_itype(12'd0,5'd10,3'b000,5'd11,7'b0010011); // ADDI x11,x10,0 (NOP-like)

            apply_reset();
            run_cycles(65);

            check_and_report("SYSTEM", "ECALL",  "environment call; sentinel x29 remains 7", dut.u_id_stage.u_reg_file.regs[29], 32'd7);
            check_and_report("SYSTEM", "EBREAK", "breakpoint; sentinel x29 remains 7",       dut.u_id_stage.u_reg_file.regs[29], 32'd7);
            check_and_report("FENCE",  "FENCE",  "memory ordering barrier; sentinel x31=5",   dut.u_id_stage.u_reg_file.regs[31], 32'd5);
            check_and_report("FENCE",  "FENCE.I","instruction barrier; sentinel x31=5",       dut.u_id_stage.u_reg_file.regs[31], 32'd5);

            check_and_report("I-TYPE", "NOP",    "addi x0,x0,0 leaves x0=0",                 dut.u_id_stage.u_reg_file.regs[0],  32'd0);
            check_and_report("I-TYPE", "MV",     "x8 = x5 + 0; 2 -> 2",                       dut.u_id_stage.u_reg_file.regs[8],  32'd2);
            check_and_report("I-TYPE", "LI",     "x9 = 9",                                    dut.u_id_stage.u_reg_file.regs[9],  32'd9);
            check_and_report("J-TYPE", "J",      "jump skips x27 write; x27 stays 0",         dut.u_id_stage.u_reg_file.regs[27], 32'd0);
            check_and_report("J-TYPE", "J",      "jump target executes x28=1",                dut.u_id_stage.u_reg_file.regs[28], 32'd1);
            check_and_report("I-TYPE", "NOP2",   "addi x11,x10,0 with x10=0 -> x11=0",        dut.u_id_stage.u_reg_file.regs[11], 32'd0);
        end
    endtask



    // -------------------------------------------------------------------------
    // AES-128 MMIO NIST test vector
    // NIST SP 800-38A F.1 ECB-AES128:
    //   KEY = 000102030405060708090A0B0C0D0E0F
    //   PT  = 00112233445566778899AABBCCDDEEFF
    //   CT  = 69C4E0D86A7B0430D8CDB78070B4C55A
    // -------------------------------------------------------------------------
    task automatic run_aes_nist_tests();
        int timeout;
        begin
            $display("\n=== AES-128 NIST MMIO tests ===");

            clear_mem_and_regs();
            apply_reset();

            // Program key words (little-endian word map into [127:0])
            dut.u_mem_stage.u_aes_mmio.key_reg[31:0]    = 32'h0C0D0E0F; // KEY0
            dut.u_mem_stage.u_aes_mmio.key_reg[63:32]   = 32'h08090A0B; // KEY1
            dut.u_mem_stage.u_aes_mmio.key_reg[95:64]   = 32'h04050607; // KEY2
            dut.u_mem_stage.u_aes_mmio.key_reg[127:96]  = 32'h00010203; // KEY3

            // Program plaintext words
            dut.u_mem_stage.u_aes_mmio.pt_reg[31:0]     = 32'hCCDDEEFF; // PT0
            dut.u_mem_stage.u_aes_mmio.pt_reg[63:32]    = 32'h8899AABB; // PT1
            dut.u_mem_stage.u_aes_mmio.pt_reg[95:64]    = 32'h44556677; // PT2
            dut.u_mem_stage.u_aes_mmio.pt_reg[127:96]   = 32'h00112233; // PT3

            // Start pulse through control path equivalent
            @(negedge clk);
            dut.u_mem_stage.u_aes_mmio.aes_start_pulse = 1'b1;
            dut.u_mem_stage.u_aes_mmio.busy_reg        = 1'b1;
            dut.u_mem_stage.u_aes_mmio.done_reg        = 1'b0;
            @(negedge clk);
            dut.u_mem_stage.u_aes_mmio.aes_start_pulse = 1'b0;

            // Wait for the sequential reusable AES core to finish.
            timeout = 0;
            while ((dut.u_mem_stage.u_aes_mmio.done_reg !== 1'b1) && (timeout < 500)) begin
                @(posedge clk);
                timeout++;
            end

            check_and_report("AES", "DONE",   "iterative reusable AES completed", {31'h0, dut.u_mem_stage.u_aes_mmio.done_reg}, 32'h1);
            check_and_report("AES", "BUSY",   "busy deasserted after completion", {31'h0, dut.u_mem_stage.u_aes_mmio.busy_reg}, 32'h0);

            // Check ciphertext against NIST expected vector
            check_and_report("AES", "CT0", "ciphertext[31:0]",    dut.u_mem_stage.u_aes_mmio.ct_reg[31:0],    32'h70B4C55A);
            check_and_report("AES", "CT1", "ciphertext[63:32]",   dut.u_mem_stage.u_aes_mmio.ct_reg[63:32],   32'hD8CDB780);
            check_and_report("AES", "CT2", "ciphertext[95:64]",   dut.u_mem_stage.u_aes_mmio.ct_reg[95:64],   32'h6A7B0430);
            check_and_report("AES", "CT3", "ciphertext[127:96]",  dut.u_mem_stage.u_aes_mmio.ct_reg[127:96],  32'h69C4E0D8);
        end
    endtask

    // -------------------------------------------------------------------------
    // AES-CTR wrapper test. Plaintext is zero, so ciphertext equals
    // AES_encrypt(nonce || counter). The block below reuses the NIST AES input
    // as the CTR counter block.
    // -------------------------------------------------------------------------
    task automatic run_aes_ctr_tests();
        int timeout;
        begin
            $display("\n=== AES-CTR tests ===");

            clear_mem_and_regs();
            apply_reset();

            dut.u_mem_stage.u_aes_mmio.key_reg[31:0]    = 32'h0C0D0E0F;
            dut.u_mem_stage.u_aes_mmio.key_reg[63:32]   = 32'h08090A0B;
            dut.u_mem_stage.u_aes_mmio.key_reg[95:64]   = 32'h04050607;
            dut.u_mem_stage.u_aes_mmio.key_reg[127:96]  = 32'h00010203;

            dut.u_mem_stage.u_aes_mmio.pt_reg           = 128'h0;
            dut.u_mem_stage.u_aes_mmio.nonce_reg        = 64'h0011223344556677;
            dut.u_mem_stage.u_aes_mmio.counter_reg      = 64'h8899AABBCCDDEEFF;
            dut.u_mem_stage.u_aes_mmio.mode_ctr_reg     = 1'b1;

            @(negedge clk);
            dut.u_mem_stage.u_aes_mmio.aes_start_pulse = 1'b1;
            dut.u_mem_stage.u_aes_mmio.busy_reg        = 1'b1;
            dut.u_mem_stage.u_aes_mmio.done_reg        = 1'b0;
            @(negedge clk);
            dut.u_mem_stage.u_aes_mmio.aes_start_pulse = 1'b0;

            timeout = 0;
            while ((dut.u_mem_stage.u_aes_mmio.done_reg !== 1'b1) && (timeout < 500)) begin
                @(posedge clk);
                timeout++;
            end

            check_and_report("AES-CTR", "DONE", "iterative reusable AES completed", {31'h0, dut.u_mem_stage.u_aes_mmio.done_reg}, 32'h1);
            check_and_report("AES-CTR", "CT0",  "zero plaintext XOR keystream[31:0]",   dut.u_mem_stage.u_aes_mmio.ct_reg[31:0],   32'h70B4C55A);
            check_and_report("AES-CTR", "CT1",  "zero plaintext XOR keystream[63:32]",  dut.u_mem_stage.u_aes_mmio.ct_reg[63:32],  32'hD8CDB780);
            check_and_report("AES-CTR", "CT2",  "zero plaintext XOR keystream[95:64]",  dut.u_mem_stage.u_aes_mmio.ct_reg[95:64],  32'h6A7B0430);
            check_and_report("AES-CTR", "CT3",  "zero plaintext XOR keystream[127:96]", dut.u_mem_stage.u_aes_mmio.ct_reg[127:96], 32'h69C4E0D8);
            check_and_report("AES-CTR", "COUNT","counter auto-incremented", dut.u_mem_stage.u_aes_mmio.counter_reg[31:0], 32'hCCDDEF00);
        end
    endtask

    // -------------------------------------------------------------------------
    // IoT SoC peripheral tests
    // -------------------------------------------------------------------------
    task automatic run_sensor_mmio_tests();
        begin
            $display("\n=== Sensor MMIO tests ===");
            clear_mem_and_regs();
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h400, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = sensor base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'd0,   5'd1, 3'b010, 5'd2, 7'b0000011); // LW x2,DATA
            dut.u_if_stage.u_instr_mem.rom[2] = enc_itype(12'd4,   5'd1, 3'b010, 5'd3, 7'b0000011); // LW x3,STATUS
            apply_reset();
            run_cycles(20);

            check_and_report("SENSOR", "DATA",   "sensor data read through MMIO", dut.u_id_stage.u_reg_file.regs[2], 32'h12345678);
            check_and_report("SENSOR", "STATUS", "status register is readable", dut.u_id_stage.u_reg_file.regs[3][0], 1'b0);
        end
    endtask

    task automatic run_sensor_spi_ip_tests();
        begin
            $display("\n=== Sensor SPI IP tests ===");
            clear_mem_and_regs();
            reset_activity_counters();

            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h400, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = sensor base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'h001, 5'd0, 3'b000, 5'd2, 7'b0010011); // x2 = slave-select bit
            dut.u_if_stage.u_instr_mem.rom[2] = enc_stype(12'd36,  5'd2, 5'd1, 3'b010, 7'b0100011); // SW x2,SPI_SLAVE_SELECT
            dut.u_if_stage.u_instr_mem.rom[3] = enc_itype(12'h400, 5'd0, 3'b000, 5'd2, 7'b0010011); // x2 = SSO control bit
            dut.u_if_stage.u_instr_mem.rom[4] = enc_stype(12'd28,  5'd2, 5'd1, 3'b010, 7'b0100011); // SW x2,SPI_CONTROL
            dut.u_if_stage.u_instr_mem.rom[5] = enc_itype(12'h05a, 5'd0, 3'b000, 5'd3, 7'b0010011); // x3 = test byte
            dut.u_if_stage.u_instr_mem.rom[6] = enc_stype(12'd20,  5'd3, 5'd1, 3'b010, 7'b0100011); // SW x3,SPI_TXDATA

            apply_reset();
            reset_activity_counters();
            run_cycles(900);

            check_and_report("SPI-IP", "SCLK", "Intel SPI IP generated serial clock activity", {31'h0, (spi_sclk_toggle_count > 0)}, 32'h1);
            check_and_report("SPI-IP", "SS_N", "slave select asserted by SPI control", {31'h0, spi_ss_n_tb}, 32'h0);
        end
    endtask

    task automatic run_uart_mmio_tests();
        begin
            $display("\n=== UART MMIO tests ===");
            clear_mem_and_regs();
            dut.u_mem_stage.u_uart_mmio.baud_div_reg = 16'd1;
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h500, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = UART base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'h05A, 5'd0, 3'b000, 5'd2, 7'b0010011); // x2 = 0x5A
            dut.u_if_stage.u_instr_mem.rom[2] = enc_stype(12'd0,   5'd2, 5'd1, 3'b010, 7'b0100011); // SW x2,TXDATA
            apply_reset();
            dut.u_mem_stage.u_uart_mmio.baud_div_reg = 16'd1;
            run_cycles(45);

            check_and_report("UART", "DONE", "TX done after MMIO write", {31'h0, dut.u_mem_stage.u_uart_mmio.done_latched}, 32'h1);
            check_and_report("UART", "BUSY", "TX no longer busy", {31'h0, dut.u_mem_stage.u_uart_mmio.tx_busy_o}, 32'h0);
        end
    endtask

    task automatic run_end_to_end_uart_aes_ctr_tests();
        logic [127:0] e2e_key;
        logic [127:0] e2e_plaintext;
        logic [127:0] e2e_ciphertext;
        logic [127:0] e2e_decrypted;
        logic [63:0]  e2e_nonce;
        logic [63:0]  e2e_counter;
        begin
            $display("\n=== End-to-end AES-CTR UART print/decrypt tests ===");
            clear_mem_and_regs();
            apply_reset();

            e2e_key       = 128'h000102030405060708090A0B0C0D0E0F;
            e2e_plaintext = 128'h4845414C54485F485237385F53393721; // "HEALTH_HR78_S97!"
            e2e_nonce     = 64'h0011223344556677;
            e2e_counter   = 64'h8899AABBCCDDEEFF;

            aes_ctr_encrypt_direct(e2e_key, e2e_plaintext, e2e_nonce, e2e_counter, e2e_ciphertext);
            check_and_report("E2E", "ENC_DONE", "AES-CTR encryption completed", {31'h0, dut.u_mem_stage.u_aes_mmio.done_reg}, 32'h1);
            check_and_report("E2E", "CT_DIFF",  "ciphertext differs from plaintext", (e2e_ciphertext != e2e_plaintext), 1'b1);

            // CTR decryption uses the same AES encryption primitive. Feed the
            // ciphertext as input with the same key, nonce, and counter.
            aes_ctr_encrypt_direct(e2e_key, e2e_ciphertext, e2e_nonce, e2e_counter, e2e_decrypted);
            check_and_report("E2E", "DEC_MATCH", "AES-CTR decrypted data matches original input", e2e_decrypted, e2e_plaintext);

            $display("UART transcript below is emitted through the RTL UART transmitter:");
            $write("UART_PRINT: ");
            uart_print_string("INPUT=");
            uart_print_hex128(e2e_plaintext);
            uart_print_string(" KEY=");
            uart_print_hex128(e2e_key);
            uart_print_string(" CIPHER=");
            uart_print_hex128(e2e_ciphertext);
            uart_print_string(" DECRYPTED=");
            uart_print_hex128(e2e_decrypted);
            uart_print_string((e2e_decrypted == e2e_plaintext) ? " MATCH=PASS\n" : " MATCH=FAIL\n");

            check_and_report("E2E", "UART_DONE", "UART completed final transcript byte", {31'h0, dut.u_mem_stage.u_uart_mmio.done_latched}, 32'h1);
        end
    endtask

    task automatic run_interrupt_tests();
        begin
            $display("\n=== Interrupt controller tests ===");
            clear_mem_and_regs();
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h600, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = INTC base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'h004, 5'd0, 3'b000, 5'd2, 7'b0010011); // enable sensor IRQ
            dut.u_if_stage.u_instr_mem.rom[2] = enc_stype(12'd4,   5'd2, 5'd1, 3'b010, 7'b0100011); // SW enable
            dut.u_if_stage.u_instr_mem.rom[3] = enc_itype(12'd0,   5'd1, 3'b010, 5'd3, 7'b0000011); // LW pending
            dut.u_if_stage.u_instr_mem.rom[4] = enc_stype(12'd8,   5'd2, 5'd1, 3'b010, 7'b0100011); // SW clear
            apply_reset();
            run_cycles(35);

            check_and_report("INTC", "PENDING", "sensor-ready pending bit observed", dut.u_id_stage.u_reg_file.regs[3] & 32'h4, 32'h4);
            check_and_report("INTC", "IRQ",     "combined irq line asserted when enabled", {31'h0, dut.irq_debug}, 32'h1);
        end
    endtask

    task automatic run_dma_lite_tests();
        begin
            $display("\n=== DMA-lite tests ===");
            clear_mem_and_regs();
            dut.u_mem_stage.u_data_mem.ram[4] = 32'hDEADBEEF;
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h700, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = DMA base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'd16,  5'd0, 3'b000, 5'd2, 7'b0010011); // src
            dut.u_if_stage.u_instr_mem.rom[2] = enc_stype(12'd0,   5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[3] = enc_itype(12'd20,  5'd0, 3'b000, 5'd2, 7'b0010011); // dst
            dut.u_if_stage.u_instr_mem.rom[4] = enc_stype(12'd4,   5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[5] = enc_itype(12'd1,   5'd0, 3'b000, 5'd2, 7'b0010011); // len/start
            dut.u_if_stage.u_instr_mem.rom[6] = enc_stype(12'd8,   5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[7] = enc_stype(12'd12,  5'd2, 5'd1, 3'b010, 7'b0100011);
            apply_reset();
            dut.u_mem_stage.u_data_mem.ram[4] = 32'hDEADBEEF;
            run_cycles(45);

            check_and_report("DMA", "COPY", "ram[4] copied to ram[5]", dut.u_mem_stage.u_data_mem.ram[5], 32'hDEADBEEF);
            check_and_report("DMA", "DONE", "done flag asserted", {31'h0, dut.u_mem_stage.u_dma_lite.done_o}, 32'h1);
        end
    endtask

    // -------------------------------------------------------------------------
    // Automotive CAN-IDS MMIO tests
    //
    // One real CPU program submits four complete frame descriptors through the
    // 0x900 MMIO page: normal engine/sensor traffic followed by the documented
    // DoS, fuzzy, and spoofing signatures. Results are read back through LW.
    // -------------------------------------------------------------------------
    task automatic run_can_ids_tests();
        int p;
        begin
            $display("\n=== Automotive CAN-IDS MMIO tests ===");
            clear_mem_and_regs();
            p = 0;

            // x1 = 0x900. ADDI cannot directly create positive 0x900 because
            // its 12-bit immediate is signed, so construct it as 0x7FF+0x101.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h7ff, 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h101, 5'd1, 3'b000, 5'd1, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h600, 5'd0, 3'b000, 5'd3, 7'b0010011); // x3 = INTC base
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd16,  5'd0, 3'b000, 5'd7, 7'b0010011); // bit 4 = IDS IRQ
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd4,   5'd7, 5'd3, 3'b010, 7'b0100011); // IRQ_ENABLE=0x10

            // All four test frames use classic-CAN DLC 8.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd8, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h0c, 5'd2, 5'd1, 3'b010, 7'b0100011); // FRAME_DLC

            // Normal frame: allowed sensor ID 0x145 with a non-signature payload.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h145, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h08, 5'd2, 5'd1, 3'b010, 7'b0100011); // FRAME_ID
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h123, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h10, 5'd2, 5'd1, 3'b010, 7'b0100011); // DATA_LO
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h14, 5'd0, 5'd1, 3'b010, 7'b0100011); // DATA_HI=0
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h00, 5'd2, 5'd1, 3'b010, 7'b0100011); // CTRL.submit
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h04, 5'd1, 3'b010, 5'd10, 7'b0000011); // normal STATUS
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;

            // DoS frame: highest-priority ID 0x000 and all-zero 8-byte payload.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h08, 5'd0, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h10, 5'd0, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h14, 5'd0, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h00, 5'd2, 5'd1, 3'b010, 7'b0100011); // submit with x2=1
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h04, 5'd1, 3'b010, 5'd11, 7'b0000011); // DoS STATUS
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;

            // Clear the sticky IDS alert before submitting the fuzzy frame.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd2, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h00, 5'd2, 5'd1, 3'b010, 7'b0100011);

            // Fuzzy frame: ID 0x555 is outside the default 0x0C3/0x145 allowlist.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h555, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h08, 5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h123, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h10, 5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h00, 5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h04, 5'd1, 3'b010, 5'd12, 7'b0000011); // fuzzy STATUS
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;

            // Clear alert, then submit spoofed engine ID 0x0C3 with the report's
            // FFFFFFFF_00000000 payload signature.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd2, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h00, 5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h0c3, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h08, 5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h10, 5'd0, 5'd1, 3'b010, 7'b0100011); // DATA_LO=0
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(-12'sd1, 5'd0, 3'b000, 5'd2, 7'b0010011); // x2=FFFFFFFF
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h14, 5'd2, 5'd1, 3'b010, 7'b0100011); // DATA_HI=FFFFFFFF
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h00, 5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h04, 5'd1, 3'b010, 5'd13, 7'b0000011); // spoof STATUS
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;

            // Read all classification counters and the interrupt pending bit.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h28, 5'd1, 3'b010, 5'd14, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h2c, 5'd1, 3'b010, 5'd15, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h30, 5'd1, 3'b010, 5'd16, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h34, 5'd1, 3'b010, 5'd17, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h38, 5'd1, 3'b010, 5'd18, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h3c, 5'd1, 3'b010, 5'd19, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h40, 5'd1, 3'b010, 5'd20, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h00, 5'd3, 3'b010, 5'd21, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_jtype(21'd0, 5'd0, 7'b1101111);

            apply_reset();
            run_cycles(220);

            check_and_report("CAN-IDS", "NORMAL", "allowed frame is classified normal", dut.u_id_stage.u_reg_file.regs[10], 32'h00000030);
            check_and_report("CAN-IDS", "DOS", "ID 0x000 and zero payload raise DoS alert", dut.u_id_stage.u_reg_file.regs[11], 32'h00000073);
            check_and_report("CAN-IDS", "FUZZY", "non-allowlisted ID raises fuzzy alert", dut.u_id_stage.u_reg_file.regs[12], 32'h00000075);
            check_and_report("CAN-IDS", "SPOOF", "engine ID with spoof payload raises alert", dut.u_id_stage.u_reg_file.regs[13], 32'h00000077);
            check_and_report("CAN-IDS", "NORMAL_COUNT", "one normal frame counted", dut.u_id_stage.u_reg_file.regs[14], 32'd1);
            check_and_report("CAN-IDS", "ATTACK_COUNT", "three attacks counted", dut.u_id_stage.u_reg_file.regs[15], 32'd3);
            check_and_report("CAN-IDS", "DOS_COUNT", "one DoS frame counted", dut.u_id_stage.u_reg_file.regs[16], 32'd1);
            check_and_report("CAN-IDS", "FUZZY_COUNT", "one fuzzy frame counted", dut.u_id_stage.u_reg_file.regs[17], 32'd1);
            check_and_report("CAN-IDS", "SPOOF_COUNT", "one spoof frame counted", dut.u_id_stage.u_reg_file.regs[18], 32'd1);
            check_and_report("CAN-IDS", "TOTAL_COUNT", "four submitted frames counted", dut.u_id_stage.u_reg_file.regs[19], 32'd4);
            check_and_report("CAN-IDS", "LAST_ID", "last attack ID is engine ECU 0x0C3", dut.u_id_stage.u_reg_file.regs[20], 32'h000000C3);
            check_and_report("CAN-IDS", "IRQ_PENDING", "IDS interrupt captured in INTC bit 4", dut.u_id_stage.u_reg_file.regs[21] & 32'h10, 32'h10);
            check_and_report("CAN-IDS", "IRQ_LINE", "enabled IDS interrupt asserts combined line", {31'h0, dut.irq_debug}, 32'h1);
            check_and_report("CAN-IDS", "ALERT_DEBUG", "top-level IDS alert remains observable", {31'h0, can_ids_alert_debug_tb}, 32'h1);
            check_and_report("CAN-IDS", "ACTIVITY", "four classification cycles reached power monitor", (dut.u_mem_stage.u_power_mgmt_mmio.can_ids_active_cycles > 0), 1'b1);
        end
    endtask

    // -------------------------------------------------------------------------
    // Integrated CAN-FD FIFO, SecOC, IDS, interrupt, and DMA test
    // -------------------------------------------------------------------------
    task automatic run_canfd_secoc_integration_tests();
        logic [31:0] status;
        logic [31:0] value;
        logic [31:0] tag_hi;
        logic [31:0] tag_lo;
        int timeout;
        begin
            $display("\n=== CAN-FD FIFO/DMA and SecOC integration tests ===");
            apply_reset();

            // Enable the dedicated CAN-FD/SecOC interrupt source at INTC bit 5.
            canfd_soc_write(32'h0000_0604, 32'h0000_0020);

            // Provision and lock the AES-CMAC key, then enable loopback and DMA.
            canfd_soc_write(32'h0000_0A9C, 32'h09CF_4F3C);
            canfd_soc_write(32'h0000_0AA0, 32'hABF7_1588);
            canfd_soc_write(32'h0000_0AA4, 32'h28AE_D2A6);
            canfd_soc_write(32'h0000_0AA8, 32'h2B7E_1516);
            canfd_soc_write(32'h0000_0A00, 32'h0000_2A00);

            // One 64-byte CAN-FD frame. Unwritten payload words remain zero.
            canfd_soc_write(32'h0000_0A08, 32'h0000_0145);
            canfd_soc_write(32'h0000_0A0C, 32'h0000_006F); // DLC=15,FDF=1,BRS=1
            canfd_soc_write(32'h0000_0A10, 32'd1);
            canfd_soc_write(32'h0000_0A20, 32'h1234_5678);
            canfd_soc_write(32'h0000_0A24, 32'h0000_1234);
            canfd_soc_write(32'h0000_0A00, 32'h0000_0004); // TX_SUBMIT

            timeout = 0;
            do begin
                canfd_soc_read(32'h0000_0A04, status);
                timeout++;
            end while (status[3] && (timeout < 10000));
            check_and_report("CAN-FD", "TX_FIFO", "protected frame reached TX FIFO",
                             {31'h0, !status[3]}, 32'h1);
            canfd_soc_read(32'h0000_0A6C, tag_hi);
            canfd_soc_read(32'h0000_0A70, tag_lo);
            canfd_soc_write(32'h0000_0A00, 32'h0000_0010); // TX_POP + loopback

            timeout = 0;
            do begin
                canfd_soc_read(32'h0000_0A7C, value);
                timeout++;
            end while ((value != 32'd1) && (timeout < 10000));
            check_and_report("SECOC", "AUTH_ACCEPT", "valid MAC and freshness accepted",
                             value, 32'd1);

            timeout = 0;
            do begin
                canfd_soc_read(32'h0000_0A98, value);
                timeout++;
            end while ((value != 32'd1) && (timeout < 1000));
            check_and_report("CAN-FD", "DMA_RECORD", "one authenticated RX record completed",
                             value, 32'd1);

            check_and_report("CAN-FD", "DMA_ID", "DMA descriptor stores CAN identifier",
                u_canfd_soc_eval.u_data_mem.ram[64], 32'h0000_0145);
            check_and_report("CAN-FD", "DMA_FLAGS", "DMA descriptor stores FD/BRS/DLC flags",
                u_canfd_soc_eval.u_data_mem.ram[65], 32'h0000_006F);
            check_and_report("SECOC", "DMA_FRESH", "DMA descriptor stores freshness value",
                u_canfd_soc_eval.u_data_mem.ram[67], 32'd1);
            check_and_report("CAN-FD", "DMA_PAYLOAD", "DMA record stores payload word zero",
                u_canfd_soc_eval.u_data_mem.ram[70], 32'h1234_5678);

            canfd_soc_read(32'h0000_093C, value);
            check_and_report("CAN-IDS", "AUTH_HANDOFF", "authenticated FD frame reached IDS",
                             value, 32'd1);
            canfd_soc_read(32'h0000_0928, value);
            check_and_report("CAN-IDS", "FD_DLC", "legal FD DLC is classified normally",
                             value, 32'd1);
            canfd_soc_read(32'h0000_0600, value);
            check_and_report("INTC", "CANFD_PENDING", "CAN-FD/SecOC event captured in bit 5",
                             value & 32'h20, 32'h20);
            check_and_report("INTC", "CANFD_IRQ", "enabled CAN-FD interrupt asserts IRQ line",
                             {31'h0, canfd_soc_irq}, 32'h1);

            // Reinject the authentic frame with the same freshness. MAC passes,
            // but the monotonic freshness check must reject it before IDS/DMA.
            canfd_soc_write(32'h0000_0A14, tag_hi);
            canfd_soc_write(32'h0000_0A18, tag_lo);
            canfd_soc_write(32'h0000_0A00, 32'h0000_0008);
            timeout = 0;
            do begin
                canfd_soc_read(32'h0000_0A84, value);
                timeout++;
            end while ((value != 32'd1) && (timeout < 10000));
            check_and_report("SECOC", "REPLAY_REJECT", "stale freshness is rejected",
                             value, 32'd1);

            // A newer freshness with the old tag isolates the MAC-failure path.
            canfd_soc_write(32'h0000_0A10, 32'd2);
            canfd_soc_write(32'h0000_0A00, 32'h0000_0008);
            timeout = 0;
            do begin
                canfd_soc_read(32'h0000_0A80, value);
                timeout++;
            end while ((value != 32'd1) && (timeout < 10000));
            check_and_report("SECOC", "MAC_REJECT", "incorrect MAC is rejected",
                             value, 32'd1);

            canfd_soc_read(32'h0000_0A7C, value);
            check_and_report("SECOC", "NO_RELEASE", "rejected frames do not increase accepts",
                             value, 32'd1);
            canfd_soc_read(32'h0000_093C, value);
            check_and_report("CAN-IDS", "NO_UNTRUSTED_IDS", "rejected frames never reach IDS",
                             value, 32'd1);
            canfd_soc_read(32'h0000_0A98, value);
            check_and_report("CAN-FD", "NO_UNTRUSTED_DMA", "rejected frames never reach DMA",
                             value, 32'd1);
            canfd_soc_read(32'h0000_0A9C, value);
            check_and_report("SECOC", "KEY_HIDE", "locked SecOC key readback is zero",
                             value, 32'h0);
        end
    endtask

    // -------------------------------------------------------------------------
    // Journal-oriented CAN security evaluation
    //
    // Seven labeled frames exercise normal traffic plus spoofing, replay,
    // flooding and protected-field modification. The DUT itself accumulates
    // TP/TN/FP/FN; the testbench converts those counters into percentages.
    // -------------------------------------------------------------------------
    task automatic run_can_ids_security_metrics_tests();
        real detection_rate;
        real precision;
        real recall;
        real false_positive_rate;
        begin
            $display("\n=== CAN-IDS attack coverage and detection metrics ===");
            apply_reset();

            // Keep ordinary CPU-spaced frames outside the flood threshold.
            ids_eval_write(8'h6C, 32'd64); // replay window
            ids_eval_write(8'h70, 32'd2);  // flood threshold

            // 1) True negative: allowed sensor frame with legal protected bits.
            ids_eval_set_frame(11'h145, 4'd8, 64'h0000_0000_0000_0123);
            ids_eval_label_submit(1'b0, 3'd0);
            run_cycles(70);

            // 2) True positive, spoofing: engine ID plus configured signature.
            ids_eval_set_frame(11'h0C3, 4'd8, 64'hFFFF_FFFF_0000_0000);
            ids_eval_label_submit(1'b1, 3'd3);
            run_cycles(70);

            // 3-4) A legal frame followed quickly by an identical copy. The
            // first is normal; the second is classified as replay.
            ids_eval_set_frame(11'h0C3, 4'd8, 64'h0000_0000_1111_2222);
            ids_eval_label_submit(1'b0, 3'd0);
            ids_eval_label_submit(1'b1, 3'd4);
            run_cycles(70);

            // 5-6) A legal baseline followed by a different frame inside a
            // widened minimum interval. Different payload prevents replay and
            // leaves the rate rule to identify flooding.
            ids_eval_write(8'h70, 32'd16);
            ids_eval_set_frame(11'h0C3, 4'd8, 64'h0000_0000_3333_4444);
            ids_eval_label_submit(1'b0, 3'd0);
            ids_eval_write(8'h10, 32'h5555_6666);
            ids_eval_label_submit(1'b1, 3'd5);
            run_cycles(70);

            // 7) Protected-field modification: ID 0x145 is configured with an
            // upper-16-bit zero invariant; A5A5 violates that invariant.
            ids_eval_write(8'h70, 32'd2);
            ids_eval_set_frame(11'h145, 4'd8, 64'hA5A5_0000_0000_0123);
            ids_eval_label_submit(1'b1, 3'd6);
            run_cycles(4);

            check_and_report("CAN-METRIC", "SPOOF", "spoof signature detected",
                             u_can_ids_eval.spoof_count_reg, 32'd1);
            check_and_report("CAN-METRIC", "REPLAY", "duplicate frame in replay window detected",
                             u_can_ids_eval.replay_count_reg, 32'd1);
            check_and_report("CAN-METRIC", "FLOOD", "short inter-frame interval detected",
                             u_can_ids_eval.flood_count_reg, 32'd1);
            check_and_report("CAN-METRIC", "MODIFY", "protected payload-field change detected",
                             u_can_ids_eval.modify_count_reg, 32'd1);
            check_and_report("CAN-METRIC", "TP", "four attack frames correctly detected",
                             u_can_ids_eval.tp_count_reg, 32'd4);
            check_and_report("CAN-METRIC", "TN", "three normal frames correctly accepted",
                             u_can_ids_eval.tn_count_reg, 32'd3);
            check_and_report("CAN-METRIC", "FP", "no normal frame falsely alerted",
                             u_can_ids_eval.fp_count_reg, 32'd0);
            check_and_report("CAN-METRIC", "FN", "no labeled attack was missed",
                             u_can_ids_eval.fn_count_reg, 32'd0);
            check_and_report("CAN-METRIC", "CLASS_MATCH", "all exact classes match ground truth",
                             u_can_ids_eval.class_match_count_reg, 32'd7);

            detection_rate = 100.0 * u_can_ids_eval.tp_count_reg /
                             (u_can_ids_eval.tp_count_reg + u_can_ids_eval.fn_count_reg);
            recall = detection_rate;
            precision = 100.0 * u_can_ids_eval.tp_count_reg /
                        (u_can_ids_eval.tp_count_reg + u_can_ids_eval.fp_count_reg);
            false_positive_rate = 100.0 * u_can_ids_eval.fp_count_reg /
                                  (u_can_ids_eval.fp_count_reg + u_can_ids_eval.tn_count_reg);
            $display("[CAN-METRIC] Detection rate = %0.2f%%", detection_rate);
            $display("[CAN-METRIC] Precision      = %0.2f%%", precision);
            $display("[CAN-METRIC] Recall         = %0.2f%%", recall);
            $display("[CAN-METRIC] False-positive = %0.2f%%", false_positive_rate);
        end
    endtask

    // -------------------------------------------------------------------------
    // AES key and nonce lifecycle checks
    // -------------------------------------------------------------------------
    task automatic run_aes_key_nonce_security_tests();
        logic [31:0] read_value;
        int timeout;
        begin
            $display("\n=== AES secure key and nonce-management tests ===");
            apply_reset();

            // Provision all four 32-bit words of one AES-128 key.
            aes_sec_write(8'h08, 32'h0C0D_0E0F);
            aes_sec_write(8'h0C, 32'h0809_0A0B);
            aes_sec_write(8'h10, 32'h0405_0607);
            aes_sec_write(8'h14, 32'h0001_0203);
            check_and_report("AES-SEC", "KEY_VALID", "all four key words recorded",
                             {28'h0, u_aes_security_eval.key_word_valid_reg}, 32'hF);

            // Locking blocks later writes and masks key readback.
            aes_sec_write(8'h48, 32'h1);
            aes_sec_write(8'h08, 32'hDEAD_BEEF);
            aes_sec_read(8'h08, read_value);
            check_and_report("AES-SEC", "KEY_LOCK", "key lock is asserted",
                             {31'h0, u_aes_security_eval.key_lock_reg}, 32'h1);
            check_and_report("AES-SEC", "WRITE_BLOCK", "locked key word cannot be overwritten",
                             u_aes_security_eval.key_reg[31:0], 32'h0C0D_0E0F);
            check_and_report("AES-SEC", "READ_HIDE", "locked key readback returns zero",
                             read_value, 32'h0);

            // Encrypt one CTR block. The wrapper records the accepted
            // key||(nonce||counter) tuple and increments the counter on done.
            aes_sec_write(8'h18, 32'h1122_3344);
            aes_sec_write(8'h1C, 32'h5566_7788);
            aes_sec_write(8'h20, 32'h99AA_BBCC);
            aes_sec_write(8'h24, 32'hDDEE_FF00);
            aes_sec_write(8'h38, 32'h4455_6677);
            aes_sec_write(8'h3C, 32'h0011_2233);
            aes_sec_write(8'h40, 32'hCCDD_EEFF);
            aes_sec_write(8'h44, 32'h8899_AABB);
            aes_sec_write(8'h00, 32'h5); // CTRL: start=1, mode_ctr=1
            timeout = 0;
            while ((u_aes_security_eval.done_reg !== 1'b1) &&
                   (timeout < 500)) begin
                @(posedge clk);
                timeout++;
            end
            check_and_report("AES-SEC", "CTR_DONE", "first protected CTR block completes",
                             {31'h0, u_aes_security_eval.done_reg}, 32'h1);
            check_and_report("AES-SEC", "COUNTER", "counter auto-increments after completion",
                             u_aes_security_eval.counter_reg[31:0], 32'hCCDD_EF00);

            // Rewind to the already-used counter with the same key and nonce.
            // The second start must be rejected rather than reuse a keystream.
            aes_sec_write(8'h40, 32'hCCDD_EEFF);
            aes_sec_write(8'h44, 32'h8899_AABB);
            aes_sec_write(8'h00, 32'h5);
            run_cycles(2);
            check_and_report("AES-SEC", "REUSE_REJECT", "same key/nonce/counter is rejected",
                             {31'h0, u_aes_security_eval.nonce_reuse_error_reg}, 32'h1);
            check_and_report("AES-SEC", "REUSE_IDLE", "rejected request does not start AES",
                             {31'h0, u_aes_security_eval.busy_reg}, 32'h0);

            // Clear the error, then zeroize and unlock for future provisioning.
            aes_sec_write(8'h48, 32'h4);
            aes_sec_write(8'h48, 32'h2);
            check_and_report("AES-SEC", "ZEROIZE", "all 128 key bits cleared",
                             (u_aes_security_eval.key_reg == 128'h0), 32'h1);
            check_and_report("AES-SEC", "UNLOCK", "zeroize returns interface to provisioning state",
                             {31'h0, u_aes_security_eval.key_lock_reg}, 32'h0);
        end
    endtask

    task automatic run_power_activity_tests();
        begin
            $display("\n=== Power/activity tests ===");
            clear_mem_and_regs();
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h7FF, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = 0x7ff
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'd1,   5'd1, 3'b000, 5'd1, 7'b0010011); // x1 = power base 0x800
            dut.u_if_stage.u_instr_mem.rom[2] = enc_itype(12'd2,   5'd0, 3'b000, 5'd2, 7'b0010011); // clear counters
            dut.u_if_stage.u_instr_mem.rom[3] = enc_stype(12'd0,   5'd2, 5'd1, 3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[4] = enc_itype(12'd1,   5'd0, 3'b000, 5'd2, 7'b0010011); // sleep
            dut.u_if_stage.u_instr_mem.rom[5] = enc_stype(12'd0,   5'd2, 5'd1, 3'b010, 7'b0100011);
            apply_reset();
            run_cycles(35);

            check_and_report("POWER", "SLEEP", "sleep control bit set", {31'h0, dut.sleep_debug}, 32'h1);
            check_and_report("POWER", "COUNT", "sleep cycles incremented", (dut.u_mem_stage.u_power_mgmt_mmio.sleep_cycles > 0), 1'b1);
            check_and_report("POWER", "DEBUG", "activity debug output observable", dut.activity_counter_debug, dut.u_mem_stage.u_power_mgmt_mmio.activity_counter_debug_o);
        end
    endtask

    task automatic run_custom_isa_tests();
        int i;
        begin
            $display("\n=== Custom security ISA tests ===");
            clear_mem_and_regs();

            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'd15, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = 0x0f
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'd51, 5'd0, 3'b000, 5'd2, 7'b0010011); // x2 = 0x33
            dut.u_if_stage.u_instr_mem.rom[2] = enc_custom(3'b000, 5'd2, 5'd1, 5'd3); // CSEC_XOR
            dut.u_if_stage.u_instr_mem.rom[3] = enc_custom(3'b001, 5'd0, 5'd0, 5'd4); // CSEC_AES_STATUS
            dut.u_if_stage.u_instr_mem.rom[4] = enc_custom(3'b010, 5'd2, 5'd1, 5'd5); // CSEC_AES_START
            for (i = 5; i < 48; i++) begin
                dut.u_if_stage.u_instr_mem.rom[i] = 32'h00000013;
            end
            dut.u_if_stage.u_instr_mem.rom[48] = enc_custom(3'b001, 5'd0, 5'd0, 5'd6); // CSEC_AES_STATUS after done
            dut.u_if_stage.u_instr_mem.rom[49] = enc_custom(3'b011, 5'd0, 5'd0, 5'd7); // CSEC_AES_CT0
            dut.u_if_stage.u_instr_mem.rom[50] = enc_custom(3'b100, 5'd0, 5'd0, 5'd8); // CSEC_AES_CLEAR
            dut.u_if_stage.u_instr_mem.rom[51] = enc_custom(3'b001, 5'd0, 5'd0, 5'd9); // CSEC_AES_STATUS after clear

            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            dut.u_mem_stage.u_aes_mmio.key_reg[31:0]   = 32'h0C0D0E0F;
            dut.u_mem_stage.u_aes_mmio.key_reg[63:32]  = 32'h08090A0B;
            dut.u_mem_stage.u_aes_mmio.key_reg[95:64]  = 32'h04050607;
            dut.u_mem_stage.u_aes_mmio.key_reg[127:96] = 32'h00010203;
            dut.u_mem_stage.u_aes_mmio.nonce_reg       = 64'h0011223344556677;
            dut.u_mem_stage.u_aes_mmio.counter_reg     = 64'h8899AABBCCDDEEFF;
            dut.u_mem_stage.u_aes_mmio.mode_ctr_reg    = 1'b0;
            dut.u_mem_stage.u_aes_mmio.busy_reg        = 1'b0;
            dut.u_mem_stage.u_aes_mmio.done_reg        = 1'b0;
            repeat (1) @(posedge clk);
            // The publication AES takes about 300 cycles per block.
            run_cycles(400);

            check_and_report("CUSTOM", "CSEC_XOR", "rd = rs1 ^ rs2; 0x0f ^ 0x33", dut.u_id_stage.u_reg_file.regs[3], 32'h0000003c);
            check_and_report("CUSTOM", "STATUS0",  "second ROM pass observes CTR mode while AES is busy", dut.u_id_stage.u_reg_file.regs[4], 32'h00000005);
            check_and_report("CUSTOM", "START",    "custom instruction selected CTR mode", {31'h0, dut.u_mem_stage.u_aes_mmio.mode_ctr_reg}, 32'h00000001);
            check_and_report("CUSTOM", "STATUS1",  "AES done after custom start", dut.u_id_stage.u_reg_file.regs[6], 32'h00000006);
            check_and_report("CUSTOM", "CT0",      "custom CT0 read returns plaintext XOR keystream", dut.u_id_stage.u_reg_file.regs[7], 32'h70B4C555);
            check_and_report("CUSTOM", "CLEAR",    "custom clear leaves mode set and done cleared", dut.u_id_stage.u_reg_file.regs[9], 32'h00000004);
        end
    endtask

    // -------------------------------------------------------------------------
    // Signal activity group
    // Exercises signals that may otherwise stay flat in the directed tests:
    // stall_if, flush_ifid, aes_sel, aes_write_en, and aes_read_en.
    // -------------------------------------------------------------------------
    task automatic run_signal_activity_tests();
        begin
            $display("\n=== Signal activity tests ===");
            reset_activity_counters();

            clear_mem_and_regs();
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'd0, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = 0
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'd0, 5'd1, 3'b010, 5'd2, 7'b0000011); // LW x2,0(x1)
            dut.u_if_stage.u_instr_mem.rom[2] = enc_itype(12'd1, 5'd2, 3'b000, 5'd3, 7'b0010011); // ADDI x3,x2,1

            apply_reset();
            dut.u_mem_stage.u_data_mem.ram[0] = 32'h0000002a;
            run_cycles(18);

            clear_mem_and_regs();
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h300, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = AES base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'd1,   5'd0, 3'b000, 5'd2, 7'b0010011); // x2 = start bit
            dut.u_if_stage.u_instr_mem.rom[2] = enc_stype(12'd0,   5'd2, 5'd1, 3'b010, 7'b0100011); // SW x2,CTRL(x1)
            dut.u_if_stage.u_instr_mem.rom[3] = enc_itype(12'd4,   5'd1, 3'b010, 5'd3, 7'b0000011); // LW x3,STATUS(x1)

            apply_reset();
            run_cycles(60);

            check_seen("stall_if", if_stall_seen_count);
            check_seen("flush_ifid", if_flush_seen_count);
            check_seen("aes_sel", aes_sel_seen_count);
            check_seen("aes_write_en", aes_write_seen_count);
            check_seen("aes_read_en", aes_read_seen_count);
        end
    endtask

    // -------------------------------------------------------------------------
    // Deterministic random coverage smoke test
    // Uses a fixed seed so regression remains repeatable while still exercising
    // non-constant data values and varied MMIO paths.
    // -------------------------------------------------------------------------
    task automatic run_random_coverage_tests();
        int unsigned seed;
        logic [31:0] rnd_a;
        logic [31:0] rnd_b;
        logic [31:0] rnd_sensor;
        logic [31:0] rnd_dma_data;
        logic [7:0]  rnd_uart_byte;
        int unsigned src_idx;
        int unsigned dst_idx;
        begin
            $display("\n=== Randomized coverage smoke tests ===");
            seed = 32'hC0DE_2026;
            rnd_a         = $urandom(seed);
            rnd_b         = $urandom();
            rnd_sensor    = $urandom();
            rnd_dma_data  = $urandom();
            rnd_uart_byte = $urandom();
            src_idx       = 8 + ($urandom() % 8);
            dst_idx       = 24 + ($urandom() % 8);

            // Random custom-ISA datapath check: CSEC_XOR rd, rs1, rs2.
            clear_mem_and_regs();
            dut.u_if_stage.u_instr_mem.rom[0] = 32'h00000013; // NOP
            dut.u_if_stage.u_instr_mem.rom[1] = 32'h00000013; // NOP
            dut.u_if_stage.u_instr_mem.rom[2] = enc_custom(3'b000, 5'd2, 5'd1, 5'd3);
            apply_reset();
            dut.u_id_stage.u_reg_file.regs[1] = rnd_a;
            dut.u_id_stage.u_reg_file.regs[2] = rnd_b;
            run_cycles(18);
            check_and_report("RANDOM", "CSEC_XOR", "random rs1 ^ rs2 through custom ISA", dut.u_id_stage.u_reg_file.regs[3], (rnd_a ^ rnd_b));

            // Random sensor MMIO read: inject a random sample, then read through CPU load.
            clear_mem_and_regs();
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h400, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = sensor base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(12'd0,   5'd1, 3'b010, 5'd2, 7'b0000011); // LW x2,SENSOR_DATA
            apply_reset();
            dut.u_mem_stage.u_sensor_spi_mmio.sensor_data_reg = rnd_sensor;
            dut.u_mem_stage.u_sensor_spi_mmio.data_ready_reg  = 1'b1;
            run_cycles(20);
            check_and_report("RANDOM", "SENSOR", "random sensor sample read through MMIO", dut.u_id_stage.u_reg_file.regs[2], rnd_sensor);

            // Random DMA-lite copy: randomized source/destination word addresses.
            clear_mem_and_regs();
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h700,        5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = DMA base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype(src_idx * 4,    5'd0, 3'b000, 5'd2, 7'b0010011); // src byte addr
            dut.u_if_stage.u_instr_mem.rom[2] = enc_stype(12'd0,          5'd2, 5'd1, 3'b010, 7'b0100011); // SW SRC
            dut.u_if_stage.u_instr_mem.rom[3] = enc_itype(dst_idx * 4,    5'd0, 3'b000, 5'd2, 7'b0010011); // dst byte addr
            dut.u_if_stage.u_instr_mem.rom[4] = enc_stype(12'd4,          5'd2, 5'd1, 3'b010, 7'b0100011); // SW DST
            dut.u_if_stage.u_instr_mem.rom[5] = enc_itype(12'd1,          5'd0, 3'b000, 5'd2, 7'b0010011); // len = 1 word
            dut.u_if_stage.u_instr_mem.rom[6] = enc_stype(12'd8,          5'd2, 5'd1, 3'b010, 7'b0100011); // SW LEN
            dut.u_if_stage.u_instr_mem.rom[7] = enc_stype(12'd12,         5'd2, 5'd1, 3'b010, 7'b0100011); // SW CTRL start
            apply_reset();
            dut.u_mem_stage.u_data_mem.ram[src_idx] = rnd_dma_data;
            run_cycles(50);
            check_and_report("RANDOM", "DMA", "random word copied from randomized source to destination", dut.u_mem_stage.u_data_mem.ram[dst_idx], rnd_dma_data);

            // Random UART byte: verify MMIO stores the byte and transfer completes.
            clear_mem_and_regs();
            dut.u_if_stage.u_instr_mem.rom[0] = enc_itype(12'h500,          5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = UART base
            dut.u_if_stage.u_instr_mem.rom[1] = enc_itype({4'h0, rnd_uart_byte}, 5'd0, 3'b000, 5'd2, 7'b0010011); // x2 = random byte
            dut.u_if_stage.u_instr_mem.rom[2] = enc_stype(12'd0,            5'd2, 5'd1, 3'b010, 7'b0100011); // SW TXDATA
            apply_reset();
            dut.u_mem_stage.u_uart_mmio.baud_div_reg = 16'd1;
            run_cycles(45);
            check_and_report("RANDOM", "UART_DATA", "random UART byte accepted through MMIO", {24'h0, dut.u_mem_stage.u_uart_mmio.tx_data_reg}, {24'h0, rnd_uart_byte});
            check_and_report("RANDOM", "UART_DONE", "random UART byte transmission completed", {31'h0, dut.u_mem_stage.u_uart_mmio.done_latched}, 32'h1);
        end
    endtask

    // -------------------------------------------------------------------------
    // Full-SoC CPU-driven integration scenario
    //
    // One continuous RV32I program exercises the complete application path:
    //   SPI/CAN frame -> CAN-IDS -> RAM -> DMA copy -> AES-CTR -> UART
    //   -> IRQ/activity -> sleep
    // -------------------------------------------------------------------------
    task automatic run_full_soc_pipeline_integration_test();
        int p;
        begin
            $display("\n=== Full-SoC CPU pipeline integration test ===");
            clear_mem_and_regs();
            p = 0;

            // Peripheral bases and interrupt/power setup.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h400, 5'd0, 3'b000, 5'd1, 7'b0010011); // x1 = sensor/SPI base
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h700, 5'd0, 3'b000, 5'd2, 7'b0010011); // x2 = DMA base
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h600, 5'd0, 3'b000, 5'd3, 7'b0010011); // x3 = INTC base
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h300, 5'd0, 3'b000, 5'd4, 7'b0010011); // x4 = AES base
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h500, 5'd0, 3'b000, 5'd5, 7'b0010011); // x5 = UART base
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h7ff, 5'd0, 3'b000, 5'd6, 7'b0010011); // x6 = 0x7ff
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd1,   5'd6, 3'b000, 5'd6, 7'b0010011); // x6 = power base 0x800
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h7ff, 5'd0, 3'b000, 5'd26, 7'b0010011); // x26 = 0x7ff
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h101, 5'd26,3'b000, 5'd26, 7'b0010011); // x26 = CAN-IDS base 0x900
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd31,  5'd0, 3'b000, 5'd7, 7'b0010011); // x7 = enable five IRQs
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd4,   5'd7, 5'd3, 3'b010, 7'b0100011); // INTC.IRQ_ENABLE = 0x1f
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd2,   5'd0, 3'b000, 5'd8, 7'b0010011); // x8 = clear counters
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd0,   5'd8, 5'd6, 3'b010, 7'b0100011); // POWER_CTRL.clear

            // Read the sensor through the CPU and retain the sample in RAM.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd0, 5'd1, 3'b010, 5'd10, 7'b0000011); // x10 = SENSOR_DATA
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013; // load-to-store pipeline interlock
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd64, 5'd10, 5'd0, 3'b010, 7'b0100011); // RAM[16] = sensor sample

            // Start an SPI loopback transaction while the remaining SoC runs.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd1,    5'd0, 3'b000, 5'd8, 7'b0010011); // slave select = 1
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd36,   5'd8, 5'd1, 3'b010, 7'b0100011); // SPI_SLAVE_SELECT
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h400,  5'd0, 3'b000, 5'd8, 7'b0010011); // SSO control bit
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd28,   5'd8, 5'd1, 3'b010, 7'b0100011); // SPI_CONTROL
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h05a,  5'd0, 3'b000, 5'd9, 7'b0010011); // SPI test byte
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd20,   5'd9, 5'd1, 3'b010, 7'b0100011); // SPI_TXDATA

            // Submit the documented spoofing signature to the hardware IDS.
            // In a vehicle, software fills these fields from an MCP2515 frame
            // read through the SPI window above.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd8,    5'd0, 3'b000, 5'd8, 7'b0010011); // DLC=8
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h0c,   5'd8, 5'd26,3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h0c3,  5'd0, 3'b000, 5'd8, 7'b0010011); // engine ID
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h08,   5'd8, 5'd26,3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h10,   5'd0, 5'd26,3'b010, 7'b0100011); // low payload=0
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(-12'sd1,  5'd0, 3'b000, 5'd8, 7'b0010011); // high payload=FFFFFFFF
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h14,   5'd8, 5'd26,3'b010, 7'b0100011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd1,    5'd0, 3'b000, 5'd8, 7'b0010011); // submit
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'h00,   5'd8, 5'd26,3'b010, 7'b0100011);

            // DMA copies the sensor sample from RAM[16] to RAM[17].
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd64, 5'd0, 3'b000, 5'd11, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd0,  5'd11, 5'd2, 3'b010, 7'b0100011); // DMA_SRC
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd68, 5'd0, 3'b000, 5'd11, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd4,  5'd11, 5'd2, 3'b010, 7'b0100011); // DMA_DST
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd1,  5'd0, 3'b000, 5'd11, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd8,  5'd11, 5'd2, 3'b010, 7'b0100011); // DMA_LEN
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd12, 5'd11, 5'd2, 3'b010, 7'b0100011); // DMA_CTRL.start

            // Program AES-CTR from RAM-resident key/nonce/counter words.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd128, 5'd0, 3'b010, 5'd13, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd8,    5'd13, 5'd4, 3'b010, 7'b0100011); // KEY0
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd132, 5'd0, 3'b010, 5'd13, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd12,   5'd13, 5'd4, 3'b010, 7'b0100011); // KEY1
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd136, 5'd0, 3'b010, 5'd13, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd16,   5'd13, 5'd4, 3'b010, 7'b0100011); // KEY2
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd140, 5'd0, 3'b010, 5'd13, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd20,   5'd13, 5'd4, 3'b010, 7'b0100011); // KEY3
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd24,   5'd10, 5'd4, 3'b010, 7'b0100011); // PT0 = sensor
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd144, 5'd0, 3'b010, 5'd13, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd56,   5'd13, 5'd4, 3'b010, 7'b0100011); // NONCE0
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd148, 5'd0, 3'b010, 5'd13, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd60,   5'd13, 5'd4, 3'b010, 7'b0100011); // NONCE1
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd152, 5'd0, 3'b010, 5'd13, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd64,   5'd13, 5'd4, 3'b010, 7'b0100011); // COUNT0
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd156, 5'd0, 3'b010, 5'd13, 7'b0000011);
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd68,   5'd13, 5'd4, 3'b010, 7'b0100011); // COUNT1
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd5,   5'd0, 3'b000, 5'd14, 7'b0010011); // start + CTR mode
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd0,    5'd14, 5'd4, 3'b010, 7'b0100011); // AES_CTRL

            // Real CPU branch loop gives AES and the slower SPI IP time to finish.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd600, 5'd0, 3'b000, 5'd30, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(-12'sd1, 5'd30, 3'b000, 5'd30, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_btype(13'h1ffc, 5'd0, 5'd30, 3'b001, 7'b1100011); // BNE x30,x0,-4

            // Read ciphertext through MMIO and transmit its low byte through UART.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd1,  5'd0, 3'b000, 5'd15, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd12, 5'd15, 5'd5, 3'b010, 7'b0100011); // UART_BAUD_DIV = 1
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd40, 5'd4, 3'b010, 5'd20, 7'b0000011); // x20 = AES_CT0
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd0,  5'd20, 5'd5, 3'b010, 7'b0100011); // UART_TXDATA = CT0[7:0]
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd80, 5'd0, 3'b000, 5'd30, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(-12'sd1, 5'd30, 3'b000, 5'd30, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_btype(13'h1ffc, 5'd0, 5'd30, 3'b001, 7'b1100011);

            // Capture interrupt and activity evidence before entering sleep.
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd0,  5'd3, 3'b010, 5'd21, 7'b0000011); // IRQ_PENDING
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd8,  5'd6, 3'b010, 5'd22, 7'b0000011); // AES_ACTIVE
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd12, 5'd6, 3'b010, 5'd23, 7'b0000011); // UART_ACTIVE
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd20, 5'd6, 3'b010, 5'd24, 7'b0000011); // DMA_ACTIVE
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd24, 5'd6, 3'b010, 5'd25, 7'b0000011); // SENSOR_ACTIVE
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd4,  5'd26,3'b010, 5'd28, 7'b0000011); // CAN_IDS_STATUS
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd28, 5'd6, 3'b010, 5'd29, 7'b0000011); // CAN_IDS_ACTIVE
            dut.u_if_stage.u_instr_mem.rom[p++] = 32'h00000013;
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'h055, 5'd0, 3'b000, 5'd27, 7'b0010011); // completion marker
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_itype(12'd1,  5'd0, 3'b000, 5'd15, 7'b0010011);
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_stype(12'd0,   5'd15, 5'd6, 3'b010, 7'b0100011); // request sleep
            dut.u_if_stage.u_instr_mem.rom[p++] = enc_jtype(21'd0, 5'd0, 7'b1101111); // remain here after application completion

            apply_reset();
            reset_activity_counters();

            // Software-visible constants used by the CPU loads above.
            dut.u_mem_stage.u_data_mem.ram[32] = 32'h0c0d0e0f;
            dut.u_mem_stage.u_data_mem.ram[33] = 32'h08090a0b;
            dut.u_mem_stage.u_data_mem.ram[34] = 32'h04050607;
            dut.u_mem_stage.u_data_mem.ram[35] = 32'h00010203;
            dut.u_mem_stage.u_data_mem.ram[36] = 32'h44556677;
            dut.u_mem_stage.u_data_mem.ram[37] = 32'h00112233;
            dut.u_mem_stage.u_data_mem.ram[38] = 32'hccddeeff;
            dut.u_mem_stage.u_data_mem.ram[39] = 32'h8899aabb;

            run_cycles(4500);

            check_and_report("FULL-SOC", "CPU_PIPELINE", "program reached completion marker through IF/ID/EX/MEM/WB", dut.u_id_stage.u_reg_file.regs[27], 32'h00000055);
            check_and_report("FULL-SOC", "SENSOR_READ", "CPU read sensor sample through MMIO", dut.u_id_stage.u_reg_file.regs[10], 32'h12345678);
            check_and_report("FULL-SOC", "DMA_COPY", "DMA copied CPU-stored sensor sample", dut.u_mem_stage.u_data_mem.ram[17], 32'h12345678);
            check_and_report("FULL-SOC", "SPI_ACTIVITY", "SPI transaction generated serial clock edges", {31'h0, (spi_sclk_toggle_count > 0)}, 32'h1);
            check_and_report("FULL-SOC", "AES_CTR_CT0", "AES-CTR encrypted sensor word", dut.u_mem_stage.u_aes_mmio.ct_reg[31:0], 32'h62809322);
            check_and_report("FULL-SOC", "UART_DATA", "UART accepted AES ciphertext low byte", {24'h0, dut.u_mem_stage.u_uart_mmio.tx_data_reg}, 32'h00000022);
            check_and_report("FULL-SOC", "UART_DONE", "UART ciphertext transmission completed", {31'h0, dut.u_mem_stage.u_uart_mmio.done_latched}, 32'h1);
            check_and_report("FULL-SOC", "CAN_IDS", "spoofed engine frame classified and alerted", dut.u_id_stage.u_reg_file.regs[28], 32'h00000077);
            check_and_report("FULL-SOC", "CAN_IDS_DEBUG", "CAN intrusion alert exposed at top level", {31'h0, can_ids_alert_debug_tb}, 32'h1);
            check_and_report("FULL-SOC", "IRQ_PENDING", "AES/UART/sensor/DMA/IDS pending bits captured", dut.u_id_stage.u_reg_file.regs[21] & 32'h1f, 32'h1f);
            check_and_report("FULL-SOC", "IRQ_LINE", "combined enabled interrupt line asserted", {31'h0, dut.irq_debug}, 32'h1);
            check_and_report("FULL-SOC", "AES_ACTIVITY", "CPU-observed AES active counter is nonzero", (dut.u_id_stage.u_reg_file.regs[22] > 0), 1'b1);
            check_and_report("FULL-SOC", "UART_ACTIVITY", "CPU-observed UART active counter is nonzero", (dut.u_id_stage.u_reg_file.regs[23] > 0), 1'b1);
            check_and_report("FULL-SOC", "DMA_ACTIVITY", "CPU-observed DMA active counter is nonzero", (dut.u_id_stage.u_reg_file.regs[24] > 0), 1'b1);
            check_and_report("FULL-SOC", "SENSOR_ACTIVITY", "CPU-observed sensor active counter is nonzero", (dut.u_id_stage.u_reg_file.regs[25] > 0), 1'b1);
            check_and_report("FULL-SOC", "CAN_IDS_ACTIVITY", "CPU-observed IDS activity counter is nonzero", (dut.u_id_stage.u_reg_file.regs[29] > 0), 1'b1);
            check_and_report("FULL-SOC", "SLEEP", "CPU requested low-power sleep after transmission", {31'h0, dut.sleep_debug}, 32'h1);
            check_and_report("FULL-SOC", "SLEEP_CYCLES", "sleep activity counter incremented", (dut.u_mem_stage.u_power_mgmt_mmio.sleep_cycles > 0), 1'b1);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // 47 checks total:
    // 10 (R) + 9 (I) + 8 (Load/Store) + 6 (B) + 4 (U/J) + 10 (System/Fence/Pseudo)
    // Existing 58 checks are preserved, then IoT-security SoC checks are added.
    // -------------------------------------------------------------------------
    initial begin
        pass_count = 0;
        fail_count = 0;
        reset_activity_counters();

        $dumpfile("riscv_core_tb.vcd");
        $dumpvars(0, riscv_core_tb);

        if ($test$plusargs("CANFD_SECOC_ONLY")) begin
            verification_phase_id = 8'd9;
            run_canfd_secoc_integration_tests();
        end else if ($test$plusargs("SECURITY_EXTENSION_ONLY")) begin
            verification_phase_id = 8'd8;
            run_aes_key_nonce_security_tests();
            run_can_ids_security_metrics_tests();
            run_canfd_secoc_integration_tests();
        end else if ($test$plusargs("FULL_SOC_SCENARIO_ONLY")) begin
            verification_phase_id = 8'd7;
            $display("\nRunning standalone scenario: Secure Health-Monitoring IoT transaction");
            run_full_soc_pipeline_integration_test();
        end else if ($test$plusargs("AES_KAT_ONLY")) begin
            verification_phase_id = 8'd1;
            run_aes_nist_tests();
        end else if ($test$plusargs("DIRECTED_CPU_ONLY")) begin
            verification_phase_id = 8'd2;
            run_rtype_tests();
            run_itype_tests();
            run_load_store_tests();
            run_branch_tests();
            run_u_jtype_tests();
            run_system_fence_pseudo_tests();
        end else if ($test$plusargs("DIRECTED_PERIPHERAL_ONLY")) begin
            verification_phase_id = 8'd3;
            run_aes_ctr_tests();
            run_sensor_mmio_tests();
            run_sensor_spi_ip_tests();
            run_uart_mmio_tests();
            run_interrupt_tests();
            run_dma_lite_tests();
            run_can_ids_tests();
            run_aes_key_nonce_security_tests();
            run_can_ids_security_metrics_tests();
            run_canfd_secoc_integration_tests();
            run_power_activity_tests();
            run_custom_isa_tests();
        end else if ($test$plusargs("RANDOM_SMOKE_ONLY")) begin
            verification_phase_id = 8'd4;
            run_random_coverage_tests();
        end else begin
            verification_phase_id = 8'd2;
            run_rtype_tests();
            run_itype_tests();
            run_load_store_tests();
            run_branch_tests();
            run_u_jtype_tests();
            run_system_fence_pseudo_tests();
            verification_phase_id = 8'd1;
            run_aes_nist_tests();
            verification_phase_id = 8'd3;
            run_aes_ctr_tests();
            run_sensor_mmio_tests();
            run_sensor_spi_ip_tests();
            run_uart_mmio_tests();
            run_end_to_end_uart_aes_ctr_tests();
            run_interrupt_tests();
            run_dma_lite_tests();
            run_can_ids_tests();
            run_aes_key_nonce_security_tests();
            run_can_ids_security_metrics_tests();
            run_canfd_secoc_integration_tests();
            run_power_activity_tests();
            run_custom_isa_tests();
            run_signal_activity_tests();
            verification_phase_id = 8'd4;
            run_random_coverage_tests();
            verification_phase_id = 8'd7;
            run_full_soc_pipeline_integration_test();
        end

        run_cycles(PIPE_DRAIN);

        $display("\n================================================");
        $display("RV32I-style directed verification summary: PASS=%0d FAIL=%0d", pass_count, fail_count);
        $display("Lightweight IoT Security Processor + Custom ISA verification summary: PASS=%0d FAIL=%0d", pass_count, fail_count);
        $display("================================================\n");

        if (fail_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("SOME TESTS FAILED");
        end

        #20;
        $finish;
    end
`endif
endmodule
