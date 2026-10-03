// ============================================================
// Synthesizable Automotive CAN Intrusion-Detection MMIO Block
//
// Base address: 0x0000_0900
//   0x00 CTRL             write [0] submit frame, [1] clear alert,
//                                  [2] clear counters, [3] enable,
//                                  [4] disable
//   0x04 STATUS           [0] alert, [3:1] class, [4] valid,
//                         [5] enabled, [6] last frame was an attack
//   0x08 FRAME_ID         [10:0] standard 11-bit CAN identifier
//   0x0C FRAME_DLC        [3:0] payload length, legal classic CAN range 0..8
//   0x10 FRAME_DATA_LO    payload bytes 4..7
//   0x14 FRAME_DATA_HI    payload bytes 0..3
//   0x18 ALLOW_ID0        first expected ECU identifier, reset 0x0C3
//   0x1C ALLOW_ID1        second expected ECU identifier, reset 0x145
//   0x20 SPOOF_DATA_LO    expected spoof signature low word, reset 0x00000000
//   0x24 SPOOF_DATA_HI    expected spoof signature high word, reset 0xFFFFFFFF
//   0x28 NORMAL_COUNT
//   0x2C ATTACK_COUNT
//   0x30 DOS_COUNT
//   0x34 FUZZY_COUNT
//   0x38 SPOOF_COUNT
//   0x3C TOTAL_COUNT
//   0x40 LAST_ATTACK_ID
//   0x44 LAST_INTERVAL    system-clock cycles between submitted frames
//   0x48 CAPABILITY       fixed value: version 2, six attack classes
//   0x4C EVAL_LABEL       [0] expected attack, [3:1] expected class,
//                         [4] enable confusion-matrix evaluation
//   0x50 TP_COUNT         true positives
//   0x54 TN_COUNT         true negatives
//   0x58 FP_COUNT         false positives
//   0x5C FN_COUNT         false negatives
//   0x60 REPLAY_COUNT
//   0x64 FLOOD_COUNT
//   0x68 MODIFY_COUNT
//   0x6C REPLAY_WINDOW    maximum duplicate-frame interval in clock cycles
//   0x70 FLOOD_THRESHOLD  minimum legal inter-frame interval in clock cycles
//   0x74 MODIFY_ID        CAN ID whose protected payload fields are checked
//   0x78 MODIFY_MASK_LO   protected payload-bit mask [31:0]
//   0x7C MODIFY_MASK_HI   protected payload-bit mask [63:32]
//   0x80 MODIFY_EXPECT_LO expected protected payload value [31:0]
//   0x84 MODIFY_EXPECT_HI expected protected payload value [63:32]
//   0x88 CLASS_MATCH_COUNT exact predicted-class matches when evaluation enabled
//
// Classification is intentionally lightweight and deterministic. It implements
// the signatures documented by the referenced CAN-IDS project and adds three
// stateful/configurable automotive checks:
//   DoS    : ID 0x000, DLC 8, all-zero payload
//   Fuzzy  : illegal DLC or identifier outside the two-entry allowlist
//   Spoof  : allowed engine ID with payload FFFFFFFF_00000000
//   Replay : an identical frame arrives inside REPLAY_WINDOW
//   Flood  : any frame arrives inside FLOOD_THRESHOLD
//   Modify : protected payload bits differ from their configured expected value
// Priority is DoS, spoofing, replay, modification, flooding, fuzzy, normal.
//
// EVAL_LABEL is verification instrumentation. A testbench or validation
// program writes the known ground truth before submitting a frame. The RTL then
// accumulates TP/TN/FP/FN counters. Detection rate/recall, precision and FPR are
// calculated by software to avoid a large always-active divider in this
// low-power block:
//   recall = detection rate = TP/(TP+FN)
//   precision             = TP/(TP+FP)
//   false-positive rate   = FP/(FP+TN)
//
// This block is a synthesizable hardware pre-filter, not a claim that the
// report's scikit-learn Random Forest has been synthesized. A trained model was
// not supplied with the report. Software may read the same feature registers,
// counters, and LAST_INTERVAL later to add exported tree-model inference.
//
// Expected software path with an MCP2515 CAN controller:
//   1. Read one complete CAN frame through the existing SPI MMIO peripheral.
//   2. Write ID, DLC, DATA_LO, and DATA_HI here.
//   3. Write CTRL.submit.
//   4. Read STATUS or service alert_irq_o through simple_intc.
// ============================================================
module can_ids_mmio (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clk_en_i,
    input  logic [31:0] addr_i,
    input  logic [31:0] write_data_i,
    input  logic        write_en_i,
    input  logic        read_en_i,
    input  logic        hw_submit_i,
    input  logic [10:0] hw_frame_id_i,
    input  logic [3:0]  hw_frame_dlc_i,
    input  logic [63:0] hw_frame_payload_i,
    input  logic        hw_frame_fd_i,
    output logic        hw_ready_o,
    output logic [31:0] read_data_o,
    output logic        alert_irq_o,
    output logic        alert_debug_o,
    output logic        active_o
);

    localparam logic [7:0] OFF_CTRL           = 8'h00;
    localparam logic [7:0] OFF_STATUS         = 8'h04;
    localparam logic [7:0] OFF_FRAME_ID       = 8'h08;
    localparam logic [7:0] OFF_FRAME_DLC      = 8'h0C;
    localparam logic [7:0] OFF_DATA_LO        = 8'h10;
    localparam logic [7:0] OFF_DATA_HI        = 8'h14;
    localparam logic [7:0] OFF_ALLOW_ID0      = 8'h18;
    localparam logic [7:0] OFF_ALLOW_ID1      = 8'h1C;
    localparam logic [7:0] OFF_SPOOF_LO       = 8'h20;
    localparam logic [7:0] OFF_SPOOF_HI       = 8'h24;
    localparam logic [7:0] OFF_NORMAL_COUNT   = 8'h28;
    localparam logic [7:0] OFF_ATTACK_COUNT   = 8'h2C;
    localparam logic [7:0] OFF_DOS_COUNT      = 8'h30;
    localparam logic [7:0] OFF_FUZZY_COUNT    = 8'h34;
    localparam logic [7:0] OFF_SPOOF_COUNT    = 8'h38;
    localparam logic [7:0] OFF_TOTAL_COUNT    = 8'h3C;
    localparam logic [7:0] OFF_LAST_ATTACK_ID = 8'h40;
    localparam logic [7:0] OFF_LAST_INTERVAL  = 8'h44;
    localparam logic [7:0] OFF_CAPABILITY     = 8'h48;
    localparam logic [7:0] OFF_EVAL_LABEL     = 8'h4C;
    localparam logic [7:0] OFF_TP_COUNT       = 8'h50;
    localparam logic [7:0] OFF_TN_COUNT       = 8'h54;
    localparam logic [7:0] OFF_FP_COUNT       = 8'h58;
    localparam logic [7:0] OFF_FN_COUNT       = 8'h5C;
    localparam logic [7:0] OFF_REPLAY_COUNT   = 8'h60;
    localparam logic [7:0] OFF_FLOOD_COUNT    = 8'h64;
    localparam logic [7:0] OFF_MODIFY_COUNT   = 8'h68;
    localparam logic [7:0] OFF_REPLAY_WINDOW  = 8'h6C;
    localparam logic [7:0] OFF_FLOOD_THRESHOLD= 8'h70;
    localparam logic [7:0] OFF_MODIFY_ID      = 8'h74;
    localparam logic [7:0] OFF_MODIFY_MASK_LO = 8'h78;
    localparam logic [7:0] OFF_MODIFY_MASK_HI = 8'h7C;
    localparam logic [7:0] OFF_MODIFY_EXP_LO  = 8'h80;
    localparam logic [7:0] OFF_MODIFY_EXP_HI  = 8'h84;
    localparam logic [7:0] OFF_CLASS_MATCH    = 8'h88;

    localparam logic [2:0] CLASS_NORMAL = 3'd0;
    localparam logic [2:0] CLASS_DOS    = 3'd1;
    localparam logic [2:0] CLASS_FUZZY  = 3'd2;
    localparam logic [2:0] CLASS_SPOOF  = 3'd3;
    localparam logic [2:0] CLASS_REPLAY = 3'd4;
    localparam logic [2:0] CLASS_FLOOD  = 3'd5;
    localparam logic [2:0] CLASS_MODIFY = 3'd6;

    logic [7:0]  reg_offset;
    logic        enable_reg;
    logic [10:0] frame_id_reg;
    logic [3:0]  frame_dlc_reg;
    logic [31:0] frame_data_lo_reg;
    logic [31:0] frame_data_hi_reg;
    logic [10:0] allow_id0_reg;
    logic [10:0] allow_id1_reg;
    logic [31:0] spoof_data_lo_reg;
    logic [31:0] spoof_data_hi_reg;

    logic [2:0]  last_class_reg;
    logic        last_valid_reg;
    logic [10:0] last_attack_id_reg;
    logic [31:0] normal_count_reg;
    logic [31:0] attack_count_reg;
    logic [31:0] dos_count_reg;
    logic [31:0] fuzzy_count_reg;
    logic [31:0] spoof_count_reg;
    logic [31:0] total_count_reg;
    logic [31:0] cycle_counter_reg;
    logic [31:0] last_submit_cycle_reg;
    logic [31:0] last_interval_reg;
    logic        last_frame_valid_reg;
    logic [10:0] last_frame_id_reg;
    logic [3:0]  last_frame_dlc_reg;
    logic [63:0] last_frame_payload_reg;
    logic        last_frame_fd_reg;

    logic        eval_enable_reg;
    logic        expected_attack_reg;
    logic [2:0]  expected_class_reg;
    logic [31:0] tp_count_reg;
    logic [31:0] tn_count_reg;
    logic [31:0] fp_count_reg;
    logic [31:0] fn_count_reg;
    logic [31:0] class_match_count_reg;
    logic [31:0] replay_count_reg;
    logic [31:0] flood_count_reg;
    logic [31:0] modify_count_reg;

    logic [31:0] replay_window_reg;
    logic [31:0] flood_threshold_reg;
    logic [10:0] modify_id_reg;
    logic [63:0] modify_mask_reg;
    logic [63:0] modify_expected_reg;

    logic [63:0] frame_payload;
    logic [63:0] spoof_payload;
    logic        dos_match;
    logic        spoof_match;
    logic        fuzzy_match;
    logic        replay_match;
    logic        flood_match;
    logic        modify_match;
    logic        classified_attack;
    logic [31:0] current_interval;
    logic [2:0]  classified_class;
    logic [10:0] classify_frame_id;
    logic [3:0]  classify_frame_dlc;
    logic [63:0] classify_frame_payload;
    logic        classify_frame_fd;

    assign reg_offset    = addr_i[7:0];
    assign frame_payload = {frame_data_hi_reg, frame_data_lo_reg};
    assign spoof_payload = {spoof_data_hi_reg, spoof_data_lo_reg};

    // Authenticated CAN-FD traffic from canfd_secoc_mmio has priority over the
    // legacy software staging registers for the cycle in which hw_submit_i is
    // asserted. Software submission remains unchanged when no hardware frame is
    // present.
    assign classify_frame_id      = hw_submit_i ? hw_frame_id_i      : frame_id_reg;
    assign classify_frame_dlc     = hw_submit_i ? hw_frame_dlc_i     : frame_dlc_reg;
    assign classify_frame_payload = hw_submit_i ? hw_frame_payload_i : frame_payload;
    assign classify_frame_fd      = hw_submit_i ? hw_frame_fd_i      : 1'b0;
    assign hw_ready_o             = clk_en_i && enable_reg;

    assign dos_match = (classify_frame_id == 11'h000) &&
                       (classify_frame_dlc == 4'd8) &&
                       (classify_frame_payload == 64'h0000_0000_0000_0000);

    assign spoof_match = (classify_frame_id == allow_id0_reg) &&
                         (classify_frame_dlc == 4'd8) &&
                         (classify_frame_payload == spoof_payload);

    assign fuzzy_match = ((!classify_frame_fd) && (classify_frame_dlc > 4'd8)) ||
                         ((classify_frame_id != allow_id0_reg) &&
                          (classify_frame_id != allow_id1_reg));

    assign current_interval = cycle_counter_reg - last_submit_cycle_reg;

    assign replay_match = last_frame_valid_reg &&
                          (current_interval <= replay_window_reg) &&
                          (classify_frame_id == last_frame_id_reg) &&
                          (classify_frame_dlc == last_frame_dlc_reg) &&
                          (classify_frame_fd == last_frame_fd_reg) &&
                          (classify_frame_payload == last_frame_payload_reg);

    assign flood_match = last_frame_valid_reg &&
                         (current_interval <= flood_threshold_reg);

    assign modify_match = (modify_mask_reg != 64'h0) &&
                          (classify_frame_id == modify_id_reg) &&
                          ((classify_frame_dlc == 4'd8) ||
                           (classify_frame_fd && (classify_frame_dlc >= 4'd8))) &&
                          ((classify_frame_payload & modify_mask_reg) !=
                           (modify_expected_reg & modify_mask_reg));

    always_comb begin
        if (dos_match) begin
            classified_class = CLASS_DOS;
        end else if (spoof_match) begin
            classified_class = CLASS_SPOOF;
        end else if (replay_match) begin
            classified_class = CLASS_REPLAY;
        end else if (modify_match) begin
            classified_class = CLASS_MODIFY;
        end else if (flood_match) begin
            classified_class = CLASS_FLOOD;
        end else if (fuzzy_match) begin
            classified_class = CLASS_FUZZY;
        end else begin
            classified_class = CLASS_NORMAL;
        end
    end

    assign classified_attack = (classified_class != CLASS_NORMAL);

    assign alert_irq_o   = alert_debug_o;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_reg            <= 1'b1;
            frame_id_reg          <= 11'h0;
            frame_dlc_reg         <= 4'h0;
            frame_data_lo_reg     <= 32'h0;
            frame_data_hi_reg     <= 32'h0;
            allow_id0_reg         <= 11'h0C3;
            allow_id1_reg         <= 11'h145;
            spoof_data_lo_reg     <= 32'h0000_0000;
            spoof_data_hi_reg     <= 32'hFFFF_FFFF;
            last_class_reg        <= CLASS_NORMAL;
            last_valid_reg        <= 1'b0;
            last_attack_id_reg    <= 11'h0;
            normal_count_reg      <= 32'h0;
            attack_count_reg      <= 32'h0;
            dos_count_reg         <= 32'h0;
            fuzzy_count_reg       <= 32'h0;
            spoof_count_reg       <= 32'h0;
            total_count_reg       <= 32'h0;
            cycle_counter_reg     <= 32'h0;
            last_submit_cycle_reg <= 32'h0;
            last_interval_reg     <= 32'h0;
            last_frame_valid_reg  <= 1'b0;
            last_frame_id_reg     <= 11'h0;
            last_frame_dlc_reg    <= 4'h0;
            last_frame_payload_reg<= 64'h0;
            last_frame_fd_reg     <= 1'b0;
            eval_enable_reg       <= 1'b0;
            expected_attack_reg   <= 1'b0;
            expected_class_reg    <= CLASS_NORMAL;
            tp_count_reg          <= 32'h0;
            tn_count_reg          <= 32'h0;
            fp_count_reg          <= 32'h0;
            fn_count_reg          <= 32'h0;
            class_match_count_reg <= 32'h0;
            replay_count_reg      <= 32'h0;
            flood_count_reg       <= 32'h0;
            modify_count_reg      <= 32'h0;
            replay_window_reg     <= 32'd64;
            flood_threshold_reg   <= 32'd2;
            modify_id_reg         <= 11'h145;
            modify_mask_reg       <= 64'hFFFF_0000_0000_0000;
            modify_expected_reg   <= 64'h0000_0000_0000_0000;
            alert_debug_o         <= 1'b0;
            active_o              <= 1'b0;
        end else if (clk_en_i) begin
            cycle_counter_reg <= cycle_counter_reg + 32'd1;
            active_o          <= 1'b0;

            if (write_en_i) begin
                case (reg_offset)
                    OFF_FRAME_ID:  frame_id_reg      <= write_data_i[10:0];
                    OFF_FRAME_DLC: frame_dlc_reg     <= write_data_i[3:0];
                    OFF_DATA_LO:   frame_data_lo_reg <= write_data_i;
                    OFF_DATA_HI:   frame_data_hi_reg <= write_data_i;
                    OFF_ALLOW_ID0: allow_id0_reg     <= write_data_i[10:0];
                    OFF_ALLOW_ID1: allow_id1_reg     <= write_data_i[10:0];
                    OFF_SPOOF_LO:  spoof_data_lo_reg <= write_data_i;
                    OFF_SPOOF_HI:  spoof_data_hi_reg <= write_data_i;
                    OFF_EVAL_LABEL: begin
                        expected_attack_reg <= write_data_i[0];
                        expected_class_reg  <= write_data_i[3:1];
                        eval_enable_reg     <= write_data_i[4];
                    end
                    OFF_REPLAY_WINDOW:   replay_window_reg   <= write_data_i;
                    OFF_FLOOD_THRESHOLD: flood_threshold_reg <= write_data_i;
                    OFF_MODIFY_ID:       modify_id_reg       <= write_data_i[10:0];
                    OFF_MODIFY_MASK_LO:  modify_mask_reg[31:0]   <= write_data_i;
                    OFF_MODIFY_MASK_HI:  modify_mask_reg[63:32]  <= write_data_i;
                    OFF_MODIFY_EXP_LO:   modify_expected_reg[31:0]  <= write_data_i;
                    OFF_MODIFY_EXP_HI:   modify_expected_reg[63:32] <= write_data_i;

                    OFF_CTRL: begin
                        if (write_data_i[3]) enable_reg <= 1'b1;
                        if (write_data_i[4]) enable_reg <= 1'b0;
                        if (write_data_i[1]) alert_debug_o <= 1'b0;

                        if (write_data_i[2]) begin
                            normal_count_reg <= 32'h0;
                            attack_count_reg <= 32'h0;
                            dos_count_reg    <= 32'h0;
                            fuzzy_count_reg  <= 32'h0;
                            spoof_count_reg  <= 32'h0;
                            total_count_reg  <= 32'h0;
                            replay_count_reg <= 32'h0;
                            flood_count_reg  <= 32'h0;
                            modify_count_reg <= 32'h0;
                            tp_count_reg     <= 32'h0;
                            tn_count_reg     <= 32'h0;
                            fp_count_reg     <= 32'h0;
                            fn_count_reg     <= 32'h0;
                            class_match_count_reg <= 32'h0;
                        end else if (write_data_i[0] && !hw_submit_i &&
                                     (enable_reg || write_data_i[3]) &&
                                     !write_data_i[4]) begin
                            active_o              <= 1'b1;
                            last_valid_reg        <= 1'b1;
                            last_class_reg        <= classified_class;
                            last_interval_reg     <= cycle_counter_reg - last_submit_cycle_reg;
                            last_submit_cycle_reg <= cycle_counter_reg;
                            last_frame_valid_reg  <= 1'b1;
                            last_frame_id_reg     <= frame_id_reg;
                            last_frame_dlc_reg    <= frame_dlc_reg;
                            last_frame_payload_reg<= frame_payload;
                            last_frame_fd_reg     <= 1'b0;
                            total_count_reg       <= total_count_reg + 32'd1;

                            if (eval_enable_reg) begin
                                if (expected_attack_reg && classified_attack)
                                    tp_count_reg <= tp_count_reg + 32'd1;
                                else if (!expected_attack_reg && !classified_attack)
                                    tn_count_reg <= tn_count_reg + 32'd1;
                                else if (!expected_attack_reg && classified_attack)
                                    fp_count_reg <= fp_count_reg + 32'd1;
                                else
                                    fn_count_reg <= fn_count_reg + 32'd1;

                                if (classified_class == expected_class_reg)
                                    class_match_count_reg <= class_match_count_reg + 32'd1;
                            end

                            case (classified_class)
                                CLASS_DOS: begin
                                    alert_debug_o      <= 1'b1;
                                    last_attack_id_reg <= frame_id_reg;
                                    attack_count_reg   <= attack_count_reg + 32'd1;
                                    dos_count_reg      <= dos_count_reg + 32'd1;
                                end
                                CLASS_FUZZY: begin
                                    alert_debug_o      <= 1'b1;
                                    last_attack_id_reg <= frame_id_reg;
                                    attack_count_reg   <= attack_count_reg + 32'd1;
                                    fuzzy_count_reg    <= fuzzy_count_reg + 32'd1;
                                end
                                CLASS_SPOOF: begin
                                    alert_debug_o      <= 1'b1;
                                    last_attack_id_reg <= frame_id_reg;
                                    attack_count_reg   <= attack_count_reg + 32'd1;
                                    spoof_count_reg    <= spoof_count_reg + 32'd1;
                                end
                                CLASS_REPLAY: begin
                                    alert_debug_o      <= 1'b1;
                                    last_attack_id_reg <= frame_id_reg;
                                    attack_count_reg   <= attack_count_reg + 32'd1;
                                    replay_count_reg   <= replay_count_reg + 32'd1;
                                end
                                CLASS_FLOOD: begin
                                    alert_debug_o      <= 1'b1;
                                    last_attack_id_reg <= frame_id_reg;
                                    attack_count_reg   <= attack_count_reg + 32'd1;
                                    flood_count_reg    <= flood_count_reg + 32'd1;
                                end
                                CLASS_MODIFY: begin
                                    alert_debug_o      <= 1'b1;
                                    last_attack_id_reg <= frame_id_reg;
                                    attack_count_reg   <= attack_count_reg + 32'd1;
                                    modify_count_reg   <= modify_count_reg + 32'd1;
                                end
                                default: begin
                                    normal_count_reg <= normal_count_reg + 32'd1;
                                end
                            endcase
                        end
                    end
                    default: ;
                endcase
            end

            // Hardware frames have already passed SecOC authentication. They
            // still traverse the same IDS rules and counters as software-fed
            // frames, preserving one source of classification truth.
            if (hw_submit_i && enable_reg) begin
                active_o               <= 1'b1;
                last_valid_reg         <= 1'b1;
                last_class_reg         <= classified_class;
                last_interval_reg      <= cycle_counter_reg - last_submit_cycle_reg;
                last_submit_cycle_reg  <= cycle_counter_reg;
                last_frame_valid_reg   <= 1'b1;
                last_frame_id_reg      <= classify_frame_id;
                last_frame_dlc_reg     <= classify_frame_dlc;
                last_frame_payload_reg <= classify_frame_payload;
                last_frame_fd_reg      <= classify_frame_fd;
                total_count_reg        <= total_count_reg + 32'd1;

                if (eval_enable_reg) begin
                    if (expected_attack_reg && classified_attack)
                        tp_count_reg <= tp_count_reg + 32'd1;
                    else if (!expected_attack_reg && !classified_attack)
                        tn_count_reg <= tn_count_reg + 32'd1;
                    else if (!expected_attack_reg && classified_attack)
                        fp_count_reg <= fp_count_reg + 32'd1;
                    else
                        fn_count_reg <= fn_count_reg + 32'd1;

                    if (classified_class == expected_class_reg)
                        class_match_count_reg <= class_match_count_reg + 32'd1;
                end

                case (classified_class)
                    CLASS_DOS: begin
                        alert_debug_o      <= 1'b1;
                        last_attack_id_reg <= classify_frame_id;
                        attack_count_reg   <= attack_count_reg + 32'd1;
                        dos_count_reg      <= dos_count_reg + 32'd1;
                    end
                    CLASS_FUZZY: begin
                        alert_debug_o      <= 1'b1;
                        last_attack_id_reg <= classify_frame_id;
                        attack_count_reg   <= attack_count_reg + 32'd1;
                        fuzzy_count_reg    <= fuzzy_count_reg + 32'd1;
                    end
                    CLASS_SPOOF: begin
                        alert_debug_o      <= 1'b1;
                        last_attack_id_reg <= classify_frame_id;
                        attack_count_reg   <= attack_count_reg + 32'd1;
                        spoof_count_reg    <= spoof_count_reg + 32'd1;
                    end
                    CLASS_REPLAY: begin
                        alert_debug_o      <= 1'b1;
                        last_attack_id_reg <= classify_frame_id;
                        attack_count_reg   <= attack_count_reg + 32'd1;
                        replay_count_reg   <= replay_count_reg + 32'd1;
                    end
                    CLASS_FLOOD: begin
                        alert_debug_o      <= 1'b1;
                        last_attack_id_reg <= classify_frame_id;
                        attack_count_reg   <= attack_count_reg + 32'd1;
                        flood_count_reg    <= flood_count_reg + 32'd1;
                    end
                    CLASS_MODIFY: begin
                        alert_debug_o      <= 1'b1;
                        last_attack_id_reg <= classify_frame_id;
                        attack_count_reg   <= attack_count_reg + 32'd1;
                        modify_count_reg   <= modify_count_reg + 32'd1;
                    end
                    default: normal_count_reg <= normal_count_reg + 32'd1;
                endcase
            end
        end
    end

    always_comb begin
        read_data_o = 32'h0;
        if (read_en_i) begin
            case (reg_offset)
                OFF_CTRL:          read_data_o = {28'h0, enable_reg, 3'h0};
                OFF_STATUS:        read_data_o = {25'h0,
                                                  (last_class_reg != CLASS_NORMAL),
                                                  enable_reg,
                                                  last_valid_reg,
                                                  last_class_reg,
                                                  alert_debug_o};
                OFF_FRAME_ID:      read_data_o = {21'h0, frame_id_reg};
                OFF_FRAME_DLC:     read_data_o = {28'h0, frame_dlc_reg};
                OFF_DATA_LO:       read_data_o = frame_data_lo_reg;
                OFF_DATA_HI:       read_data_o = frame_data_hi_reg;
                OFF_ALLOW_ID0:     read_data_o = {21'h0, allow_id0_reg};
                OFF_ALLOW_ID1:     read_data_o = {21'h0, allow_id1_reg};
                OFF_SPOOF_LO:      read_data_o = spoof_data_lo_reg;
                OFF_SPOOF_HI:      read_data_o = spoof_data_hi_reg;
                OFF_NORMAL_COUNT:  read_data_o = normal_count_reg;
                OFF_ATTACK_COUNT:  read_data_o = attack_count_reg;
                OFF_DOS_COUNT:     read_data_o = dos_count_reg;
                OFF_FUZZY_COUNT:   read_data_o = fuzzy_count_reg;
                OFF_SPOOF_COUNT:   read_data_o = spoof_count_reg;
                OFF_TOTAL_COUNT:   read_data_o = total_count_reg;
                OFF_LAST_ATTACK_ID:read_data_o = {21'h0, last_attack_id_reg};
                OFF_LAST_INTERVAL: read_data_o = last_interval_reg;
                OFF_CAPABILITY:    read_data_o = 32'h0002_007F;
                OFF_EVAL_LABEL:    read_data_o = {27'h0, eval_enable_reg,
                                                   expected_class_reg,
                                                   expected_attack_reg};
                OFF_TP_COUNT:      read_data_o = tp_count_reg;
                OFF_TN_COUNT:      read_data_o = tn_count_reg;
                OFF_FP_COUNT:      read_data_o = fp_count_reg;
                OFF_FN_COUNT:      read_data_o = fn_count_reg;
                OFF_REPLAY_COUNT:  read_data_o = replay_count_reg;
                OFF_FLOOD_COUNT:   read_data_o = flood_count_reg;
                OFF_MODIFY_COUNT:  read_data_o = modify_count_reg;
                OFF_REPLAY_WINDOW: read_data_o = replay_window_reg;
                OFF_FLOOD_THRESHOLD:read_data_o = flood_threshold_reg;
                OFF_MODIFY_ID:     read_data_o = {21'h0, modify_id_reg};
                OFF_MODIFY_MASK_LO:read_data_o = modify_mask_reg[31:0];
                OFF_MODIFY_MASK_HI:read_data_o = modify_mask_reg[63:32];
                OFF_MODIFY_EXP_LO: read_data_o = modify_expected_reg[31:0];
                OFF_MODIFY_EXP_HI: read_data_o = modify_expected_reg[63:32];
                OFF_CLASS_MATCH:   read_data_o = class_match_count_reg;
                default:           read_data_o = 32'h0;
            endcase
        end
    end

endmodule
