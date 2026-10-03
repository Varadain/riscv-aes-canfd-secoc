package canfd_secoc_uvm_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import "DPI-C" function void secoc_cmac_ref(
        input int unsigned key3, input int unsigned key2,
        input int unsigned key1, input int unsigned key0,
        input int unsigned can_id, input int unsigned ide,
        input int unsigned fdf, input int unsigned brs,
        input int unsigned dlc, input int unsigned freshness,
        input int unsigned p15, input int unsigned p14,
        input int unsigned p13, input int unsigned p12,
        input int unsigned p11, input int unsigned p10,
        input int unsigned p9, input int unsigned p8,
        input int unsigned p7, input int unsigned p6,
        input int unsigned p5, input int unsigned p4,
        input int unsigned p3, input int unsigned p2,
        input int unsigned p1, input int unsigned p0,
        output int unsigned tag3, output int unsigned tag2,
        output int unsigned tag1, output int unsigned tag0
    );

    localparam bit [127:0] TEST_KEY =
        128'h2b7e1516_28aed2a6_abf71588_09cf4f3c;

    typedef enum int unsigned {
        VALID_RX   = 0,
        BAD_MAC    = 1,
        REPLAY_RX  = 2,
        TX_LOOPBACK= 3
    } canfd_kind_e;

    class canfd_secoc_item extends uvm_sequence_item;
        canfd_kind_e kind;
        bit          is_random;
        bit [28:0]   can_id;
        bit [3:0]    dlc;
        bit          ide;
        bit          fdf;
        bit          brs;
        bit [31:0]   freshness;
        bit [511:0]  payload;

        bit [127:0] expected_tag;
        bit [63:0]  observed_tag64;
        bit [31:0]  observed_accept_count;
        bit [31:0]  observed_auth_fail_count;
        bit [31:0]  observed_fresh_fail_count;
        bit [31:0]  observed_ids_submits;
        bit [31:0]  observed_dma_words;
        bit [31:0]  observed_dma_id;
        bit [31:0]  observed_dma_flags;
        bit [31:0]  observed_dma_freshness;
        bit [31:0]  observed_dma_payload0;

        `uvm_object_utils_begin(canfd_secoc_item)
            `uvm_field_enum(canfd_kind_e, kind, UVM_ALL_ON)
            `uvm_field_int(is_random, UVM_ALL_ON)
            `uvm_field_int(can_id, UVM_ALL_ON)
            `uvm_field_int(dlc, UVM_ALL_ON)
            `uvm_field_int(ide, UVM_ALL_ON)
            `uvm_field_int(fdf, UVM_ALL_ON)
            `uvm_field_int(brs, UVM_ALL_ON)
            `uvm_field_int(freshness, UVM_ALL_ON)
            `uvm_field_int(payload, UVM_ALL_ON)
            `uvm_field_int(expected_tag, UVM_ALL_ON)
            `uvm_field_int(observed_tag64, UVM_ALL_ON)
            `uvm_field_int(observed_accept_count, UVM_ALL_ON)
            `uvm_field_int(observed_auth_fail_count, UVM_ALL_ON)
            `uvm_field_int(observed_fresh_fail_count, UVM_ALL_ON)
            `uvm_field_int(observed_ids_submits, UVM_ALL_ON)
            `uvm_field_int(observed_dma_words, UVM_ALL_ON)
            `uvm_field_int(observed_dma_id, UVM_ALL_ON)
            `uvm_field_int(observed_dma_flags, UVM_ALL_ON)
            `uvm_field_int(observed_dma_freshness, UVM_ALL_ON)
            `uvm_field_int(observed_dma_payload0, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "canfd_secoc_item");
            super.new(name);
        endfunction
    endclass

    class canfd_secoc_sequence extends uvm_sequence #(canfd_secoc_item);
        `uvm_object_utils(canfd_secoc_sequence)
        int unsigned random_transactions = 40;
        int unsigned prng_state = 32'h51ec_0c01;
        int unsigned next_freshness = 1;
        int unsigned last_accepted_freshness = 0;

        function new(string name = "canfd_secoc_sequence");
            super.new(name);
        endfunction

        function int unsigned next_word();
            prng_state ^= (prng_state << 13);
            prng_state ^= (prng_state >> 17);
            prng_state ^= (prng_state << 5);
            return prng_state;
        endfunction

        function bit [511:0] next_payload();
            bit [511:0] value;
            for (int i = 0; i < 16; i++) value[i*32 +: 32] = next_word();
            return value;
        endfunction

        task send_one(canfd_kind_e kind,
                      bit random_item,
                      bit [28:0] can_id,
                      bit [3:0] dlc,
                      bit ide,
                      bit fdf,
                      bit brs,
                      bit [31:0] freshness);
            canfd_secoc_item tr;
            tr = canfd_secoc_item::type_id::create("tr");
            start_item(tr);
            tr.kind = kind;
            tr.is_random = random_item;
            tr.can_id = can_id;
            tr.dlc = dlc;
            tr.ide = ide;
            tr.fdf = fdf;
            tr.brs = brs;
            tr.freshness = freshness;
            tr.payload = next_payload();
            finish_item(tr);
        endtask

        task body();
            void'($value$plusargs("RANDOM_TXNS=%0d", random_transactions));
            void'($value$plusargs("CANFD_SEED=%0d", prng_state));
            if (prng_state == 0) prng_state = 32'h51ec_0c01;

            // Six deterministic transactions close the safety-critical corner
            // cases before randomized traffic broadens IDs, flags and payloads.
            send_one(VALID_RX, 0, 29'h0C3, 4'd8,  0, 0, 0, 32'd1);
            last_accepted_freshness = 1;
            send_one(BAD_MAC,  0, 29'h1234567, 4'd15, 1, 1, 1, 32'd2);
            send_one(VALID_RX, 0, 29'h145, 4'd9,  0, 1, 1, 32'd3);
            last_accepted_freshness = 3;
            send_one(REPLAY_RX,0, 29'h145, 4'd9,  0, 1, 1,
                     last_accepted_freshness);
            send_one(TX_LOOPBACK,0,29'h0C3, 4'd15, 0, 1, 0, 32'd4);
            last_accepted_freshness = 4;
            send_one(VALID_RX, 0, 29'h1001234, 4'd10, 1, 1, 0, 32'd5);
            last_accepted_freshness = 5;
            next_freshness = 6;

            repeat (random_transactions) begin
                canfd_kind_e kind;
                bit [31:0] freshness;
                kind = canfd_kind_e'(next_word() % 4);
                if (kind == REPLAY_RX) begin
                    freshness = last_accepted_freshness;
                end else begin
                    freshness = next_freshness++;
                    if ((kind == VALID_RX) || (kind == TX_LOOPBACK))
                        last_accepted_freshness = freshness;
                end
                send_one(kind, 1,
                         (next_word() & 1) ? (next_word() & 29'h1fff_ffff) :
                                           (next_word() & 29'h7ff),
                         next_word()[3:0], next_word()[0], next_word()[0],
                         next_word()[0], freshness);
            end
        endtask
    endclass

    class canfd_secoc_sequencer extends uvm_sequencer #(canfd_secoc_item);
        `uvm_component_utils(canfd_secoc_sequencer)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
    endclass

    class canfd_secoc_driver extends uvm_driver #(canfd_secoc_item);
        `uvm_component_utils(canfd_secoc_driver)
        virtual canfd_secoc_uvm_if vif;
        uvm_analysis_port #(canfd_secoc_item) completed_ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            completed_ap = new("completed_ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual canfd_secoc_uvm_if)::get(
                    this, "", "vif", vif))
                `uvm_fatal("NOVIF", "canfd_secoc_uvm_if was not configured")
        endfunction

        function bit [127:0] reference_cmac(canfd_secoc_item tr);
            int unsigned t3, t2, t1, t0;
            secoc_cmac_ref(
                TEST_KEY[127:96], TEST_KEY[95:64],
                TEST_KEY[63:32], TEST_KEY[31:0],
                tr.can_id, tr.ide, tr.fdf, tr.brs, tr.dlc, tr.freshness,
                tr.payload[511:480], tr.payload[479:448],
                tr.payload[447:416], tr.payload[415:384],
                tr.payload[383:352], tr.payload[351:320],
                tr.payload[319:288], tr.payload[287:256],
                tr.payload[255:224], tr.payload[223:192],
                tr.payload[191:160], tr.payload[159:128],
                tr.payload[127:96], tr.payload[95:64],
                tr.payload[63:32], tr.payload[31:0],
                t3, t2, t1, t0);
            return {t3, t2, t1, t0};
        endfunction

        task program_frame(canfd_secoc_item tr);
            vif.mmio_write(8'h08, {3'h0, tr.can_id});
            vif.mmio_write(8'h0C, {25'h0, tr.brs, tr.fdf, tr.ide, tr.dlc});
            vif.mmio_write(8'h10, tr.freshness);
            for (int i = 0; i < 16; i++)
                vif.mmio_write(8'h20 + i*4, tr.payload[i*32 +: 32]);
        endtask

        task read_event_counters(output logic [31:0] accepted,
                                 output logic [31:0] auth_fail,
                                 output logic [31:0] fresh_fail);
            vif.mmio_read(8'h7C, accepted);
            vif.mmio_read(8'h80, auth_fail);
            vif.mmio_read(8'h84, fresh_fail);
        endtask

        task wait_for_security_event(input logic [31:0] previous_total);
            logic [31:0] accepted, auth_fail, fresh_fail;
            int timeout;
            timeout = 0;
            do begin
                read_event_counters(accepted, auth_fail, fresh_fail);
                timeout++;
                if (timeout > 10000)
                    `uvm_fatal("TIMEOUT", "SecOC frame processing timed out")
            end while ((accepted + auth_fail + fresh_fail) == previous_total);
        endtask

        task wait_for_tx_head();
            logic [31:0] status;
            int timeout = 0;
            do begin
                vif.mmio_read(8'h04, status);
                timeout++;
                if (timeout > 10000)
                    `uvm_fatal("TIMEOUT", "SecOC TX CMAC generation timed out")
            end while (status[3]);
        endtask

        task wait_for_dma(input logic [31:0] accepted_count);
            logic [31:0] status;
            int timeout = 0;
            while (vif.dma_write_count < accepted_count * 22) begin
                vif.mmio_read(8'h04, status);
                timeout++;
                if (timeout > 2000)
                    `uvm_fatal("DMA_TIMEOUT", "CAN-FD RX DMA record timed out")
            end
        endtask

        task configure_dut();
            wait (vif.rst_n === 1'b1);
            vif.mmio_write(8'h9C, TEST_KEY[31:0]);
            vif.mmio_write(8'hA0, TEST_KEY[63:32]);
            vif.mmio_write(8'hA4, TEST_KEY[95:64]);
            vif.mmio_write(8'hA8, TEST_KEY[127:96]);
            // Enable DMA and loopback, then lock key writes/readback.
            vif.mmio_write(8'h00, 32'h0000_2A00);
        endtask

        task run_phase(uvm_phase phase);
            canfd_secoc_item tr;
            logic [31:0] accepted_before, auth_before, fresh_before;
            logic [31:0] tag_hi, tag_lo;
            configure_dut();
            forever begin
                seq_item_port.get_next_item(tr);
                tr.expected_tag = reference_cmac(tr);
                read_event_counters(accepted_before, auth_before, fresh_before);
                program_frame(tr);

                if (tr.kind == TX_LOOPBACK) begin
                    vif.mmio_write(8'h00, 32'h0000_0004);
                    wait_for_tx_head();
                    vif.mmio_read(8'h6C, tag_hi);
                    vif.mmio_read(8'h70, tag_lo);
                    tr.observed_tag64 = {tag_hi, tag_lo};
                    vif.mmio_write(8'h00, 32'h0000_0010);
                end else begin
                    if (tr.kind == BAD_MAC) begin
                        vif.mmio_write(8'h14, tr.expected_tag[127:96]);
                        vif.mmio_write(8'h18, tr.expected_tag[95:64] ^ 32'h1);
                    end else begin
                        vif.mmio_write(8'h14, tr.expected_tag[127:96]);
                        vif.mmio_write(8'h18, tr.expected_tag[95:64]);
                    end
                    vif.mmio_write(8'h00, 32'h0000_0008);
                end

                wait_for_security_event(accepted_before + auth_before + fresh_before);
                vif.mmio_read(8'hB0, tag_hi);
                vif.mmio_read(8'hB4, tag_lo);
                if (tr.kind != TX_LOOPBACK)
                    tr.observed_tag64 = {tag_hi, tag_lo};
                read_event_counters(tr.observed_accept_count,
                                    tr.observed_auth_fail_count,
                                    tr.observed_fresh_fail_count);
                wait_for_dma(tr.observed_accept_count);
                tr.observed_ids_submits = vif.ids_submit_count;
                tr.observed_dma_words = vif.dma_write_count;
                tr.observed_dma_id = vif.dma_last_id;
                tr.observed_dma_flags = vif.dma_last_flags;
                tr.observed_dma_freshness = vif.dma_last_freshness;
                tr.observed_dma_payload0 = vif.dma_last_payload0;
                completed_ap.write(tr);
                seq_item_port.item_done();
            end
        endtask
    endclass

    class canfd_secoc_agent extends uvm_agent;
        `uvm_component_utils(canfd_secoc_agent)
        canfd_secoc_sequencer sequencer;
        canfd_secoc_driver driver;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sequencer = canfd_secoc_sequencer::type_id::create("sequencer", this);
            driver = canfd_secoc_driver::type_id::create("driver", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
        endfunction
    endclass

    class canfd_secoc_scoreboard extends uvm_component;
        `uvm_component_utils(canfd_secoc_scoreboard)
        uvm_analysis_imp #(canfd_secoc_item, canfd_secoc_scoreboard) analysis_export;
        int unsigned transactions;
        int unsigned random_transactions;
        int unsigned expected_accept;
        int unsigned expected_auth_fail;
        int unsigned expected_fresh_fail;
        int unsigned mismatches;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            analysis_export = new("analysis_export", this);
        endfunction

        function void mismatch(string text);
            mismatches++;
            `uvm_error("CANFD_SCOREBOARD", text)
        endfunction

        function void write(canfd_secoc_item tr);
            transactions++;
            if (tr.is_random) random_transactions++;
            case (tr.kind)
                VALID_RX, TX_LOOPBACK: expected_accept++;
                BAD_MAC: expected_auth_fail++;
                REPLAY_RX: expected_fresh_fail++;
            endcase

            if (tr.observed_tag64 !== tr.expected_tag[127:64])
                mismatch($sformatf("CMAC mismatch got=%016h expected=%016h",
                                   tr.observed_tag64, tr.expected_tag[127:64]));
            if (tr.observed_accept_count != expected_accept)
                mismatch($sformatf("RX accept count=%0d expected=%0d",
                                   tr.observed_accept_count, expected_accept));
            if (tr.observed_auth_fail_count != expected_auth_fail)
                mismatch($sformatf("Auth-fail count=%0d expected=%0d",
                                   tr.observed_auth_fail_count, expected_auth_fail));
            if (tr.observed_fresh_fail_count != expected_fresh_fail)
                mismatch($sformatf("Freshness-fail count=%0d expected=%0d",
                                   tr.observed_fresh_fail_count, expected_fresh_fail));
            if (tr.observed_ids_submits != expected_accept)
                mismatch($sformatf("IDS releases=%0d expected=%0d",
                                   tr.observed_ids_submits, expected_accept));
            if (tr.observed_dma_words != expected_accept * 22)
                mismatch($sformatf("DMA words=%0d expected=%0d",
                                   tr.observed_dma_words, expected_accept * 22));
            if ((tr.kind == VALID_RX) || (tr.kind == TX_LOOPBACK)) begin
                if (tr.observed_dma_id != {3'h0, tr.can_id})
                    mismatch($sformatf("DMA ID=%08h expected=%08h",
                                       tr.observed_dma_id, {3'h0, tr.can_id}));
                if (tr.observed_dma_flags !=
                    {25'h0, tr.brs, tr.fdf, tr.ide, tr.dlc})
                    mismatch($sformatf("DMA flags=%08h expected=%08h",
                        tr.observed_dma_flags,
                        {25'h0, tr.brs, tr.fdf, tr.ide, tr.dlc}));
                if (tr.observed_dma_freshness != tr.freshness)
                    mismatch($sformatf("DMA freshness=%08h expected=%08h",
                                       tr.observed_dma_freshness, tr.freshness));
                if (tr.observed_dma_payload0 != tr.payload[31:0])
                    mismatch($sformatf("DMA payload0=%08h expected=%08h",
                                       tr.observed_dma_payload0, tr.payload[31:0]));
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("CANFD_SCOREBOARD",
                $sformatf("CAN-FD/SecOC scoreboard transactions=%0d randomized=%0d accepted=%0d auth_fail=%0d fresh_fail=%0d mismatches=%0d",
                    transactions, random_transactions, expected_accept,
                    expected_auth_fail, expected_fresh_fail, mismatches), UVM_NONE)
        endfunction
    endclass

    class canfd_secoc_coverage extends uvm_component;
        `uvm_component_utils(canfd_secoc_coverage)
        uvm_analysis_imp #(canfd_secoc_item, canfd_secoc_coverage) analysis_export;
        virtual canfd_secoc_uvm_if vif;
        bit [3:0] kind_bins;
        bit [2:0] dlc_bins;
        bit [1:0] ide_bins;
        bit [1:0] fdf_bins;
        bit [1:0] brs_bins;
        bit [2:0] outcome_bins;
        int unsigned samples;

`ifdef NATIVE_COVERGROUPS
        covergroup canfd_cg with function sample(int unsigned kind,
            bit [3:0] dlc, bit ide, bit fdf, bit brs);
            option.per_instance = 1;
            cp_kind: coverpoint kind { bins all_kinds[] = {[0:3]}; }
            cp_dlc: coverpoint dlc {
                bins classic = {[0:8]}; bins fd_mid = {[9:14]}; bins fd_max = {15};
            }
            cp_ide: coverpoint ide;
            cp_fdf: coverpoint fdf;
            cp_brs: coverpoint brs;
        endgroup
`endif

        function new(string name, uvm_component parent);
            super.new(name, parent);
            analysis_export = new("analysis_export", this);
`ifdef NATIVE_COVERGROUPS
            canfd_cg = new();
`endif
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual canfd_secoc_uvm_if)::get(
                    this, "", "vif", vif))
                `uvm_fatal("NOVIF", "coverage could not obtain virtual interface")
        endfunction

        function int unsigned count_bits(bit [31:0] value, int width);
            int unsigned count = 0;
            for (int i = 0; i < width; i++) count += value[i];
            return count;
        endfunction

        function int unsigned covered_bins();
            return count_bits({28'h0, kind_bins}, 4) +
                   count_bits({29'h0, dlc_bins}, 3) +
                   count_bits({30'h0, ide_bins}, 2) +
                   count_bits({30'h0, fdf_bins}, 2) +
                   count_bits({30'h0, brs_bins}, 2) +
                   count_bits({29'h0, outcome_bins}, 3);
        endfunction

        function void write(canfd_secoc_item tr);
            samples++;
            kind_bins[tr.kind] = 1'b1;
            if (tr.dlc <= 8) dlc_bins[0] = 1'b1;
            else if (tr.dlc == 15) dlc_bins[2] = 1'b1;
            else dlc_bins[1] = 1'b1;
            ide_bins[tr.ide] = 1'b1;
            fdf_bins[tr.fdf] = 1'b1;
            brs_bins[tr.brs] = 1'b1;
            case (tr.kind)
                VALID_RX, TX_LOOPBACK: outcome_bins[0] = 1'b1;
                BAD_MAC: outcome_bins[1] = 1'b1;
                REPLAY_RX: outcome_bins[2] = 1'b1;
            endcase
`ifdef NATIVE_COVERGROUPS
            canfd_cg.sample(tr.kind, tr.dlc, tr.ide, tr.fdf, tr.brs);
`endif
        endfunction

        function void check_phase(uvm_phase phase);
            if (covered_bins() != 16)
                `uvm_error("CANFD_COVERAGE",
                    $sformatf("Portable coverage incomplete: %0d/16 bins",
                              covered_bins()))
            if (vif.assertion_failures != 0)
                `uvm_error("CANFD_ASSERTIONS",
                    $sformatf("Assertion failures=%0d", vif.assertion_failures))
            if (vif.assertion_cover_hits == 0)
                `uvm_error("CANFD_ASSERTIONS", "Assertion cover properties were not reached")
        endfunction

        function void report_phase(uvm_phase phase);
            real percentage = (100.0 * covered_bins()) / 16.0;
            `uvm_info("CANFD_COVERAGE",
                $sformatf("Portable CAN-FD/SecOC functional coverage: %0.2f%% (%0d/16 bins) from %0d transactions",
                          percentage, covered_bins(), samples), UVM_NONE)
            `uvm_info("CANFD_ASSERTIONS",
                $sformatf("Concurrent assertions=5 failures=%0d cover hits=%0d",
                          vif.assertion_failures, vif.assertion_cover_hits), UVM_NONE)
`ifdef NATIVE_COVERGROUPS
            `uvm_info("CANFD_COVERAGE",
                $sformatf("Native CAN-FD/SecOC covergroup coverage: %0.2f%%",
                          canfd_cg.get_inst_coverage()), UVM_NONE)
`endif
        endfunction
    endclass

    class canfd_secoc_env extends uvm_env;
        `uvm_component_utils(canfd_secoc_env)
        canfd_secoc_agent agent;
        canfd_secoc_scoreboard scoreboard;
        canfd_secoc_coverage coverage;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = canfd_secoc_agent::type_id::create("agent", this);
            scoreboard = canfd_secoc_scoreboard::type_id::create("scoreboard", this);
            coverage = canfd_secoc_coverage::type_id::create("coverage", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            agent.driver.completed_ap.connect(scoreboard.analysis_export);
            agent.driver.completed_ap.connect(coverage.analysis_export);
        endfunction
    endclass

    class canfd_secoc_uvm_test extends uvm_test;
        `uvm_component_utils(canfd_secoc_uvm_test)
        canfd_secoc_env env;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = canfd_secoc_env::type_id::create("env", this);
        endfunction
        task run_phase(uvm_phase phase);
            canfd_secoc_sequence seq;
            phase.raise_objection(this);
            seq = canfd_secoc_sequence::type_id::create("seq");
            seq.start(env.agent.sequencer);
            phase.drop_objection(this);
        endtask
        function void check_phase(uvm_phase phase);
            if (env.scoreboard.mismatches != 0)
                `uvm_error("CANFD_TEST", "Scoreboard recorded mismatches")
        endfunction
    endclass
endpackage
