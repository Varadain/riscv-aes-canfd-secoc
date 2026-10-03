// ============================================================
// AES / AES-CTR MMIO Peripheral
//
// Base address: 0x0000_0300
// Existing ECB-compatible map is preserved:
//   0x00 CTRL      write [0] start, [1] clear done, [2] mode_ctr
//   0x04 STATUS    read  [0] busy, [1] done, [2] mode_ctr
//   0x08-0x14 KEY0..KEY3
//   0x18-0x24 PT0..PT3
//   0x28-0x34 CT0..CT3
//
// CTR additions:
//   0x38 NONCE0    nonce[31:0]
//   0x3C NONCE1    nonce[63:32]
//   0x40 COUNT0    counter[31:0]
//   0x44 COUNT1    counter[63:32]
//   0x48 KEY_CTRL  write [0] lock key, [1] zeroize key,
//                        [2] clear reuse error, [3] enable reuse protection,
//                        [4] disable reuse protection
//   0x4C SEC_STATUS read [0] key locked, [1] all key words written,
//                         [2] nonce/counter reuse rejected,
//                         [3] reuse protection enabled, [7:4] key-word mask
//
// ECB: ciphertext = AES_encrypt(plaintext)
// CTR: ciphertext = plaintext XOR AES_encrypt(nonce[63:0] || counter[63:0])
//      counter auto-increments after each block.
//
//  note:
// The CPU has 32-bit registers, but AES uses 128-bit key/plaintext/ciphertext
// blocks. Therefore four consecutive 32-bit MMIO registers are joined to form
// each 128-bit value. KEY0/PT0/CT0 hold the least-significant 32-bit word.
//
// Typical MMIO sequence:
//   1. Write KEY0..KEY3 and PT0..PT3.
//   2. For CTR, also write NONCE0..1 and COUNT0..1.
//   3. Write CTRL with mode in bit 2 and start in bit 0.
//   4. Poll STATUS.busy/done or wait for aes_done_irq_o.
//   5. Read CT0..CT3, then clear done with CTRL[1].
//
// Software must not change key, plaintext, mode, nonce, or counter while busy.
// CTR confidentiality also requires that the same key and nonce/counter input
// block never be reused for different plaintext blocks. This wrapper encrypts;
// it does not provide authentication or integrity checking.
//
// KEY_CTRL adds a small synthesizable key-lifecycle layer. After provisioning,
// software may lock key writes and readback. Zeroize clears the key and unlocks
// the interface for controlled reprovisioning. CTR reuse protection remembers
// the last accepted key, nonce and counter and rejects a repeated or decreasing
// counter for that same key/nonce pair.
// This improves prototype key/nonce hygiene, but register storage is not a
// substitute for a tamper-resistant key vault or authenticated encryption.
//
// WHY THE INTERFACE SIGNALS EXIST:
//   clk/rst_n provide deterministic sequential state and recovery.
//   clk_en_i pauses wrapper updates without physically gating the clock.
//   addr/write_data/write_en/read_en form the ordinary 32-bit CPU MMIO path.
//   custom_* is a parallel low-latency path for the optional custom-0 ISA.
//   read_data/custom_result keep MMIO and custom-instruction return paths clear.
//   irq/debug/active expose completion and observability to the rest of the SoC.
// ============================================================
module aes_mmio (
    input  logic        clk,                // Common SoC/AES clock
    input  logic        rst_n,              // Active-low wrapper reset
    input  logic        clk_en_i,           // Enables wrapper state changes
    input  logic [31:0] addr_i,             // AES-page byte address
    input  logic [31:0] write_data_i,       // CPU MMIO store value
    input  logic        write_en_i,         // Selected AES MMIO write
    input  logic        read_en_i,          // Selected AES MMIO read
    input  logic        custom_valid_i,     // Custom security command valid
    input  logic [2:0]  custom_cmd_i,       // Command encoded by funct3
    input  logic [31:0] custom_rs1_i,       // Forwarded custom rs1 value
    input  logic [31:0] custom_rs2_i,       // Forwarded custom rs2 value
    output logic [31:0] custom_result_o,    // Custom instruction WB value
    output logic [31:0] read_data_o,        // CPU MMIO load value
    output logic        aes_done_irq_o,     // Sticky completion interrupt level
    output logic [31:0] ciphertext_debug_o, // Ciphertext low word observation
    output logic        active_o            // High while encryption is busy
);

    // Register offsets are decoded from the low byte of the MMIO address.
    // The higher address bits are decoded by mem_stage before this module.
    localparam logic [7:0] OFF_CTRL   = 8'h00;
    localparam logic [7:0] OFF_STATUS = 8'h04;
    localparam logic [7:0] OFF_KEY0   = 8'h08;
    localparam logic [7:0] OFF_KEY1   = 8'h0C;
    localparam logic [7:0] OFF_KEY2   = 8'h10;
    localparam logic [7:0] OFF_KEY3   = 8'h14;
    localparam logic [7:0] OFF_PT0    = 8'h18;
    localparam logic [7:0] OFF_PT1    = 8'h1C;
    localparam logic [7:0] OFF_PT2    = 8'h20;
    localparam logic [7:0] OFF_PT3    = 8'h24;
    localparam logic [7:0] OFF_CT0    = 8'h28;
    localparam logic [7:0] OFF_CT1    = 8'h2C;
    localparam logic [7:0] OFF_CT2    = 8'h30;
    localparam logic [7:0] OFF_CT3    = 8'h34;
    localparam logic [7:0] OFF_NONCE0 = 8'h38;
    localparam logic [7:0] OFF_NONCE1 = 8'h3C;
    localparam logic [7:0] OFF_COUNT0 = 8'h40;
    localparam logic [7:0] OFF_COUNT1 = 8'h44;
    localparam logic [7:0] OFF_KEY_CTRL = 8'h48;
    localparam logic [7:0] OFF_SEC_STATUS = 8'h4C;

    // Commands used when the processor reaches AES through the custom ISA path
    // instead of ordinary load/store MMIO instructions.
    localparam logic [2:0] CSEC_AES_STATUS = 3'b001;
    localparam logic [2:0] CSEC_AES_START  = 3'b010;
    localparam logic [2:0] CSEC_AES_CT0    = 3'b011;
    localparam logic [2:0] CSEC_AES_CLEAR  = 3'b100;

    // Software-visible storage registers.
    logic [7:0]   reg_offset;
    logic [127:0] key_reg;
    logic [127:0] pt_reg;
    logic [127:0] ct_reg;
    logic [63:0]  nonce_reg;
    logic [63:0]  counter_reg;
    logic [3:0]   key_word_valid_reg;
    logic         key_lock_reg;
    logic         reuse_protect_reg;
    logic         nonce_reuse_error_reg;
    logic         last_ctr_valid_reg;
    logic [127:0] last_ctr_key_reg;
    logic [127:0] last_ctr_input_reg;

    // Sticky peripheral status. done remains high until a new operation starts
    // or software explicitly clears it.
    logic busy_reg;
    logic done_reg;
    logic mode_ctr_reg;

    // Signals connected to the reusable AES primitive.
    logic aes_start_pulse;
    logic aes_clk_en;
    logic aes_done;
    logic [127:0] aes_input_block;
    logic [127:0] aes_ciphertext;
    logic         key_valid;
    logic         ctr_reuse_detected;

    // mem_stage already selected the 0x300 page. The low byte identifies one
    // register within its 256-byte window.
    assign reg_offset = addr_i[7:0];

    // Qualify acceptance of the registered start pulse. The primitive still
    // receives the normal system clock; no gated clock is created. In the
    // current compatibility wrapper, clk_en gates request acceptance rather than
    // pausing an encryption that has already started.
    assign aes_clk_en = clk_en_i && busy_reg;

    // The interrupt is level-sensitive and follows the sticky done flag.
    // Software clears it through CTRL[1] or CSEC_AES_CLEAR.
    assign aes_done_irq_o = done_reg;
    assign ciphertext_debug_o = ct_reg[31:0];
    assign active_o = busy_reg;

    // ECB encrypts the plaintext directly. CTR encrypts nonce||counter to form
    // a 128-bit keystream, which is XORed with plaintext after AES completes.
    // Concatenation places nonce in bits [127:64] and counter in bits [63:0].
    assign aes_input_block = mode_ctr_reg ? {nonce_reg, counter_reg} : pt_reg;
    assign key_valid = &key_word_valid_reg;
    assign ctr_reuse_detected = last_ctr_valid_reg &&
                                (last_ctr_key_reg == key_reg) &&
                                (last_ctr_input_reg[127:64] == nonce_reg) &&
                                (counter_reg <= last_ctr_input_reg[63:0]);

    // Sequential register and transaction-control logic.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_reg          <= '0;
            pt_reg           <= '0;
            ct_reg           <= '0;
            nonce_reg        <= '0;
            counter_reg      <= '0;
            key_word_valid_reg <= 4'h0;
            key_lock_reg       <= 1'b0;
            reuse_protect_reg  <= 1'b1;
            nonce_reuse_error_reg <= 1'b0;
            last_ctr_valid_reg <= 1'b0;
            last_ctr_key_reg   <= '0;
            last_ctr_input_reg <= '0;
            busy_reg         <= 1'b0;
            done_reg         <= 1'b0;
            mode_ctr_reg     <= 1'b0;
            aes_start_pulse  <= 1'b0;
        end else begin
            // start is a pulse, not a stored level. Default it low every cycle.
            aes_start_pulse <= 1'b0;

            // Ordinary CPU store path. Writes are ignored when the peripheral
            // clock enable is disabled. Registers are not hardware-locked while
            // busy, so software must obey the programming sequence above.
            if (clk_en_i && write_en_i) begin
                case (reg_offset)
                    OFF_CTRL: begin
                        // CTRL[2] selects ECB(0) or CTR(1). mode_ctr_reg and the
                        // registered start pulse update together on this edge;
                        // the primitive accepts that pulse on the following edge,
                        // when the newly written mode is already available.
                        mode_ctr_reg <= write_data_i[2];

                        // CTRL[0] starts only when the previous block is idle.
                        if (write_data_i[0] && !busy_reg) begin
                            if (write_data_i[2] && reuse_protect_reg &&
                                ctr_reuse_detected) begin
                                // Reject repeated or decreasing counters for
                                // the same key and nonce.
                                nonce_reuse_error_reg <= 1'b1;
                            end else begin
                                aes_start_pulse <= 1'b1;
                                busy_reg        <= 1'b1;
                                done_reg        <= 1'b0;
                                if (write_data_i[2]) begin
                                    last_ctr_valid_reg <= 1'b1;
                                    last_ctr_key_reg   <= key_reg;
                                    last_ctr_input_reg <= {nonce_reg, counter_reg};
                                end
                            end
                        end

                        // CTRL[1] acknowledges/clears the sticky done flag.
                        if (write_data_i[1]) begin
                            done_reg <= 1'b0;
                        end
                    end
                    // Four 32-bit stores assemble each AES-wide value.
                    OFF_KEY0: if (!key_lock_reg && !busy_reg) begin
                        key_reg[31:0] <= write_data_i;
                        key_word_valid_reg[0] <= 1'b1;
                    end
                    OFF_KEY1: if (!key_lock_reg && !busy_reg) begin
                        key_reg[63:32] <= write_data_i;
                        key_word_valid_reg[1] <= 1'b1;
                    end
                    OFF_KEY2: if (!key_lock_reg && !busy_reg) begin
                        key_reg[95:64] <= write_data_i;
                        key_word_valid_reg[2] <= 1'b1;
                    end
                    OFF_KEY3: if (!key_lock_reg && !busy_reg) begin
                        key_reg[127:96] <= write_data_i;
                        key_word_valid_reg[3] <= 1'b1;
                    end
                    OFF_PT0: if (!busy_reg) pt_reg[31:0] <= write_data_i;
                    OFF_PT1: if (!busy_reg) pt_reg[63:32] <= write_data_i;
                    OFF_PT2: if (!busy_reg) pt_reg[95:64] <= write_data_i;
                    OFF_PT3: if (!busy_reg) pt_reg[127:96] <= write_data_i;
                    OFF_NONCE0: if (!busy_reg) nonce_reg[31:0] <= write_data_i;
                    OFF_NONCE1: if (!busy_reg) nonce_reg[63:32] <= write_data_i;
                    OFF_COUNT0: if (!busy_reg) counter_reg[31:0] <= write_data_i;
                    OFF_COUNT1: if (!busy_reg) counter_reg[63:32] <= write_data_i;
                    OFF_KEY_CTRL: begin
                        if (write_data_i[0]) key_lock_reg <= 1'b1;
                        if (write_data_i[2]) nonce_reuse_error_reg <= 1'b0;
                        if (write_data_i[3]) reuse_protect_reg <= 1'b1;
                        if (write_data_i[4]) reuse_protect_reg <= 1'b0;
                        if (write_data_i[1] && !busy_reg) begin
                            key_reg             <= '0;
                            key_word_valid_reg  <= 4'h0;
                            key_lock_reg        <= 1'b0;
                            last_ctr_valid_reg  <= 1'b0;
                            last_ctr_key_reg    <= '0;
                            last_ctr_input_reg  <= '0;
                        end
                    end
                    default: ;
                endcase
            end

            // Custom security instruction path. CSEC_AES_START loads two source
            // registers into the low 64 bits of plaintext and starts CTR mode.
            // The upper plaintext words remain zero for this compact command.
            if (clk_en_i && custom_valid_i) begin
                case (custom_cmd_i)
                    CSEC_AES_START: begin
                        mode_ctr_reg <= 1'b1;
                        pt_reg[31:0] <= custom_rs1_i;
                        pt_reg[63:32] <= custom_rs2_i;
                        pt_reg[127:64] <= 64'h0;
                        if (!busy_reg) begin
                            if (reuse_protect_reg && ctr_reuse_detected) begin
                                nonce_reuse_error_reg <= 1'b1;
                            end else begin
                                aes_start_pulse <= 1'b1;
                                busy_reg        <= 1'b1;
                                done_reg        <= 1'b0;
                                last_ctr_valid_reg <= 1'b1;
                                last_ctr_key_reg   <= key_reg;
                                last_ctr_input_reg <= {nonce_reg, counter_reg};
                            end
                        end
                    end
                    CSEC_AES_CLEAR: begin
                        done_reg <= 1'b0;
                    end
                    default: ;
                endcase
            end

            // Capture the primitive result only for the currently active MMIO
            // transaction. The !aes_start_pulse guard prevents a stale done
            // pulse from being mistaken for completion of a newly started job.
            // Software should not assert sleep/disable clk_en_i while busy,
            // because the reusable primitive can finish while wrapper status is
            // paused and its one-cycle done pulse would not be captured here.
            if (clk_en_i && aes_done && busy_reg && !aes_start_pulse) begin
                // In CTR mode, AES output is the keystream rather than the final
                // ciphertext. XOR with plaintext to produce the stored result.
                // CTR encryption and decryption use the same XOR operation.
                ct_reg   <= mode_ctr_reg ? (pt_reg ^ aes_ciphertext) : aes_ciphertext;
                busy_reg <= 1'b0;
                done_reg <= 1'b1;
                if (mode_ctr_reg) begin
                    // Each CTR block must use a unique counter value.
                    counter_reg <= counter_reg + 64'd1;
                end
            end
        end
    end

    // Combinational custom-instruction and MMIO readback multiplexers. These
    // reads have no side effect; done remains set until explicitly cleared or a
    // new accepted start resets it.
    // Default zero values prevent stale or multiple peripherals from driving
    // undefined read data.
    always_comb begin
        custom_result_o = 32'h0;
        case (custom_cmd_i)
            CSEC_AES_STATUS: custom_result_o = {29'h0, mode_ctr_reg, done_reg, busy_reg};
            CSEC_AES_START:  custom_result_o = {29'h0, mode_ctr_reg, done_reg, busy_reg};
            CSEC_AES_CT0:    custom_result_o = ct_reg[31:0];
            CSEC_AES_CLEAR:  custom_result_o = {31'h0, done_reg};
            default:         custom_result_o = 32'h0;
        endcase

        read_data_o = 32'h0;
        if (read_en_i) begin
            case (reg_offset)
                OFF_CTRL:   read_data_o = {29'h0, mode_ctr_reg, done_reg, busy_reg};
                OFF_STATUS: read_data_o = {29'h0, mode_ctr_reg, done_reg, busy_reg};
                OFF_KEY0:   read_data_o = key_lock_reg ? 32'h0 : key_reg[31:0];
                OFF_KEY1:   read_data_o = key_lock_reg ? 32'h0 : key_reg[63:32];
                OFF_KEY2:   read_data_o = key_lock_reg ? 32'h0 : key_reg[95:64];
                OFF_KEY3:   read_data_o = key_lock_reg ? 32'h0 : key_reg[127:96];
                OFF_PT0:    read_data_o = pt_reg[31:0];
                OFF_PT1:    read_data_o = pt_reg[63:32];
                OFF_PT2:    read_data_o = pt_reg[95:64];
                OFF_PT3:    read_data_o = pt_reg[127:96];
                OFF_CT0:    read_data_o = ct_reg[31:0];
                OFF_CT1:    read_data_o = ct_reg[63:32];
                OFF_CT2:    read_data_o = ct_reg[95:64];
                OFF_CT3:    read_data_o = ct_reg[127:96];
                OFF_NONCE0: read_data_o = nonce_reg[31:0];
                OFF_NONCE1: read_data_o = nonce_reg[63:32];
                OFF_COUNT0: read_data_o = counter_reg[31:0];
                OFF_COUNT1: read_data_o = counter_reg[63:32];
                OFF_KEY_CTRL: read_data_o = {28'h0, reuse_protect_reg,
                                              nonce_reuse_error_reg,
                                              key_valid, key_lock_reg};
                OFF_SEC_STATUS: read_data_o = {24'h0, key_word_valid_reg,
                                                reuse_protect_reg,
                                                nonce_reuse_error_reg,
                                                key_valid, key_lock_reg};
                default:    read_data_o = 32'h0;
            endcase
        end
    end

    // The stable wrapper keeps the MMIO block independent of the internal AES
    // microarchitecture used by the publication core.
    aes128_lowpower u_aes128_lowpower (
        .clk       (clk),
        .reset     (~rst_n),
        .clk_en    (aes_clk_en),
        .start     (aes_start_pulse),
        .plaintext (aes_input_block),
        .key       (key_reg),
        .ciphertext(aes_ciphertext),
        .done      (aes_done)
    );

endmodule
