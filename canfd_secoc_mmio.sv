// =============================================================================
// CAN-FD frame controller with FIFOs, RX DMA, and SecOC-style AES-CMAC
//
// Base address: 0x0000_0A00
//
// This block owns the frame-level boundary between a CAN-FD protocol/PHY core
// and the security SoC. It deliberately does not implement ISO 11898 bit
// timing, arbitration, CRC generation, or the electrical transceiver. Software
// and verification use RX_PUSH/TX_SUBMIT as the frame boundary; the same FIFO
// interface can later be connected to a licensed CAN-FD MAC without changing
// the SecOC, IDS, DMA, or interrupt paths.
//
// Security profile used by this prototype:
//   AES-CMAC-128 message = five complete 128-bit blocks
//     M0 = {"SECO", freshness, CAN ID, IDE, FDF, BRS, DLC, 28'b0}
//     M1..M4 = all 64 payload bytes (four 128-bit blocks)
//   The full CMAC is retained for debug/validation. RX verification compares
//   the most-significant 64 bits, which models a configurable truncated SecOC
//   authenticator while keeping the hardware interface compact.
//
// FIFO policy:
//   - RX_PUSH places a received frame and its 64-bit authenticator in RX FIFO.
//   - Authenticated, fresh RX frames are released to CAN-IDS and optional DMA.
//   - TX_SUBMIT computes a CMAC and places the protected frame in TX FIFO.
//   - TX_POP removes the head; loopback mode returns it to RX FIFO.
//
// RX DMA record (22 words, normally stored with a 0x60-byte stride):
//   +0x00 ID, +0x04 flags/DLC, +0x08 timestamp, +0x0C freshness
//   +0x10 tag[127:96], +0x14 tag[95:64], +0x18..+0x54 payload words 0..15
// =============================================================================
module canfd_secoc_mmio #(
    parameter integer FIFO_DEPTH = 4
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         clk_en_i,
    input  logic [31:0]  addr_i,
    input  logic [31:0]  write_data_i,
    input  logic         write_en_i,
    input  logic         read_en_i,
    output logic [31:0]  read_data_o,

    output logic         irq_o,
    output logic         active_o,

    // Trusted frame released only after freshness and MAC checks pass.
    output logic         ids_submit_o,
    output logic [10:0]  ids_frame_id_o,
    output logic [3:0]   ids_frame_dlc_o,
    output logic [63:0]  ids_frame_payload_o,
    output logic         ids_frame_fd_o,

    // Write-only DMA master. mem_stage grants this port when DMA-lite is idle.
    output logic         dma_req_o,
    input  logic         dma_grant_i,
    output logic [31:0]  dma_write_addr_o,
    output logic [31:0]  dma_write_data_o,
    output logic         dma_write_en_o
);

    localparam logic [7:0] OFF_CTRL          = 8'h00;
    localparam logic [7:0] OFF_STATUS        = 8'h04;
    localparam logic [7:0] OFF_FRAME_ID      = 8'h08;
    localparam logic [7:0] OFF_FRAME_FLAGS   = 8'h0C;
    localparam logic [7:0] OFF_FRESHNESS     = 8'h10;
    localparam logic [7:0] OFF_RX_TAG_HI     = 8'h14;
    localparam logic [7:0] OFF_RX_TAG_LO     = 8'h18;
    localparam logic [7:0] OFF_DATA0         = 8'h20;
    localparam logic [7:0] OFF_DATA15        = 8'h5C;
    localparam logic [7:0] OFF_TX_HEAD_ID    = 8'h60;
    localparam logic [7:0] OFF_TX_HEAD_FLAGS = 8'h64;
    localparam logic [7:0] OFF_TX_HEAD_FRESH = 8'h68;
    localparam logic [7:0] OFF_TX_HEAD_TAG_HI= 8'h6C;
    localparam logic [7:0] OFF_TX_HEAD_TAG_LO= 8'h70;
    localparam logic [7:0] OFF_TX_DATA_INDEX = 8'h74;
    localparam logic [7:0] OFF_TX_HEAD_DATA  = 8'h78;
    localparam logic [7:0] OFF_RX_ACCEPT     = 8'h7C;
    localparam logic [7:0] OFF_AUTH_FAIL     = 8'h80;
    localparam logic [7:0] OFF_FRESH_FAIL    = 8'h84;
    localparam logic [7:0] OFF_OVERFLOW      = 8'h88;
    localparam logic [7:0] OFF_LAST_FRESH    = 8'h8C;
    localparam logic [7:0] OFF_DMA_BASE      = 8'h90;
    localparam logic [7:0] OFF_DMA_STRIDE    = 8'h94;
    localparam logic [7:0] OFF_DMA_RECORDS   = 8'h98;
    localparam logic [7:0] OFF_KEY0          = 8'h9C;
    localparam logic [7:0] OFF_KEY1          = 8'hA0;
    localparam logic [7:0] OFF_KEY2          = 8'hA4;
    localparam logic [7:0] OFF_KEY3          = 8'hA8;
    localparam logic [7:0] OFF_KEY_STATUS    = 8'hAC;
    localparam logic [7:0] OFF_LAST_TAG_HI   = 8'hB0;
    localparam logic [7:0] OFF_LAST_TAG_LO   = 8'hB4;
    localparam logic [7:0] OFF_CAPABILITY    = 8'hB8;

    localparam integer PTR_W = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_WAIT_L,
        ST_WAIT_BLOCK,
        ST_BYPASS
    } secoc_state_t;

    logic [7:0] reg_offset;
    logic       enable_reg;
    logic       secoc_enable_reg;
    logic       loopback_enable_reg;
    logic       dma_enable_reg;
    logic       irq_sticky_reg;
    logic       overflow_sticky_reg;

    logic [28:0]  stage_id_reg;
    logic [3:0]   stage_dlc_reg;
    logic         stage_ide_reg;
    logic         stage_fdf_reg;
    logic         stage_brs_reg;
    logic [31:0]  stage_freshness_reg;
    logic [63:0]  stage_rx_tag_reg;
    logic [511:0] stage_payload_reg;
    logic [3:0]   tx_data_index_reg;

    logic [127:0] key_reg;
    logic [3:0]   key_word_valid_reg;
    logic         key_lock_reg;

    logic [28:0]  rx_id_fifo [0:FIFO_DEPTH-1];
    logic [3:0]   rx_dlc_fifo [0:FIFO_DEPTH-1];
    logic         rx_ide_fifo [0:FIFO_DEPTH-1];
    logic         rx_fdf_fifo [0:FIFO_DEPTH-1];
    logic         rx_brs_fifo [0:FIFO_DEPTH-1];
    logic [31:0]  rx_fresh_fifo [0:FIFO_DEPTH-1];
    logic [63:0]  rx_tag_fifo [0:FIFO_DEPTH-1];
    logic [511:0] rx_payload_fifo [0:FIFO_DEPTH-1];

    logic [28:0]  tx_id_fifo [0:FIFO_DEPTH-1];
    logic [3:0]   tx_dlc_fifo [0:FIFO_DEPTH-1];
    logic         tx_ide_fifo [0:FIFO_DEPTH-1];
    logic         tx_fdf_fifo [0:FIFO_DEPTH-1];
    logic         tx_brs_fifo [0:FIFO_DEPTH-1];
    logic [31:0]  tx_fresh_fifo [0:FIFO_DEPTH-1];
    logic [127:0] tx_tag_fifo [0:FIFO_DEPTH-1];
    logic [511:0] tx_payload_fifo [0:FIFO_DEPTH-1];

    logic [PTR_W-1:0] rx_wptr_reg;
    logic [PTR_W-1:0] rx_rptr_reg;
    logic [PTR_W-1:0] tx_wptr_reg;
    logic [PTR_W-1:0] tx_rptr_reg;
    logic [PTR_W:0]   rx_count_reg;
    logic [PTR_W:0]   tx_count_reg;

    secoc_state_t state_reg;
    logic         work_is_rx_reg;
    logic [28:0]  work_id_reg;
    logic [3:0]   work_dlc_reg;
    logic         work_ide_reg;
    logic         work_fdf_reg;
    logic         work_brs_reg;
    logic [31:0]  work_freshness_reg;
    logic [63:0]  work_expected_tag_reg;
    logic [511:0] work_payload_reg;
    logic [31:0]  work_timestamp_reg;

    logic [31:0]  cycle_counter_reg;
    logic [31:0]  last_rx_freshness_reg;
    logic [31:0]  last_tx_freshness_reg;
    logic [127:0] last_computed_tag_reg;
    logic         last_auth_ok_reg;
    logic         last_fresh_ok_reg;

    logic [31:0] rx_accept_count_reg;
    logic [31:0] auth_fail_count_reg;
    logic [31:0] fresh_fail_count_reg;
    logic [31:0] overflow_count_reg;

    logic [127:0] aes_input_reg;
    logic         aes_start_reg;
    logic [127:0] aes_ciphertext;
    logic         aes_done;
    logic [127:0] cmac_k1_reg;
    logic [2:0]   block_index_reg;

    logic         dma_busy_reg;
    logic [4:0]   dma_word_index_reg;
    logic [31:0]  dma_base_reg;
    logic [31:0]  dma_stride_reg;
    logic [31:0]  dma_next_addr_reg;
    logic [31:0]  dma_record_count_reg;
    logic [31:0]  dma_record_base_reg;
    logic [28:0]  dma_id_reg;
    logic [3:0]   dma_dlc_reg;
    logic         dma_ide_reg;
    logic         dma_fdf_reg;
    logic         dma_brs_reg;
    logic [31:0]  dma_timestamp_reg;
    logic [31:0]  dma_freshness_reg;
    logic [127:0] dma_tag_reg;
    logic [511:0] dma_payload_reg;

    logic ctrl_write;
    logic rx_user_push_event;
    logic tx_pop_event;
    logic loopback_push_event;
    logic rx_push_event;
    logic rx_consume_event;
    logic tx_start_event;
    logic tx_complete_event;


    assign reg_offset = addr_i[7:0];
    assign ctrl_write = write_en_i && (reg_offset == OFF_CTRL);

    assign rx_user_push_event = ctrl_write && write_data_i[3] && enable_reg &&
                                (rx_count_reg < FIFO_DEPTH);
    assign tx_pop_event = ctrl_write && write_data_i[4] && (tx_count_reg != 0);
    assign loopback_push_event = tx_pop_event && loopback_enable_reg &&
                                 !write_data_i[3] && (rx_count_reg < FIFO_DEPTH);
    assign rx_push_event = rx_user_push_event || loopback_push_event;
    assign rx_consume_event = (state_reg == ST_IDLE) && (rx_count_reg != 0) &&
                              !ctrl_write && clk_en_i;
    assign tx_start_event = ctrl_write && write_data_i[2] && enable_reg &&
                            (state_reg == ST_IDLE) && (rx_count_reg == 0) &&
                            (tx_count_reg < FIFO_DEPTH);
    assign tx_complete_event = (state_reg == ST_WAIT_BLOCK) && aes_done &&
                               (block_index_reg == 3'd4) && !work_is_rx_reg;

    function automatic logic [127:0] cmac_double(input logic [127:0] value);
        begin
            cmac_double = {value[126:0], 1'b0};
            if (value[127]) cmac_double = cmac_double ^ 128'h87;
        end
    endfunction

    function automatic logic [127:0] message_block(input logic [2:0] index);
        begin
            case (index)
                3'd0: message_block = {32'h5345_434F,
                                       work_freshness_reg,
                                       work_id_reg,
                                       work_ide_reg,
                                       work_fdf_reg,
                                       work_brs_reg,
                                       work_dlc_reg,
                                       28'h0};
                3'd1: message_block = work_payload_reg[127:0];
                3'd2: message_block = work_payload_reg[255:128];
                3'd3: message_block = work_payload_reg[383:256];
                default: message_block = work_payload_reg[511:384];
            endcase
        end
    endfunction

    aes128_lowpower u_secoc_aes (
        .clk       (clk),
        .reset     (!rst_n),
        .clk_en    (1'b1),
        .start     (aes_start_reg),
        .plaintext (aes_input_reg),
        .key       (key_reg),
        .ciphertext(aes_ciphertext),
        .done      (aes_done)
    );

    assign irq_o = irq_sticky_reg;
    assign active_o = (state_reg != ST_IDLE) || dma_busy_reg || ids_submit_o;

    assign dma_req_o        = dma_busy_reg;
    assign dma_write_addr_o = dma_record_base_reg + {25'h0, dma_word_index_reg, 2'b00};
    assign dma_write_en_o   = dma_busy_reg && dma_grant_i;

    // Keep the record mux in always_comb so every record field participates in
    // the sensitivity set. A function whose only formal argument was the word
    // index could leave word zero stale when dma_id_reg changed at DMA start.
    always_comb begin
        case (dma_word_index_reg)
            5'd0: dma_write_data_o = {3'h0, dma_id_reg};
            5'd1: dma_write_data_o = {25'h0, dma_brs_reg, dma_fdf_reg,
                                      dma_ide_reg, dma_dlc_reg};
            5'd2: dma_write_data_o = dma_timestamp_reg;
            5'd3: dma_write_data_o = dma_freshness_reg;
            5'd4: dma_write_data_o = dma_tag_reg[127:96];
            5'd5: dma_write_data_o = dma_tag_reg[95:64];
            default: dma_write_data_o =
                dma_payload_reg[(dma_word_index_reg - 5'd6) * 32 +: 32];
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable_reg            <= 1'b1;
            secoc_enable_reg      <= 1'b1;
            loopback_enable_reg   <= 1'b0;
            dma_enable_reg        <= 1'b0;
            irq_sticky_reg        <= 1'b0;
            overflow_sticky_reg   <= 1'b0;
            stage_id_reg          <= 29'h0;
            stage_dlc_reg         <= 4'h0;
            stage_ide_reg         <= 1'b0;
            stage_fdf_reg         <= 1'b1;
            stage_brs_reg         <= 1'b1;
            stage_freshness_reg   <= 32'h0;
            stage_rx_tag_reg      <= 64'h0;
            stage_payload_reg     <= 512'h0;
            tx_data_index_reg     <= 4'h0;
            key_reg               <= 128'h0;
            key_word_valid_reg    <= 4'h0;
            key_lock_reg          <= 1'b0;
            rx_wptr_reg           <= '0;
            rx_rptr_reg           <= '0;
            tx_wptr_reg           <= '0;
            tx_rptr_reg           <= '0;
            rx_count_reg          <= '0;
            tx_count_reg          <= '0;
            state_reg             <= ST_IDLE;
            work_is_rx_reg        <= 1'b0;
            work_id_reg           <= 29'h0;
            work_dlc_reg          <= 4'h0;
            work_ide_reg          <= 1'b0;
            work_fdf_reg          <= 1'b0;
            work_brs_reg          <= 1'b0;
            work_freshness_reg    <= 32'h0;
            work_expected_tag_reg <= 64'h0;
            work_payload_reg      <= 512'h0;
            work_timestamp_reg    <= 32'h0;
            cycle_counter_reg     <= 32'h0;
            last_rx_freshness_reg <= 32'h0;
            last_tx_freshness_reg <= 32'h0;
            last_computed_tag_reg <= 128'h0;
            last_auth_ok_reg      <= 1'b0;
            last_fresh_ok_reg     <= 1'b0;
            rx_accept_count_reg   <= 32'h0;
            auth_fail_count_reg   <= 32'h0;
            fresh_fail_count_reg  <= 32'h0;
            overflow_count_reg    <= 32'h0;
            aes_input_reg         <= 128'h0;
            aes_start_reg         <= 1'b0;
            cmac_k1_reg           <= 128'h0;
            block_index_reg       <= 3'h0;
            dma_busy_reg          <= 1'b0;
            dma_word_index_reg    <= 5'h0;
            dma_base_reg          <= 32'h0000_0100;
            dma_stride_reg        <= 32'h0000_0060;
            dma_next_addr_reg     <= 32'h0000_0100;
            dma_record_count_reg  <= 32'h0;
            dma_record_base_reg   <= 32'h0;
            dma_id_reg            <= 29'h0;
            dma_dlc_reg           <= 4'h0;
            dma_ide_reg           <= 1'b0;
            dma_fdf_reg           <= 1'b0;
            dma_brs_reg           <= 1'b0;
            dma_timestamp_reg     <= 32'h0;
            dma_freshness_reg     <= 32'h0;
            dma_tag_reg           <= 128'h0;
            dma_payload_reg       <= 512'h0;
            ids_submit_o          <= 1'b0;
            ids_frame_id_o        <= 11'h0;
            ids_frame_dlc_o       <= 4'h0;
            ids_frame_payload_o   <= 64'h0;
            ids_frame_fd_o        <= 1'b0;
            for (int unsigned fifo_index = 0;
                 fifo_index < FIFO_DEPTH; fifo_index = fifo_index + 1) begin
                rx_id_fifo[fifo_index]      <= 29'h0;
                rx_dlc_fifo[fifo_index]     <= 4'h0;
                rx_ide_fifo[fifo_index]     <= 1'b0;
                rx_fdf_fifo[fifo_index]     <= 1'b0;
                rx_brs_fifo[fifo_index]     <= 1'b0;
                rx_fresh_fifo[fifo_index]   <= 32'h0;
                rx_tag_fifo[fifo_index]     <= 64'h0;
                rx_payload_fifo[fifo_index] <= 512'h0;
                tx_id_fifo[fifo_index]      <= 29'h0;
                tx_dlc_fifo[fifo_index]     <= 4'h0;
                tx_ide_fifo[fifo_index]     <= 1'b0;
                tx_fdf_fifo[fifo_index]     <= 1'b0;
                tx_brs_fifo[fifo_index]     <= 1'b0;
                tx_fresh_fifo[fifo_index]   <= 32'h0;
                tx_tag_fifo[fifo_index]     <= 128'h0;
                tx_payload_fifo[fifo_index] <= 512'h0;
            end
        end else if (clk_en_i) begin
            cycle_counter_reg <= cycle_counter_reg + 32'd1;
            aes_start_reg     <= 1'b0;
            ids_submit_o      <= 1'b0;

            // RX FIFO count and pointers support one push and one consume in
            // the same cycle without losing either operation.
            case ({rx_push_event, rx_consume_event})
                2'b10: rx_count_reg <= rx_count_reg + 1'b1;
                2'b01: rx_count_reg <= rx_count_reg - 1'b1;
                default: ;
            endcase
            if (rx_push_event) begin
                if (rx_user_push_event) begin
                    rx_id_fifo[rx_wptr_reg]      <= stage_id_reg;
                    rx_dlc_fifo[rx_wptr_reg]     <= stage_dlc_reg;
                    rx_ide_fifo[rx_wptr_reg]     <= stage_ide_reg;
                    rx_fdf_fifo[rx_wptr_reg]     <= stage_fdf_reg;
                    rx_brs_fifo[rx_wptr_reg]     <= stage_brs_reg;
                    rx_fresh_fifo[rx_wptr_reg]   <= stage_freshness_reg;
                    rx_tag_fifo[rx_wptr_reg]     <= stage_rx_tag_reg;
                    rx_payload_fifo[rx_wptr_reg] <= stage_payload_reg;
                end else begin
                    rx_id_fifo[rx_wptr_reg]      <= tx_id_fifo[tx_rptr_reg];
                    rx_dlc_fifo[rx_wptr_reg]     <= tx_dlc_fifo[tx_rptr_reg];
                    rx_ide_fifo[rx_wptr_reg]     <= tx_ide_fifo[tx_rptr_reg];
                    rx_fdf_fifo[rx_wptr_reg]     <= tx_fdf_fifo[tx_rptr_reg];
                    rx_brs_fifo[rx_wptr_reg]     <= tx_brs_fifo[tx_rptr_reg];
                    rx_fresh_fifo[rx_wptr_reg]   <= tx_fresh_fifo[tx_rptr_reg];
                    rx_tag_fifo[rx_wptr_reg]     <= tx_tag_fifo[tx_rptr_reg][127:64];
                    rx_payload_fifo[rx_wptr_reg] <= tx_payload_fifo[tx_rptr_reg];
                end
                rx_wptr_reg <= rx_wptr_reg + 1'b1;
            end
            if (rx_consume_event) rx_rptr_reg <= rx_rptr_reg + 1'b1;

            case ({tx_complete_event, tx_pop_event})
                2'b10: tx_count_reg <= tx_count_reg + 1'b1;
                2'b01: tx_count_reg <= tx_count_reg - 1'b1;
                default: ;
            endcase
            if (tx_pop_event) tx_rptr_reg <= tx_rptr_reg + 1'b1;
            if (tx_complete_event) begin
                tx_id_fifo[tx_wptr_reg]      <= work_id_reg;
                tx_dlc_fifo[tx_wptr_reg]     <= work_dlc_reg;
                tx_ide_fifo[tx_wptr_reg]     <= work_ide_reg;
                tx_fdf_fifo[tx_wptr_reg]     <= work_fdf_reg;
                tx_brs_fifo[tx_wptr_reg]     <= work_brs_reg;
                tx_fresh_fifo[tx_wptr_reg]   <= work_freshness_reg;
                tx_tag_fifo[tx_wptr_reg]     <= aes_ciphertext;
                tx_payload_fifo[tx_wptr_reg] <= work_payload_reg;
                tx_wptr_reg                  <= tx_wptr_reg + 1'b1;
            end

            if (ctrl_write) begin
                if (write_data_i[0])  enable_reg          <= 1'b1;
                if (write_data_i[1])  enable_reg          <= 1'b0;
                if (write_data_i[5])  irq_sticky_reg      <= 1'b0;
                if (write_data_i[7])  secoc_enable_reg    <= 1'b1;
                if (write_data_i[8])  secoc_enable_reg    <= 1'b0;
                if (write_data_i[9])  loopback_enable_reg <= 1'b1;
                if (write_data_i[10]) loopback_enable_reg <= 1'b0;
                if (write_data_i[11]) dma_enable_reg      <= 1'b1;
                if (write_data_i[12]) dma_enable_reg      <= 1'b0;
                if (write_data_i[13]) key_lock_reg        <= 1'b1;
                if (write_data_i[14] && (state_reg == ST_IDLE)) begin
                    key_reg            <= 128'h0;
                    key_word_valid_reg <= 4'h0;
                    key_lock_reg       <= 1'b1;
                end
                if (write_data_i[6]) begin
                    rx_accept_count_reg <= 32'h0;
                    auth_fail_count_reg <= 32'h0;
                    fresh_fail_count_reg<= 32'h0;
                    overflow_count_reg  <= 32'h0;
                    overflow_sticky_reg <= 1'b0;
                end
            end

            if (write_en_i && (reg_offset != OFF_CTRL)) begin
                if ((reg_offset >= OFF_DATA0) && (reg_offset <= OFF_DATA15) &&
                    (reg_offset[1:0] == 2'b00)) begin
                    stage_payload_reg[(reg_offset - OFF_DATA0) * 8 +: 32]
                        <= write_data_i;
                end else begin
                    case (reg_offset)
                        OFF_FRAME_ID: begin
                            stage_id_reg <= write_data_i[28:0];
                        end
                        OFF_FRAME_FLAGS: begin
                            stage_dlc_reg <= write_data_i[3:0];
                            stage_ide_reg <= write_data_i[4];
                            stage_fdf_reg <= write_data_i[5];
                            stage_brs_reg <= write_data_i[6];
                        end
                        OFF_FRESHNESS: stage_freshness_reg <= write_data_i;
                        OFF_RX_TAG_HI: stage_rx_tag_reg[63:32] <= write_data_i;
                        OFF_RX_TAG_LO: stage_rx_tag_reg[31:0]  <= write_data_i;
                        OFF_TX_DATA_INDEX: tx_data_index_reg <= write_data_i[3:0];
                        OFF_DMA_BASE: begin
                            dma_base_reg      <= {write_data_i[31:2], 2'b00};
                            dma_next_addr_reg <= {write_data_i[31:2], 2'b00};
                            dma_record_count_reg <= 32'h0;
                        end
                        OFF_DMA_STRIDE: dma_stride_reg <= {write_data_i[31:2], 2'b00};
                        OFF_KEY0: if (!key_lock_reg && (state_reg == ST_IDLE)) begin
                            key_reg[31:0] <= write_data_i;
                            key_word_valid_reg[0] <= 1'b1;
                        end
                        OFF_KEY1: if (!key_lock_reg && (state_reg == ST_IDLE)) begin
                            key_reg[63:32] <= write_data_i;
                            key_word_valid_reg[1] <= 1'b1;
                        end
                        OFF_KEY2: if (!key_lock_reg && (state_reg == ST_IDLE)) begin
                            key_reg[95:64] <= write_data_i;
                            key_word_valid_reg[2] <= 1'b1;
                        end
                        OFF_KEY3: if (!key_lock_reg && (state_reg == ST_IDLE)) begin
                            key_reg[127:96] <= write_data_i;
                            key_word_valid_reg[3] <= 1'b1;
                        end
                        default: ;
                    endcase
                end
            end

            // Invalid or unavailable commands are counted as FIFO/control
            // overflow rather than silently accepted.
            if (ctrl_write && ((write_data_i[3] && !rx_user_push_event) ||
                               (write_data_i[2] && !tx_start_event) ||
                               (write_data_i[4] && (tx_count_reg == 0)) ||
                               (tx_pop_event && loopback_enable_reg &&
                                !loopback_push_event))) begin
                overflow_sticky_reg <= 1'b1;
                overflow_count_reg  <= overflow_count_reg + 32'd1;
                irq_sticky_reg      <= 1'b1;
            end

            if (rx_consume_event) begin
                work_is_rx_reg        <= 1'b1;
                work_id_reg           <= rx_id_fifo[rx_rptr_reg];
                work_dlc_reg          <= rx_dlc_fifo[rx_rptr_reg];
                work_ide_reg          <= rx_ide_fifo[rx_rptr_reg];
                work_fdf_reg          <= rx_fdf_fifo[rx_rptr_reg];
                work_brs_reg          <= rx_brs_fifo[rx_rptr_reg];
                work_freshness_reg    <= rx_fresh_fifo[rx_rptr_reg];
                work_expected_tag_reg <= rx_tag_fifo[rx_rptr_reg];
                work_payload_reg      <= rx_payload_fifo[rx_rptr_reg];
                work_timestamp_reg    <= cycle_counter_reg;
                if (!secoc_enable_reg) begin
                    state_reg <= ST_BYPASS;
                end else if (key_word_valid_reg != 4'hF) begin
                    state_reg        <= ST_IDLE;
                    last_auth_ok_reg <= 1'b0;
                    last_fresh_ok_reg<= 1'b0;
                    auth_fail_count_reg <= auth_fail_count_reg + 32'd1;
                    irq_sticky_reg   <= 1'b1;
                end else begin
                    aes_input_reg <= 128'h0;
                    aes_start_reg <= 1'b1;
                    state_reg     <= ST_WAIT_L;
                end
            end else if (tx_start_event) begin
                work_is_rx_reg        <= 1'b0;
                work_id_reg           <= stage_id_reg;
                work_dlc_reg          <= stage_dlc_reg;
                work_ide_reg          <= stage_ide_reg;
                work_fdf_reg          <= stage_fdf_reg;
                work_brs_reg          <= stage_brs_reg;
                work_freshness_reg    <= stage_freshness_reg;
                work_expected_tag_reg <= 64'h0;
                work_payload_reg      <= stage_payload_reg;
                work_timestamp_reg    <= cycle_counter_reg;
                if (!secoc_enable_reg) begin
                    state_reg <= ST_BYPASS;
                end else if (key_word_valid_reg != 4'hF) begin
                    state_reg        <= ST_IDLE;
                    last_auth_ok_reg <= 1'b0;
                    last_fresh_ok_reg<= 1'b0;
                    auth_fail_count_reg <= auth_fail_count_reg + 32'd1;
                    irq_sticky_reg   <= 1'b1;
                end else if (stage_freshness_reg <= last_tx_freshness_reg) begin
                    state_reg        <= ST_IDLE;
                    last_auth_ok_reg <= 1'b0;
                    last_fresh_ok_reg<= 1'b0;
                    fresh_fail_count_reg <= fresh_fail_count_reg + 32'd1;
                    irq_sticky_reg   <= 1'b1;
                end else begin
                    last_tx_freshness_reg <= stage_freshness_reg;
                    aes_input_reg <= 128'h0;
                    aes_start_reg <= 1'b1;
                    state_reg     <= ST_WAIT_L;
                end
            end

            if ((state_reg == ST_WAIT_L) && aes_done) begin
                cmac_k1_reg     <= cmac_double(aes_ciphertext);
                block_index_reg <= 3'd0;
                aes_input_reg   <= message_block(3'd0);
                aes_start_reg   <= 1'b1;
                state_reg       <= ST_WAIT_BLOCK;
            end else if ((state_reg == ST_WAIT_BLOCK) && aes_done) begin
                if (block_index_reg == 3'd4) begin
                    last_computed_tag_reg <= aes_ciphertext;
                    state_reg <= ST_IDLE;
                    if (work_is_rx_reg) begin
                        last_auth_ok_reg <=
                            (aes_ciphertext[127:64] == work_expected_tag_reg);
                        last_fresh_ok_reg <=
                            (work_freshness_reg > last_rx_freshness_reg);
                        if ((aes_ciphertext[127:64] == work_expected_tag_reg) &&
                            (work_freshness_reg > last_rx_freshness_reg)) begin
                            last_rx_freshness_reg <= work_freshness_reg;
                            rx_accept_count_reg   <= rx_accept_count_reg + 32'd1;
                            ids_submit_o          <= 1'b1;
                            ids_frame_id_o        <= work_id_reg[10:0];
                            ids_frame_dlc_o       <= work_dlc_reg;
                            ids_frame_payload_o   <= work_payload_reg[63:0];
                            ids_frame_fd_o        <= work_fdf_reg;
                            irq_sticky_reg        <= 1'b1;
                            if (dma_enable_reg && !dma_busy_reg) begin
                                dma_busy_reg        <= 1'b1;
                                dma_word_index_reg  <= 5'h0;
                                dma_record_base_reg <= dma_next_addr_reg;
                                dma_id_reg          <= work_id_reg;
                                dma_dlc_reg         <= work_dlc_reg;
                                dma_ide_reg         <= work_ide_reg;
                                dma_fdf_reg         <= work_fdf_reg;
                                dma_brs_reg         <= work_brs_reg;
                                dma_timestamp_reg   <= work_timestamp_reg;
                                dma_freshness_reg   <= work_freshness_reg;
                                dma_tag_reg         <= aes_ciphertext;
                                dma_payload_reg     <= work_payload_reg;
                            end else if (dma_enable_reg) begin
                                overflow_sticky_reg <= 1'b1;
                                overflow_count_reg  <= overflow_count_reg + 32'd1;
                            end
                        end else begin
                            irq_sticky_reg <= 1'b1;
                            if (aes_ciphertext[127:64] != work_expected_tag_reg)
                                auth_fail_count_reg <= auth_fail_count_reg + 32'd1;
                            if (work_freshness_reg <= last_rx_freshness_reg)
                                fresh_fail_count_reg <= fresh_fail_count_reg + 32'd1;
                        end
                    end else begin
                        last_auth_ok_reg  <= 1'b1;
                        last_fresh_ok_reg <= 1'b1;
                        irq_sticky_reg    <= 1'b1;
                    end
                end else begin
                    block_index_reg <= block_index_reg + 3'd1;
                    aes_input_reg <= aes_ciphertext ^
                        ((block_index_reg == 3'd3) ?
                         (message_block(3'd4) ^ cmac_k1_reg) :
                         message_block(block_index_reg + 3'd1));
                    aes_start_reg <= 1'b1;
                end
            end else if (state_reg == ST_BYPASS) begin
                state_reg             <= ST_IDLE;
                last_computed_tag_reg <= 128'h0;
                last_auth_ok_reg      <= 1'b1;
                last_fresh_ok_reg     <= 1'b1;
                irq_sticky_reg        <= 1'b1;
                if (work_is_rx_reg) begin
                    rx_accept_count_reg   <= rx_accept_count_reg + 32'd1;
                    last_rx_freshness_reg <= work_freshness_reg;
                    ids_submit_o          <= 1'b1;
                    ids_frame_id_o        <= work_id_reg[10:0];
                    ids_frame_dlc_o       <= work_dlc_reg;
                    ids_frame_payload_o   <= work_payload_reg[63:0];
                    ids_frame_fd_o        <= work_fdf_reg;
                end else begin
                    tx_id_fifo[tx_wptr_reg]      <= work_id_reg;
                    tx_dlc_fifo[tx_wptr_reg]     <= work_dlc_reg;
                    tx_ide_fifo[tx_wptr_reg]     <= work_ide_reg;
                    tx_fdf_fifo[tx_wptr_reg]     <= work_fdf_reg;
                    tx_brs_fifo[tx_wptr_reg]     <= work_brs_reg;
                    tx_fresh_fifo[tx_wptr_reg]   <= work_freshness_reg;
                    tx_tag_fifo[tx_wptr_reg]     <= 128'h0;
                    tx_payload_fifo[tx_wptr_reg] <= work_payload_reg;
                    tx_wptr_reg                  <= tx_wptr_reg + 1'b1;
                    tx_count_reg                 <= tx_count_reg + 1'b1;
                end
            end

            if (dma_busy_reg && dma_grant_i) begin
                if (dma_word_index_reg == 5'd21) begin
                    dma_busy_reg         <= 1'b0;
                    dma_word_index_reg   <= 5'h0;
                    dma_record_count_reg <= dma_record_count_reg + 32'd1;
                    dma_next_addr_reg    <= dma_next_addr_reg + dma_stride_reg;
                    irq_sticky_reg       <= 1'b1;
                end else begin
                    dma_word_index_reg <= dma_word_index_reg + 5'd1;
                end
            end
        end
    end

    always_comb begin
        read_data_o = 32'h0;
        if (read_en_i) begin
            if ((reg_offset >= OFF_DATA0) && (reg_offset <= OFF_DATA15) &&
                (reg_offset[1:0] == 2'b00)) begin
                read_data_o = stage_payload_reg[(reg_offset - OFF_DATA0) * 8 +: 32];
            end else begin
                case (reg_offset)
                    OFF_CTRL: read_data_o = {17'h0, key_lock_reg,
                                             dma_enable_reg, loopback_enable_reg,
                                             secoc_enable_reg, enable_reg, 10'h0};
                    OFF_STATUS: read_data_o = {11'h0,
                        overflow_sticky_reg, dma_enable_reg, loopback_enable_reg,
                        secoc_enable_reg, key_lock_reg, dma_busy_reg,
                        last_fresh_ok_reg, last_auth_ok_reg,
                        rx_count_reg[2:0], tx_count_reg[2:0],
                        (rx_count_reg == FIFO_DEPTH), (rx_count_reg == 0),
                        (tx_count_reg == FIFO_DEPTH), (tx_count_reg == 0),
                        irq_sticky_reg, (state_reg != ST_IDLE), enable_reg};
                    OFF_FRAME_ID: read_data_o = {3'h0, stage_id_reg};
                    OFF_FRAME_FLAGS: read_data_o = {25'h0, stage_brs_reg,
                                                    stage_fdf_reg, stage_ide_reg,
                                                    stage_dlc_reg};
                    OFF_FRESHNESS: read_data_o = stage_freshness_reg;
                    OFF_RX_TAG_HI: read_data_o = stage_rx_tag_reg[63:32];
                    OFF_RX_TAG_LO: read_data_o = stage_rx_tag_reg[31:0];
                    OFF_TX_HEAD_ID: read_data_o = (tx_count_reg == 0) ? 32'h0 :
                                                   {3'h0, tx_id_fifo[tx_rptr_reg]};
                    OFF_TX_HEAD_FLAGS: read_data_o = (tx_count_reg == 0) ? 32'h0 :
                        {25'h0, tx_brs_fifo[tx_rptr_reg], tx_fdf_fifo[tx_rptr_reg],
                         tx_ide_fifo[tx_rptr_reg], tx_dlc_fifo[tx_rptr_reg]};
                    OFF_TX_HEAD_FRESH: read_data_o = (tx_count_reg == 0) ? 32'h0 :
                                                    tx_fresh_fifo[tx_rptr_reg];
                    OFF_TX_HEAD_TAG_HI: read_data_o = (tx_count_reg == 0) ? 32'h0 :
                                                    tx_tag_fifo[tx_rptr_reg][127:96];
                    OFF_TX_HEAD_TAG_LO: read_data_o = (tx_count_reg == 0) ? 32'h0 :
                                                    tx_tag_fifo[tx_rptr_reg][95:64];
                    OFF_TX_DATA_INDEX: read_data_o = {28'h0, tx_data_index_reg};
                    OFF_TX_HEAD_DATA: read_data_o = (tx_count_reg == 0) ? 32'h0 :
                        tx_payload_fifo[tx_rptr_reg][tx_data_index_reg * 32 +: 32];
                    OFF_RX_ACCEPT: read_data_o = rx_accept_count_reg;
                    OFF_AUTH_FAIL: read_data_o = auth_fail_count_reg;
                    OFF_FRESH_FAIL: read_data_o = fresh_fail_count_reg;
                    OFF_OVERFLOW: read_data_o = overflow_count_reg;
                    OFF_LAST_FRESH: read_data_o = last_rx_freshness_reg;
                    OFF_DMA_BASE: read_data_o = dma_base_reg;
                    OFF_DMA_STRIDE: read_data_o = dma_stride_reg;
                    OFF_DMA_RECORDS: read_data_o = dma_record_count_reg;
                    OFF_KEY0: read_data_o = key_lock_reg ? 32'h0 : key_reg[31:0];
                    OFF_KEY1: read_data_o = key_lock_reg ? 32'h0 : key_reg[63:32];
                    OFF_KEY2: read_data_o = key_lock_reg ? 32'h0 : key_reg[95:64];
                    OFF_KEY3: read_data_o = key_lock_reg ? 32'h0 : key_reg[127:96];
                    OFF_KEY_STATUS: read_data_o = {26'h0, key_word_valid_reg,
                                                   key_lock_reg, secoc_enable_reg};
                    OFF_LAST_TAG_HI: read_data_o = last_computed_tag_reg[127:96];
                    OFF_LAST_TAG_LO: read_data_o = last_computed_tag_reg[95:64];
                    OFF_CAPABILITY: read_data_o = 32'h0001_043F;
                    default: read_data_o = 32'h0;
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    // Structural invariants remain close to the RTL. End-to-end temporal
    // properties and functional coverage are also checked by the UVM bench.
    assert property (@(posedge clk) disable iff (!rst_n)
        rx_count_reg <= FIFO_DEPTH && tx_count_reg <= FIFO_DEPTH)
        else $error("CAN-FD FIFO count exceeded configured depth");

    assert property (@(posedge clk) disable iff (!rst_n)
        dma_write_en_o |-> dma_req_o && dma_grant_i)
        else $error("CAN-FD DMA write occurred without request and grant");

    assert property (@(posedge clk) disable iff (!rst_n)
        ids_submit_o |-> last_auth_ok_reg && last_fresh_ok_reg)
        else $error("Unauthenticated CAN-FD frame was released to CAN-IDS");
`endif

endmodule
