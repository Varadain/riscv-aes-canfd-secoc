// ============================================================================
// CAN-IDS UVM virtual interface
//
// The UVM driver uses the MMIO tasks below to program can_ids_mmio. The monitor
// observes one sampled result per submitted frame through the observation fields.
// Assertions check the basic bus contract and important RTL output invariants.
// ============================================================================
interface can_ids_uvm_if(input logic clk);
    timeunit 1ns;
    timeprecision 1ps;

    logic        rst_n;
    logic        clk_en;
    logic [31:0] addr;
    logic [31:0] wdata;
    logic        write_en;
    logic        read_en;
    logic [31:0] rdata;
    logic        alert_irq;
    logic        alert_debug;
    logic        active;

    // Waveform-visible transaction/result sample from driver to monitor.
    logic        sample_valid;
    logic [31:0] obs_case_id;
    logic        obs_is_random;
    logic [2:0]  obs_stimulus_kind;
    logic [10:0] obs_can_id;
    logic [3:0]  obs_dlc;
    logic [63:0] obs_payload;
    logic        obs_expected_attack;
    logic [2:0]  obs_expected_class;
    logic        obs_attack;
    logic [2:0]  obs_class;
    logic        obs_status_valid;
    logic        obs_alert;
    logic [31:0] obs_total_count;
    logic [31:0] obs_normal_count;
    logic [31:0] obs_attack_count;
    logic [31:0] obs_dos_count;
    logic [31:0] obs_fuzzy_count;
    logic [31:0] obs_spoof_count;
    logic [31:0] obs_replay_count;
    logic [31:0] obs_flood_count;
    logic [31:0] obs_modify_count;
    logic [31:0] obs_tp_count;
    logic [31:0] obs_tn_count;
    logic [31:0] obs_fp_count;
    logic [31:0] obs_fn_count;
    logic [31:0] obs_class_match_count;
    logic [10:0] obs_last_attack_id;

    logic [31:0] coverage_bins;
    logic [31:0] coverage_percent_x100;
    logic [31:0] scoreboard_matches;
    logic [31:0] scoreboard_mismatches;
    logic [31:0] assertion_failures;
    logic [31:0] assertion_cover_hits;
    logic [31:0] assertion_submit_attempts;
    logic [31:0] assertion_active_attempts;

    task automatic init();
        rst_n = 1'b0;
        clk_en = 1'b1;
        addr = 32'h0;
        wdata = 32'h0;
        write_en = 1'b0;
        read_en = 1'b0;
        sample_valid = 1'b0;
        obs_case_id = 32'h0;
        obs_is_random = 1'b0;
        obs_stimulus_kind = 3'h0;
        obs_can_id = 11'h0;
        obs_dlc = 4'h0;
        obs_payload = 64'h0;
        obs_expected_attack = 1'b0;
        obs_expected_class = 3'h0;
        obs_attack = 1'b0;
        obs_class = 3'h0;
        obs_status_valid = 1'b0;
        obs_alert = 1'b0;
        obs_total_count = 32'h0;
        obs_normal_count = 32'h0;
        obs_attack_count = 32'h0;
        obs_dos_count = 32'h0;
        obs_fuzzy_count = 32'h0;
        obs_spoof_count = 32'h0;
        obs_replay_count = 32'h0;
        obs_flood_count = 32'h0;
        obs_modify_count = 32'h0;
        obs_tp_count = 32'h0;
        obs_tn_count = 32'h0;
        obs_fp_count = 32'h0;
        obs_fn_count = 32'h0;
        obs_class_match_count = 32'h0;
        obs_last_attack_id = 11'h0;
        coverage_bins = 32'h0;
        coverage_percent_x100 = 32'h0;
        scoreboard_matches = 32'h0;
        scoreboard_mismatches = 32'h0;
        assertion_failures = 32'h0;
        assertion_cover_hits = 32'h0;
        assertion_submit_attempts = 32'h0;
        assertion_active_attempts = 32'h0;
    endtask

    task automatic apply_reset();
        init();
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
    endtask

    task automatic wait_cycles(input int unsigned cycles);
        repeat (cycles) @(posedge clk);
    endtask

    task automatic mmio_write(input logic [7:0] offset, input logic [31:0] data);
        @(negedge clk);
        addr = {24'h0, offset};
        wdata = data;
        write_en = 1'b1;
        read_en = 1'b0;
        @(posedge clk);
        @(negedge clk);
        write_en = 1'b0;
        wdata = 32'h0;
    endtask

    task automatic mmio_read(input logic [7:0] offset, output logic [31:0] data);
        @(negedge clk);
        addr = {24'h0, offset};
        read_en = 1'b1;
        write_en = 1'b0;
        #1;
        data = rdata;
        @(negedge clk);
        read_en = 1'b0;
    endtask

    task automatic publish_sample(
        input int unsigned case_id,
        input logic        is_random,
        input logic [2:0]  stimulus_kind,
        input logic [10:0] can_id,
        input logic [3:0]  dlc,
        input logic [63:0] payload,
        input logic        expected_attack,
        input logic [2:0]  expected_class,
        input logic        observed_attack,
        input logic [2:0]  observed_class,
        input logic        status_valid,
        input logic        alert,
        input logic [31:0] total_count,
        input logic [31:0] normal_count,
        input logic [31:0] attack_count,
        input logic [31:0] dos_count,
        input logic [31:0] fuzzy_count,
        input logic [31:0] spoof_count,
        input logic [31:0] replay_count,
        input logic [31:0] flood_count,
        input logic [31:0] modify_count,
        input logic [31:0] tp_count,
        input logic [31:0] tn_count,
        input logic [31:0] fp_count,
        input logic [31:0] fn_count,
        input logic [31:0] class_match_count,
        input logic [10:0] last_attack_id
    );
        @(negedge clk);
        obs_case_id = case_id;
        obs_is_random = is_random;
        obs_stimulus_kind = stimulus_kind;
        obs_can_id = can_id;
        obs_dlc = dlc;
        obs_payload = payload;
        obs_expected_attack = expected_attack;
        obs_expected_class = expected_class;
        obs_attack = observed_attack;
        obs_class = observed_class;
        obs_status_valid = status_valid;
        obs_alert = alert;
        obs_total_count = total_count;
        obs_normal_count = normal_count;
        obs_attack_count = attack_count;
        obs_dos_count = dos_count;
        obs_fuzzy_count = fuzzy_count;
        obs_spoof_count = spoof_count;
        obs_replay_count = replay_count;
        obs_flood_count = flood_count;
        obs_modify_count = modify_count;
        obs_tp_count = tp_count;
        obs_tn_count = tn_count;
        obs_fp_count = fp_count;
        obs_fn_count = fn_count;
        obs_class_match_count = class_match_count;
        obs_last_attack_id = last_attack_id;
        sample_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        sample_valid = 1'b0;
    endtask

    wire submit_pulse = rst_n && clk_en && write_en && (addr[7:0] == 8'h00) &&
                        wdata[0] && !wdata[4];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            assertion_submit_attempts <= 32'h0;
            assertion_active_attempts <= 32'h0;
        end else begin
            if (submit_pulse)
                assertion_submit_attempts <= assertion_submit_attempts + 32'd1;
            if (active)
                assertion_active_attempts <= assertion_active_attempts + 32'd1;
        end
    end

    ASSERT_NO_READ_WRITE_COLLISION:
        assert property (@(posedge clk) disable iff (!rst_n)
                         !(read_en && write_en))
        else begin
            assertion_failures++;
            $error("CAN-IDS UVM bus attempted read and write in the same cycle");
        end

    ASSERT_IRQ_MATCHES_ALERT:
        assert property (@(posedge clk) disable iff (!rst_n)
                         alert_irq === alert_debug)
        else begin
            assertion_failures++;
            $error("CAN-IDS IRQ output must mirror sticky alert_debug");
        end

    ASSERT_SUBMIT_RAISES_ACTIVE:
        assert property (@(posedge clk) disable iff (!rst_n)
                         submit_pulse |=> active)
        else begin
            assertion_failures++;
            $error("CAN-IDS submit did not produce an active pulse");
        end

    ASSERT_ACTIVE_ONE_CYCLE:
        assert property (@(posedge clk) disable iff (!rst_n)
                         active |=> !active)
        else begin
            assertion_failures++;
            $error("CAN-IDS active pulse stayed high for more than one cycle");
        end

    COVER_ATTACK_ALERT:
        cover property (@(posedge clk) disable iff (!rst_n)
                        active && alert_debug)
        assertion_cover_hits++;
endinterface
