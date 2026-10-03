// ============================================================================
// CAN-IDS UVM-style verification package
//
// Components:
//   sequences : emit directed boundary cases and constrained-random traffic
//   driver    : programs can_ids_mmio through MMIO tasks
//   monitor   : samples the result stream from the virtual interface
//   scoreboard: checks class, confusion matrix, counters, and alert behavior
//   coverage  : portable functional coverage plus optional native covergroups
// ============================================================================
package can_ids_uvm_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam logic [7:0] OFF_CTRL            = 8'h00;
    localparam logic [7:0] OFF_STATUS          = 8'h04;
    localparam logic [7:0] OFF_FRAME_ID        = 8'h08;
    localparam logic [7:0] OFF_FRAME_DLC       = 8'h0C;
    localparam logic [7:0] OFF_DATA_LO         = 8'h10;
    localparam logic [7:0] OFF_DATA_HI         = 8'h14;
    localparam logic [7:0] OFF_ALLOW_ID0       = 8'h18;
    localparam logic [7:0] OFF_ALLOW_ID1       = 8'h1C;
    localparam logic [7:0] OFF_NORMAL_COUNT    = 8'h28;
    localparam logic [7:0] OFF_ATTACK_COUNT    = 8'h2C;
    localparam logic [7:0] OFF_DOS_COUNT       = 8'h30;
    localparam logic [7:0] OFF_FUZZY_COUNT     = 8'h34;
    localparam logic [7:0] OFF_SPOOF_COUNT     = 8'h38;
    localparam logic [7:0] OFF_TOTAL_COUNT     = 8'h3C;
    localparam logic [7:0] OFF_LAST_ATTACK_ID  = 8'h40;
    localparam logic [7:0] OFF_EVAL_LABEL      = 8'h4C;
    localparam logic [7:0] OFF_TP_COUNT        = 8'h50;
    localparam logic [7:0] OFF_TN_COUNT        = 8'h54;
    localparam logic [7:0] OFF_FP_COUNT        = 8'h58;
    localparam logic [7:0] OFF_FN_COUNT        = 8'h5C;
    localparam logic [7:0] OFF_REPLAY_COUNT    = 8'h60;
    localparam logic [7:0] OFF_FLOOD_COUNT     = 8'h64;
    localparam logic [7:0] OFF_MODIFY_COUNT    = 8'h68;
    localparam logic [7:0] OFF_REPLAY_WINDOW   = 8'h6C;
    localparam logic [7:0] OFF_FLOOD_THRESHOLD = 8'h70;
    localparam logic [7:0] OFF_MODIFY_ID       = 8'h74;
    localparam logic [7:0] OFF_MODIFY_MASK_LO  = 8'h78;
    localparam logic [7:0] OFF_MODIFY_MASK_HI  = 8'h7C;
    localparam logic [7:0] OFF_MODIFY_EXP_LO   = 8'h80;
    localparam logic [7:0] OFF_MODIFY_EXP_HI   = 8'h84;
    localparam logic [7:0] OFF_CLASS_MATCH     = 8'h88;

    localparam logic [2:0] CLASS_NORMAL = 3'd0;
    localparam logic [2:0] CLASS_DOS    = 3'd1;
    localparam logic [2:0] CLASS_FUZZY  = 3'd2;
    localparam logic [2:0] CLASS_SPOOF  = 3'd3;
    localparam logic [2:0] CLASS_REPLAY = 3'd4;
    localparam logic [2:0] CLASS_FLOOD  = 3'd5;
    localparam logic [2:0] CLASS_MODIFY = 3'd6;

    localparam logic [2:0] STIM_NORMAL        = 3'd0;
    localparam logic [2:0] STIM_DOS           = 3'd1;
    localparam logic [2:0] STIM_FUZZY_UNKNOWN = 3'd2;
    localparam logic [2:0] STIM_FUZZY_ILLEGAL = 3'd3;
    localparam logic [2:0] STIM_SPOOF         = 3'd4;
    localparam logic [2:0] STIM_MODIFY        = 3'd5;

    function string class_name(input logic [2:0] cls);
        case (cls)
            CLASS_NORMAL: return "NORMAL";
            CLASS_DOS:    return "DOS";
            CLASS_FUZZY:  return "FUZZY";
            CLASS_SPOOF:  return "SPOOF";
            CLASS_REPLAY: return "REPLAY";
            CLASS_FLOOD:  return "FLOOD";
            CLASS_MODIFY: return "MODIFY";
            default:      return "UNKNOWN";
        endcase
    endfunction

    function string case_name(input int unsigned case_id);
        if (case_id >= 1000) begin
            return $sformatf("random_%0d", case_id - 1000);
        end
        case (case_id)
            0: return "normal_allow1";
            1: return "dos_zero_id";
            2: return "fuzzy_unknown_id";
            3: return "fuzzy_illegal_dlc";
            4: return "spoof_signature";
            5: return "replay_seed_normal";
            6: return "replay_duplicate";
            7: return "flood_fast_frame";
            8: return "modify_protected_payload";
            default: return "unknown_case";
        endcase
    endfunction

    class can_ids_item extends uvm_sequence_item;
        rand bit [10:0] can_id;
        rand bit [3:0]  dlc;
        rand bit [63:0] payload;
        rand bit [2:0]  stimulus_kind;
        rand int unsigned pre_gap_cycles;

        int unsigned case_id;
        bit is_random;
        bit expected_attack;
        bit [2:0] expected_class;
        bit set_flood_threshold;
        bit [31:0] flood_threshold;

        bit observed_attack;
        bit [2:0] observed_class;
        bit status_valid;
        bit alert;
        bit alert_irq_match;
        bit [31:0] total_count;
        bit [31:0] normal_count;
        bit [31:0] attack_count;
        bit [31:0] dos_count;
        bit [31:0] fuzzy_count;
        bit [31:0] spoof_count;
        bit [31:0] replay_count;
        bit [31:0] flood_count;
        bit [31:0] modify_count;
        bit [31:0] tp_count;
        bit [31:0] tn_count;
        bit [31:0] fp_count;
        bit [31:0] fn_count;
        bit [31:0] class_match_count;
        bit [10:0] last_attack_id;

        `uvm_object_utils_begin(can_ids_item)
            `uvm_field_int(can_id, UVM_ALL_ON)
            `uvm_field_int(dlc, UVM_ALL_ON)
            `uvm_field_int(payload, UVM_ALL_ON)
            `uvm_field_int(stimulus_kind, UVM_ALL_ON)
            `uvm_field_int(case_id, UVM_ALL_ON)
            `uvm_field_int(is_random, UVM_ALL_ON)
            `uvm_field_int(expected_attack, UVM_ALL_ON)
            `uvm_field_int(expected_class, UVM_ALL_ON)
            `uvm_field_int(observed_attack, UVM_ALL_ON)
            `uvm_field_int(observed_class, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "can_ids_item");
            super.new(name);
        endfunction

    endclass

    class can_ids_sequence extends uvm_sequence #(can_ids_item);
        `uvm_object_utils(can_ids_sequence)

        function new(string name = "can_ids_sequence");
            super.new(name);
        endfunction

        task emit_case(
            input int unsigned case_id,
            input bit [10:0] can_id,
            input bit [3:0] dlc,
            input bit [63:0] payload,
            input bit expected_attack,
            input bit [2:0] expected_class,
            input int unsigned pre_gap_cycles,
            input bit set_flood_threshold = 1'b0,
            input bit [31:0] flood_threshold = 32'd2
        );
            can_ids_item tr;
            tr = can_ids_item::type_id::create($sformatf("case_%0d", case_id));
            start_item(tr);
            tr.case_id = case_id;
            tr.is_random = 1'b0;
            tr.can_id = can_id;
            tr.dlc = dlc;
            tr.payload = payload;
            tr.expected_attack = expected_attack;
            tr.expected_class = expected_class;
            tr.pre_gap_cycles = pre_gap_cycles;
            tr.set_flood_threshold = set_flood_threshold;
            tr.flood_threshold = flood_threshold;
            finish_item(tr);
        endtask

        task body();
            emit_case(0, 11'h145, 4'd8, 64'h0000_0000_0000_0123,
                      1'b0, CLASS_NORMAL, 8);
            emit_case(1, 11'h000, 4'd8, 64'h0000_0000_0000_0000,
                      1'b1, CLASS_DOS, 8);
            emit_case(2, 11'h7AB, 4'd8, 64'h1111_2222_3333_4444,
                      1'b1, CLASS_FUZZY, 8);
            emit_case(3, 11'h145, 4'd9, 64'h0000_0000_0000_0123,
                      1'b1, CLASS_FUZZY, 8);
            emit_case(4, 11'h0C3, 4'd8, 64'hFFFF_FFFF_0000_0000,
                      1'b1, CLASS_SPOOF, 8);
            emit_case(5, 11'h0C3, 4'd8, 64'h0000_0000_1111_2222,
                      1'b0, CLASS_NORMAL, 8);
            emit_case(6, 11'h0C3, 4'd8, 64'h0000_0000_1111_2222,
                      1'b1, CLASS_REPLAY, 0);
            emit_case(7, 11'h0C3, 4'd8, 64'h0000_0000_3333_4444,
                      1'b1, CLASS_FLOOD, 0, 1'b1, 32'd128);
            emit_case(8, 11'h145, 4'd8, 64'hA5A5_0000_0000_0123,
                      1'b1, CLASS_MODIFY, 8, 1'b1, 32'd2);
        endtask
    endclass

    class can_ids_random_sequence extends uvm_sequence #(can_ids_item);
        `uvm_object_utils(can_ids_random_sequence)

        int unsigned transaction_count = 200;

        function new(string name = "can_ids_random_sequence");
            super.new(name);
        endfunction

        function void set_expected(can_ids_item tr);
            tr.expected_attack = 1'b1;
            case (tr.stimulus_kind)
                STIM_NORMAL: begin
                    tr.expected_attack = 1'b0;
                    tr.expected_class = CLASS_NORMAL;
                end
                STIM_DOS:           tr.expected_class = CLASS_DOS;
                STIM_FUZZY_UNKNOWN: tr.expected_class = CLASS_FUZZY;
                STIM_FUZZY_ILLEGAL: tr.expected_class = CLASS_FUZZY;
                STIM_SPOOF:         tr.expected_class = CLASS_SPOOF;
                STIM_MODIFY:        tr.expected_class = CLASS_MODIFY;
                default: begin
                    tr.expected_attack = 1'b0;
                    tr.expected_class = CLASS_NORMAL;
                end
            endcase
        endfunction

        function bit [2:0] weighted_stimulus_kind();
            int unsigned choice;
            choice = $urandom_range(99, 0);
            if (choice < 30) return STIM_NORMAL;
            if (choice < 40) return STIM_DOS;
            if (choice < 60) return STIM_FUZZY_UNKNOWN;
            if (choice < 70) return STIM_FUZZY_ILLEGAL;
            if (choice < 85) return STIM_SPOOF;
            return STIM_MODIFY;
        endfunction

        function void populate_constrained_random(can_ids_item tr, input int forced_kind = -1);
            bit [10:0] candidate_id;

            tr.stimulus_kind = (forced_kind >= 0) ? forced_kind[2:0] :
                                                   weighted_stimulus_kind();
            tr.pre_gap_cycles = $urandom_range(120, 70);
            tr.payload = {$urandom(), $urandom()};

            case (tr.stimulus_kind)
                STIM_NORMAL: begin
                    tr.can_id = $urandom_range(1, 0) ? 11'h145 : 11'h0C3;
                    tr.dlc = $urandom_range(8, 0);
                    if ((tr.can_id == 11'h0C3) && (tr.dlc == 4'd8) &&
                        (tr.payload == 64'hFFFF_FFFF_0000_0000)) begin
                        tr.payload[0] = ~tr.payload[0];
                    end
                    if ((tr.can_id == 11'h145) && (tr.dlc == 4'd8)) begin
                        tr.payload[63:48] = 16'h0000;
                    end
                end
                STIM_DOS: begin
                    tr.can_id = 11'h000;
                    tr.dlc = 4'd8;
                    tr.payload = 64'h0000_0000_0000_0000;
                end
                STIM_FUZZY_UNKNOWN: begin
                    candidate_id = $urandom_range(11'h7FF, 11'h001);
                    while ((candidate_id == 11'h0C3) || (candidate_id == 11'h145)) begin
                        candidate_id = $urandom_range(11'h7FF, 11'h001);
                    end
                    tr.can_id = candidate_id;
                    tr.dlc = $urandom_range(8, 0);
                end
                STIM_FUZZY_ILLEGAL: begin
                    tr.can_id = $urandom_range(1, 0) ? 11'h145 : 11'h0C3;
                    tr.dlc = $urandom_range(15, 9);
                end
                STIM_SPOOF: begin
                    tr.can_id = 11'h0C3;
                    tr.dlc = 4'd8;
                    tr.payload = 64'hFFFF_FFFF_0000_0000;
                end
                STIM_MODIFY: begin
                    tr.can_id = 11'h145;
                    tr.dlc = 4'd8;
                    tr.payload[63:48] = $urandom_range(16'hFFFF, 16'h0001);
                end
                default: begin
                    tr.can_id = 11'h0C3;
                    tr.dlc = 4'd0;
                    tr.payload = 64'h0;
                end
            endcase
        endfunction

        task emit_random(input int unsigned index, input int forced_kind = -1);
            can_ids_item tr;
            tr = can_ids_item::type_id::create($sformatf("random_case_%0d", index));
            start_item(tr);
            populate_constrained_random(tr, forced_kind);
            tr.case_id = 1000 + index;
            tr.is_random = 1'b1;
            tr.set_flood_threshold = 1'b0;
            tr.flood_threshold = 32'd2;
            set_expected(tr);
            finish_item(tr);
        endtask

        task body();
            if (transaction_count < 6) begin
                `uvm_fatal("RAND_COUNT", "At least six random transactions are required for stimulus-kind coverage")
            end

            // Force one randomized sample from each legal family, then let the
            // remaining samples follow the weighted seeded distribution.
            for (int unsigned kind = STIM_NORMAL; kind <= STIM_MODIFY; kind++) begin
                emit_random(kind, kind);
            end
            for (int unsigned index = 6; index < transaction_count; index++) begin
                emit_random(index);
            end
        endtask
    endclass

    class can_ids_sequencer extends uvm_sequencer #(can_ids_item);
        `uvm_component_utils(can_ids_sequencer)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    class can_ids_driver extends uvm_driver #(can_ids_item);
        `uvm_component_utils(can_ids_driver)

        virtual can_ids_uvm_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual can_ids_uvm_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "can_ids_uvm_if was not set for driver")
            end
        endfunction

        task configure_defaults();
            vif.mmio_write(OFF_ALLOW_ID0, 32'h0000_00C3);
            vif.mmio_write(OFF_ALLOW_ID1, 32'h0000_0145);
            vif.mmio_write(OFF_REPLAY_WINDOW, 32'd64);
            vif.mmio_write(OFF_FLOOD_THRESHOLD, 32'd2);
            vif.mmio_write(OFF_MODIFY_ID, 32'h0000_0145);
            vif.mmio_write(OFF_MODIFY_MASK_LO, 32'h0000_0000);
            vif.mmio_write(OFF_MODIFY_MASK_HI, 32'hFFFF_0000);
            vif.mmio_write(OFF_MODIFY_EXP_LO, 32'h0000_0000);
            vif.mmio_write(OFF_MODIFY_EXP_HI, 32'h0000_0000);
            vif.mmio_write(OFF_CTRL, 32'h0000_000E); // clear alert/counters and enable
        endtask

        task drive_one(can_ids_item tr);
            logic [31:0] status;
            logic [31:0] tmp;

            vif.wait_cycles(tr.pre_gap_cycles);
            if (tr.set_flood_threshold) begin
                vif.mmio_write(OFF_FLOOD_THRESHOLD, tr.flood_threshold);
            end

            vif.mmio_write(OFF_FRAME_ID, {21'h0, tr.can_id});
            vif.mmio_write(OFF_FRAME_DLC, {28'h0, tr.dlc});
            vif.mmio_write(OFF_DATA_LO, tr.payload[31:0]);
            vif.mmio_write(OFF_DATA_HI, tr.payload[63:32]);
            vif.mmio_write(OFF_EVAL_LABEL,
                           {27'h0, 1'b1, tr.expected_class, tr.expected_attack});
            vif.mmio_write(OFF_CTRL, 32'h0000_0001);
            vif.wait_cycles(2);

            vif.mmio_read(OFF_STATUS, status);
            tr.alert = status[0];
            tr.observed_class = status[3:1];
            tr.status_valid = status[4];
            tr.observed_attack = status[6];
            tr.alert_irq_match = (vif.alert_irq === vif.alert_debug);

            vif.mmio_read(OFF_TOTAL_COUNT, tr.total_count);
            vif.mmio_read(OFF_NORMAL_COUNT, tr.normal_count);
            vif.mmio_read(OFF_ATTACK_COUNT, tr.attack_count);
            vif.mmio_read(OFF_DOS_COUNT, tr.dos_count);
            vif.mmio_read(OFF_FUZZY_COUNT, tr.fuzzy_count);
            vif.mmio_read(OFF_SPOOF_COUNT, tr.spoof_count);
            vif.mmio_read(OFF_REPLAY_COUNT, tr.replay_count);
            vif.mmio_read(OFF_FLOOD_COUNT, tr.flood_count);
            vif.mmio_read(OFF_MODIFY_COUNT, tr.modify_count);
            vif.mmio_read(OFF_TP_COUNT, tr.tp_count);
            vif.mmio_read(OFF_TN_COUNT, tr.tn_count);
            vif.mmio_read(OFF_FP_COUNT, tr.fp_count);
            vif.mmio_read(OFF_FN_COUNT, tr.fn_count);
            vif.mmio_read(OFF_CLASS_MATCH, tr.class_match_count);
            vif.mmio_read(OFF_LAST_ATTACK_ID, tmp);
            tr.last_attack_id = tmp[10:0];

            vif.publish_sample(
                tr.case_id, tr.is_random, tr.stimulus_kind,
                tr.can_id, tr.dlc, tr.payload,
                tr.expected_attack, tr.expected_class,
                tr.observed_attack, tr.observed_class,
                tr.status_valid, tr.alert,
                tr.total_count, tr.normal_count, tr.attack_count,
                tr.dos_count, tr.fuzzy_count, tr.spoof_count,
                tr.replay_count, tr.flood_count, tr.modify_count,
                tr.tp_count, tr.tn_count, tr.fp_count, tr.fn_count,
                tr.class_match_count, tr.last_attack_id
            );
        endtask

        task run_phase(uvm_phase phase);
            can_ids_item tr;
            vif.apply_reset();
            configure_defaults();

            forever begin
                seq_item_port.get_next_item(tr);
                drive_one(tr);
                seq_item_port.item_done();
            end
        endtask
    endclass

    class can_ids_monitor extends uvm_component;
        `uvm_component_utils(can_ids_monitor)

        virtual can_ids_uvm_if vif;
        uvm_analysis_port #(can_ids_item) observed_ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            observed_ap = new("observed_ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual can_ids_uvm_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "can_ids_uvm_if was not set for monitor")
            end
        endfunction

        task run_phase(uvm_phase phase);
            can_ids_item obs;
            forever begin
                @(posedge vif.clk);
                if (vif.sample_valid) begin
                    obs = can_ids_item::type_id::create("obs");
                    obs.case_id = vif.obs_case_id;
                    obs.is_random = vif.obs_is_random;
                    obs.stimulus_kind = vif.obs_stimulus_kind;
                    obs.can_id = vif.obs_can_id;
                    obs.dlc = vif.obs_dlc;
                    obs.payload = vif.obs_payload;
                    obs.expected_attack = vif.obs_expected_attack;
                    obs.expected_class = vif.obs_expected_class;
                    obs.observed_attack = vif.obs_attack;
                    obs.observed_class = vif.obs_class;
                    obs.status_valid = vif.obs_status_valid;
                    obs.alert = vif.obs_alert;
                    obs.alert_irq_match = (vif.alert_irq === vif.alert_debug);
                    obs.total_count = vif.obs_total_count;
                    obs.normal_count = vif.obs_normal_count;
                    obs.attack_count = vif.obs_attack_count;
                    obs.dos_count = vif.obs_dos_count;
                    obs.fuzzy_count = vif.obs_fuzzy_count;
                    obs.spoof_count = vif.obs_spoof_count;
                    obs.replay_count = vif.obs_replay_count;
                    obs.flood_count = vif.obs_flood_count;
                    obs.modify_count = vif.obs_modify_count;
                    obs.tp_count = vif.obs_tp_count;
                    obs.tn_count = vif.obs_tn_count;
                    obs.fp_count = vif.obs_fp_count;
                    obs.fn_count = vif.obs_fn_count;
                    obs.class_match_count = vif.obs_class_match_count;
                    obs.last_attack_id = vif.obs_last_attack_id;
                    observed_ap.write(obs);
                end
            end
        endtask
    endclass

    class can_ids_agent extends uvm_agent;
        `uvm_component_utils(can_ids_agent)
        can_ids_sequencer seqr;
        can_ids_driver driver;
        can_ids_monitor monitor;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            seqr = can_ids_sequencer::type_id::create("seqr", this);
            driver = can_ids_driver::type_id::create("driver", this);
            monitor = can_ids_monitor::type_id::create("monitor", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(seqr.seq_item_export);
        endfunction
    endclass

    class can_ids_scoreboard extends uvm_component;
        `uvm_component_utils(can_ids_scoreboard)

        virtual can_ids_uvm_if vif;
        uvm_analysis_imp #(can_ids_item, can_ids_scoreboard) analysis_export;

        int unsigned checked_count;
        int unsigned mismatch_count;
        int unsigned random_checked_count;
        int unsigned expected_transactions = 9;
        int unsigned exp_total;
        int unsigned exp_normal;
        int unsigned exp_attack;
        int unsigned exp_dos;
        int unsigned exp_fuzzy;
        int unsigned exp_spoof;
        int unsigned exp_replay;
        int unsigned exp_flood;
        int unsigned exp_modify;
        int unsigned exp_tp;
        int unsigned exp_tn;
        int unsigned exp_fp;
        int unsigned exp_fn;
        int unsigned exp_class_match;
        bit [6:0] class_seen;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            analysis_export = new("analysis_export", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual can_ids_uvm_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "can_ids_uvm_if was not set for scoreboard")
            end
            void'(uvm_config_db#(int unsigned)::get(this, "", "expected_transactions",
                                                       expected_transactions));
        endfunction

        function void expect_counter(string label, bit [31:0] observed, int unsigned expected);
            if (observed !== expected[31:0]) begin
                mismatch_count++;
                `uvm_error("COUNTER",
                    $sformatf("%s observed %0d expected %0d",
                              label, observed, expected))
            end
        endfunction

        function void write(can_ids_item tr);
            checked_count++;
            if (tr.is_random) begin
                random_checked_count++;
            end
            exp_total++;
            class_seen[tr.expected_class] = 1'b1;

            if (tr.expected_attack) begin
                exp_attack++;
                exp_tp++;
            end else begin
                exp_normal++;
                exp_tn++;
            end

            case (tr.expected_class)
                CLASS_DOS:    exp_dos++;
                CLASS_FUZZY:  exp_fuzzy++;
                CLASS_SPOOF:  exp_spoof++;
                CLASS_REPLAY: exp_replay++;
                CLASS_FLOOD:  exp_flood++;
                CLASS_MODIFY: exp_modify++;
                default: ;
            endcase
            exp_class_match++;

            if (!tr.status_valid) begin
                mismatch_count++;
                `uvm_error("STATUS", $sformatf("%s did not set STATUS.valid",
                                               case_name(tr.case_id)))
            end
            if (tr.observed_class !== tr.expected_class) begin
                mismatch_count++;
                `uvm_error("CLASS",
                    $sformatf("%s observed class %s expected %s",
                              case_name(tr.case_id),
                              class_name(tr.observed_class),
                              class_name(tr.expected_class)))
            end
            if (tr.observed_attack !== tr.expected_attack) begin
                mismatch_count++;
                `uvm_error("ATTACK",
                    $sformatf("%s observed attack=%0d expected attack=%0d",
                              case_name(tr.case_id),
                              tr.observed_attack, tr.expected_attack))
            end
            if (!tr.alert_irq_match) begin
                mismatch_count++;
                `uvm_error("IRQ", "alert_irq_o and alert_debug_o diverged")
            end
            if (tr.expected_attack && (tr.last_attack_id !== tr.can_id)) begin
                mismatch_count++;
                `uvm_error("LAST_ID",
                    $sformatf("%s last_attack_id=%03h expected %03h",
                              case_name(tr.case_id),
                              tr.last_attack_id, tr.can_id))
            end

            expect_counter("TOTAL", tr.total_count, exp_total);
            expect_counter("NORMAL", tr.normal_count, exp_normal);
            expect_counter("ATTACK", tr.attack_count, exp_attack);
            expect_counter("DOS", tr.dos_count, exp_dos);
            expect_counter("FUZZY", tr.fuzzy_count, exp_fuzzy);
            expect_counter("SPOOF", tr.spoof_count, exp_spoof);
            expect_counter("REPLAY", tr.replay_count, exp_replay);
            expect_counter("FLOOD", tr.flood_count, exp_flood);
            expect_counter("MODIFY", tr.modify_count, exp_modify);
            expect_counter("TP", tr.tp_count, exp_tp);
            expect_counter("TN", tr.tn_count, exp_tn);
            expect_counter("FP", tr.fp_count, exp_fp);
            expect_counter("FN", tr.fn_count, exp_fn);
            expect_counter("CLASS_MATCH", tr.class_match_count, exp_class_match);

            if (mismatch_count == 0) begin
                vif.scoreboard_matches = checked_count;
            end else begin
                vif.scoreboard_mismatches = mismatch_count;
            end

            `uvm_info("CAN_IDS_MATCH",
                $sformatf("%0d %s ID=%03h DLC=%0d CLASS=%s TP=%0d TN=%0d FP=%0d FN=%0d",
                          checked_count, case_name(tr.case_id), tr.can_id, tr.dlc,
                          class_name(tr.observed_class), tr.tp_count, tr.tn_count,
                          tr.fp_count, tr.fn_count),
                UVM_LOW)
        endfunction

        function void check_phase(uvm_phase phase);
            if (checked_count != expected_transactions) begin
                `uvm_error("COUNT", $sformatf("Expected %0d CAN-IDS transactions, observed %0d",
                                              expected_transactions, checked_count))
            end
            if (class_seen != 7'b111_1111) begin
                `uvm_error("CLASS_COVER", $sformatf("Class coverage mask %07b did not cover all classes", class_seen))
            end
            if (mismatch_count != 0) begin
                `uvm_error("MISMATCH", $sformatf("CAN-IDS scoreboard recorded %0d mismatches", mismatch_count))
            end
        endfunction

        function void report_phase(uvm_phase phase);
            real detection_rate;
            real precision;
            real false_positive_rate;
            detection_rate = (exp_tp + exp_fn) == 0 ? 0.0 :
                             (100.0 * exp_tp) / (exp_tp + exp_fn);
            precision = (exp_tp + exp_fp) == 0 ? 0.0 :
                        (100.0 * exp_tp) / (exp_tp + exp_fp);
            false_positive_rate = (exp_fp + exp_tn) == 0 ? 0.0 :
                                  (100.0 * exp_fp) / (exp_fp + exp_tn);
            `uvm_info("CAN_IDS_METRICS",
                $sformatf("Detection rate=%0.2f%% Precision=%0.2f%% False-positive rate=%0.2f%% TP=%0d TN=%0d FP=%0d FN=%0d",
                          detection_rate, precision, false_positive_rate,
                          exp_tp, exp_tn, exp_fp, exp_fn),
                UVM_NONE)
            `uvm_info("RANDOM_SUMMARY",
                $sformatf("Constrained-random CAN-IDS transactions=%0d total transactions=%0d scoreboard mismatches=%0d",
                          random_checked_count, checked_count, mismatch_count),
                UVM_NONE)
        endfunction
    endclass

    class can_ids_coverage extends uvm_component;
        `uvm_component_utils(can_ids_coverage)

        virtual can_ids_uvm_if vif;
        uvm_analysis_imp #(can_ids_item, can_ids_coverage) analysis_export;
        int unsigned sampled_count;
        bit [6:0] class_bins;
        bit [1:0] attack_bins;
        bit [3:0] id_bins;
        bit [1:0] dlc_bins;
        bit [3:0] payload_bins;
        bit [1:0] source_bins;
        bit [5:0] random_kind_bins;
        bit tp_seen;
        bit tn_seen;
        bit fp_zero_seen;
        bit fn_zero_seen;
        bit class_match_seen;
        bit alert_sticky_seen;
        bit irq_match_seen;
        bit replay_behavior_seen;
        bit flood_behavior_seen;
        bit modify_behavior_seen;
        bit status_valid_seen;

`ifdef NATIVE_COVERGROUPS
        covergroup can_ids_cg with function sample(
            bit [10:0] can_id,
            bit [3:0] dlc,
            bit [2:0] observed_class,
            bit observed_attack,
            bit is_random,
            bit [2:0] stimulus_kind
        );
            option.per_instance = 1;
            option.name = "can_ids_classification_coverage";

            cp_class: coverpoint observed_class {
                bins normal = {CLASS_NORMAL};
                bins dos    = {CLASS_DOS};
                bins fuzzy  = {CLASS_FUZZY};
                bins spoof  = {CLASS_SPOOF};
                bins replay = {CLASS_REPLAY};
                bins flood  = {CLASS_FLOOD};
                bins modify = {CLASS_MODIFY};
            }
            cp_attack: coverpoint observed_attack {
                bins accepted = {1'b0};
                bins attack   = {1'b1};
            }
            cp_dlc: coverpoint dlc {
                bins legal[] = {[0:8]};
                bins illegal = {[9:15]};
            }
            cp_id: coverpoint can_id {
                bins zero = {11'h000};
                bins allow0 = {11'h0C3};
                bins allow1 = {11'h145};
                bins other = default;
            }
            attack_by_class: cross cp_attack, cp_class;
            cp_source: coverpoint is_random {
                bins directed = {1'b0};
                bins constrained_random = {1'b1};
            }
            cp_random_kind: coverpoint stimulus_kind iff (is_random) {
                bins normal = {STIM_NORMAL};
                bins dos = {STIM_DOS};
                bins fuzzy_unknown = {STIM_FUZZY_UNKNOWN};
                bins fuzzy_illegal = {STIM_FUZZY_ILLEGAL};
                bins spoof = {STIM_SPOOF};
                bins modify = {STIM_MODIFY};
            }
        endgroup
`endif

        function new(string name, uvm_component parent);
            super.new(name, parent);
            analysis_export = new("analysis_export", this);
`ifdef NATIVE_COVERGROUPS
            can_ids_cg = new();
`endif
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual can_ids_uvm_if)::get(this, "", "vif", vif)) begin
                `uvm_fatal("NOVIF", "can_ids_uvm_if was not set for coverage")
            end
        endfunction

        function int unsigned count_bits(input bit [31:0] mask, input int unsigned width);
            int unsigned count;
            count = 0;
            for (int i = 0; i < width; i++) begin
                count += mask[i];
            end
            return count;
        endfunction

        function int unsigned covered_bins();
            return count_bits({25'h0, class_bins}, 7) +
                   count_bits({30'h0, attack_bins}, 2) +
                   count_bits({28'h0, id_bins}, 4) +
                   count_bits({30'h0, dlc_bins}, 2) +
                   count_bits({28'h0, payload_bins}, 4) +
                   count_bits({30'h0, source_bins}, 2) +
                   count_bits({26'h0, random_kind_bins}, 6) +
                   tp_seen + tn_seen + fp_zero_seen + fn_zero_seen +
                   class_match_seen + alert_sticky_seen + irq_match_seen +
                   replay_behavior_seen + flood_behavior_seen +
                   modify_behavior_seen + status_valid_seen;
        endfunction

        function void write(can_ids_item tr);
            class_bins[tr.observed_class] = 1'b1;
            attack_bins[tr.observed_attack] = 1'b1;
            source_bins[tr.is_random] = 1'b1;
            if (tr.is_random && (tr.stimulus_kind <= STIM_MODIFY)) begin
                random_kind_bins[tr.stimulus_kind] = 1'b1;
            end

            if (tr.can_id == 11'h000) begin
                id_bins[0] = 1'b1;
            end else if (tr.can_id == 11'h0C3) begin
                id_bins[1] = 1'b1;
            end else if (tr.can_id == 11'h145) begin
                id_bins[2] = 1'b1;
            end else begin
                id_bins[3] = 1'b1;
            end

            if (tr.dlc <= 4'd8) begin
                dlc_bins[0] = 1'b1;
            end else begin
                dlc_bins[1] = 1'b1;
            end

            if (tr.payload == 64'h0000_0000_0000_0000) begin
                payload_bins[0] = 1'b1;
            end else if (tr.payload == 64'hFFFF_FFFF_0000_0000) begin
                payload_bins[1] = 1'b1;
            end else if ((tr.can_id == 11'h145) && (tr.payload[63:48] != 16'h0000)) begin
                payload_bins[2] = 1'b1;
            end else begin
                payload_bins[3] = 1'b1;
            end

            tp_seen |= (tr.tp_count != 0);
            tn_seen |= (tr.tn_count != 0);
            fp_zero_seen |= (tr.fp_count == 0);
            fn_zero_seen |= (tr.fn_count == 0);
            class_match_seen |= (tr.class_match_count == tr.total_count);
            alert_sticky_seen |= tr.alert;
            irq_match_seen |= tr.alert_irq_match;
            replay_behavior_seen |= (tr.observed_class == CLASS_REPLAY);
            flood_behavior_seen |= (tr.observed_class == CLASS_FLOOD);
            modify_behavior_seen |= (tr.observed_class == CLASS_MODIFY);
            status_valid_seen |= tr.status_valid;
            sampled_count++;

            vif.coverage_bins = covered_bins();
            vif.coverage_percent_x100 = (10000 * covered_bins()) / 38;

`ifdef NATIVE_COVERGROUPS
            can_ids_cg.sample(tr.can_id, tr.dlc, tr.observed_class, tr.observed_attack,
                              tr.is_random, tr.stimulus_kind);
`endif
        endfunction

        function void check_phase(uvm_phase phase);
            if (covered_bins() != 38) begin
                `uvm_error("FUNC_COV",
                    $sformatf("Portable CAN-IDS coverage incomplete: %0d/38 bins",
                              covered_bins()))
            end
            if (vif.assertion_failures != 0) begin
                `uvm_error("SVA_FAIL", $sformatf("CAN-IDS SVA failures=%0d",
                                                 vif.assertion_failures))
            end
            if (vif.assertion_cover_hits == 0) begin
                `uvm_error("SVA_COVER", "CAN-IDS attack-alert cover property was not reached")
            end
        endfunction

        function void report_phase(uvm_phase phase);
            real portable_coverage;
            portable_coverage = (100.0 * covered_bins()) / 38.0;
            `uvm_info("FUNC_COV",
                $sformatf("Portable CAN-IDS functional coverage: %0.2f%% (%0d/38 bins) from %0d transactions",
                          portable_coverage, covered_bins(), sampled_count),
                UVM_NONE)
            `uvm_info("SVA_SUMMARY",
                $sformatf("Concurrent assertions=4 failures=%0d submit attempts=%0d active attempts=%0d attack-alert cover hits=%0d",
                          vif.assertion_failures, vif.assertion_submit_attempts,
                          vif.assertion_active_attempts, vif.assertion_cover_hits),
                UVM_NONE)
`ifdef NATIVE_COVERGROUPS
            `uvm_info("FUNC_COV",
                $sformatf("Native CAN-IDS covergroup coverage: %0.2f%%",
                          can_ids_cg.get_inst_coverage()),
                UVM_NONE)
`endif
        endfunction
    endclass

    class can_ids_env extends uvm_env;
        `uvm_component_utils(can_ids_env)
        can_ids_agent agent;
        can_ids_scoreboard scoreboard;
        can_ids_coverage coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = can_ids_agent::type_id::create("agent", this);
            scoreboard = can_ids_scoreboard::type_id::create("scoreboard", this);
            coverage = can_ids_coverage::type_id::create("coverage", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.monitor.observed_ap.connect(scoreboard.analysis_export);
            agent.monitor.observed_ap.connect(coverage.analysis_export);
        endfunction
    endclass

    class can_ids_uvm_test extends uvm_test;
        `uvm_component_utils(can_ids_uvm_test)
        can_ids_env env;
        int unsigned random_transactions = 200;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            void'($value$plusargs("RANDOM_TXNS=%d", random_transactions));
            if (random_transactions < 6) begin
                `uvm_fatal("RAND_COUNT", "RANDOM_TXNS must be at least 6")
            end
            uvm_config_db#(int unsigned)::set(this, "env.scoreboard",
                                               "expected_transactions",
                                               9 + random_transactions);
            env = can_ids_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            can_ids_sequence seq;
            can_ids_random_sequence random_seq;
            phase.raise_objection(this);
            seq = can_ids_sequence::type_id::create("seq");
            seq.start(env.agent.seqr);
            random_seq = can_ids_random_sequence::type_id::create("random_seq");
            random_seq.transaction_count = random_transactions;
            `uvm_info("RANDOM_CFG",
                $sformatf("Starting %0d constrained-random CAN-IDS transactions",
                          random_transactions), UVM_NONE)
            random_seq.start(env.agent.seqr);
            repeat (30) @(env.agent.driver.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
