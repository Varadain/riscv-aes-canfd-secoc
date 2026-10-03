// ============================================================
// MEM STAGE / Lightweight IoT Security SoC Interconnect
//
// Normal RAM remains at low memory. MMIO ranges:
//   0x0000_0300 AES / AES-CTR
//   0x0000_0400 Sensor MMIO + Intel Avalon SPI sensor I/O window
//   0x0000_0500 UART MMIO
//   0x0000_0600 Interrupt controller
//   0x0000_0700 DMA-lite
//   0x0000_0800 Power/activity control
//   0x0000_0900 Automotive CAN intrusion-detection engine
//   0x0000_0A00 CAN-FD frame controller, SecOC, FIFO and RX DMA
//
// Custom-0 security ISA commands (opcode 0001011, funct3 command):
//   000 CSEC_XOR         rd = rs1 ^ rs2
//   001 CSEC_AES_STATUS  rd = {29'b0, mode_ctr, done, busy}
//   010 CSEC_AES_START   start AES-CTR with pt[31:0]=rs1, pt[63:32]=rs2
//   011 CSEC_AES_CT0     rd = ciphertext[31:0]
//   100 CSEC_AES_CLEAR   clear AES done flag
//
// MENTAL MODEL:
//   The EX stage sends this module an address/result and store data. This MEM
//   stage behaves like a small internal bus interconnect:
//     1. Recover the effective address and load/store format tag.
//     2. Decide whether the request targets RAM or exactly one MMIO page.
//     3. Assert a read/write enable only for the selected destination.
//     4. Return one selected read result to the WB stage.
//   Custom instructions use a parallel command path and receive highest
//   priority in the final read-result multiplexer.
//
// WHY THE INTERFACE SIGNALS EXIST:
//   clk/rst_n synchronize the stateful MMIO slaves instantiated in this stage.
//   addr/write_data plus mem_read/mem_write carry ordinary load/store traffic.
//   custom_valid/custom_cmd identify the separate custom-0 security operation.
//   read_data_o is the single return path, avoiding multiple bus drivers.
//   UART/SPI pins connect real external I/O; irq/sleep connect SoC control.
//   AES and activity debug outputs make implementation behavior observable.
// ============================================================
module mem_stage (
    input  logic        clk,          // Common SoC clock
    input  logic        rst_n,        // Active-low reset
    input  logic [31:0] addr_i,       // Tagged EX result or custom rs1 operand
    input  logic [31:0] write_data_i, // Forwarded rs2/store/custom operand
    input  logic        mem_read_i,   // CPU requests a load/MMIO read
    input  logic        mem_write_i,  // CPU requests a store/MMIO write
    input  logic        custom_valid_i, // Current instruction is custom-0
    input  logic [2:0]  custom_cmd_i, // funct3-selected custom command
    output logic [31:0] read_data_o,  // Value forwarded toward the WB stage

    output logic        uart_tx_o,    // Encrypted serial output pin
    input  logic        spi_miso_i,   // Serial sensor data input
    output logic        spi_mosi_o,   // Serial sensor command/data output
    output logic        spi_sclk_o,   // Sensor SPI clock
    output logic        spi_ss_n_o,   // Active-low sensor chip select
    output logic        irq_o,        // Combined enabled interrupt request
    output logic        sleep_o,      // Software-controlled peripheral idle state
    output logic        aes_done_o,   // Top-level AES completion observation
    output logic [31:0] aes_ciphertext_debug_o, // Low ciphertext debug word
    output logic [31:0] activity_counter_debug_o, // Combined activity debug value
    output logic        can_ids_alert_debug_o     // Sticky CAN attack indication
);

    // The execute stage packs the load/store type into address_i[31:29].
    // The remaining 29 bits form the real byte address used by RAM and MMIO.
    logic [2:0]  ls_tag;
    logic [31:0] eff_addr;

    // RAM words are always physically 32 bits. load_store_unit selects or
    // merges a byte/halfword when the architectural operation is narrower.
    logic [31:0] raw_mem_word;      // Complete aligned word read from RAM
    logic [31:0] merged_store_word; // Old word with selected byte/half replaced
    logic [31:0] mem_read_data;     // Final sign/zero-extended CPU load value

    // Page-select signals form a one-hot peripheral selection for valid,
    // fully-known addresses. mmio_sel is their OR and distinguishes MMIO from
    // ordinary data RAM.
    logic aes_sel;
    logic sensor_sel;
    logic uart_sel;
    logic intc_sel;
    logic dma_sel;
    logic power_sel;
    logic can_ids_sel;
    logic canfd_sel;
    logic mmio_sel;

    // Each peripheral receives a request only when both the CPU operation and
    // that peripheral's decoded page are active.
    logic aes_write_en;
    logic aes_read_en;
    logic sensor_write_en;
    logic sensor_read_en;
    logic uart_write_en;
    logic uart_read_en;
    logic intc_write_en;
    logic intc_read_en;
    logic dma_write_en;
    logic dma_read_en;
    logic power_write_en;
    logic power_read_en;
    logic can_ids_write_en;
    logic can_ids_read_en;
    logic canfd_write_en;
    logic canfd_read_en;

    logic data_mem_read_en;
    logic data_mem_write_en;

    // Every slave has a private read-data wire. Only the final multiplexer is
    // allowed to drive read_data_o, preventing multiple-driver conflicts.
    logic [31:0] aes_read_data;
    logic [31:0] sensor_read_data;
    logic [31:0] uart_read_data;
    logic [31:0] intc_read_data;
    logic [31:0] dma_read_data;
    logic [31:0] power_read_data;
    logic [31:0] can_ids_read_data;
    logic [31:0] canfd_read_data;
    logic [31:0] aes_custom_result;
    logic [31:0] custom_result;

    // Event and activity wires connect peripherals to the interrupt and
    // activity-monitoring blocks without involving the CPU datapath directly.
    logic aes_done_irq;
    logic aes_active;
    logic sensor_ready_irq;
    logic sensor_active;
    logic uart_busy;
    logic uart_done;
    logic uart_done_irq;
    logic uart_active;
    logic dma_busy;
    logic dma_done;
    logic dma_done_irq;
    logic dma_active;
    logic can_ids_alert_irq;
    logic can_ids_active;
    logic canfd_secoc_irq;
    logic canfd_active;
    logic canfd_ids_submit;
    logic [10:0] canfd_ids_frame_id;
    logic [3:0]  canfd_ids_frame_dlc;
    logic [63:0] canfd_ids_frame_payload;
    logic        canfd_ids_frame_fd;
    logic        can_ids_hw_ready;

    // DMA master-side RAM interface. These signals are independent of the
    // CPU's normal RAM port, allowing one-word staged transfers.
    logic [31:0] dma_mem_read_addr;
    logic [31:0] dma_mem_write_addr;
    logic [31:0] dma_mem_write_data;
    logic        dma_mem_write_en;
    logic [31:0] dma_mem_read_data;
    logic [31:0] ram_dma_read_addr;
    logic [31:0] ram_dma_write_addr;
    logic [31:0] ram_dma_write_data;
    logic        ram_dma_write_en;
    logic        canfd_dma_req;
    logic        canfd_dma_grant;
    logic [31:0] canfd_dma_write_addr;
    logic [31:0] canfd_dma_write_data;
    logic        canfd_dma_write_en;

    // EX encodes load/store width in the upper three bits of addr_i. Recover
    // that metadata and clear those bits to recreate the real byte address.
    // For normal word operations the tag is 000, so addr_i is unchanged.
    assign ls_tag   = addr_i[31:29];
    assign eff_addr = {3'b000, addr_i[28:0]};

    // Each peripheral owns one 256-byte page because bits [7:0] remain free as
    // its internal register offset. Comparing [31:8] therefore decodes:
    //   eff_addr = 0x0000_05xx -> UART page selected
    //   eff_addr = 0x0000_050C -> UART still selected, offset is 0x0C
    // A valid address selects at most one page.
    assign aes_sel    = (eff_addr[31:8] == 24'h000003); // 0x0000_0300
    assign sensor_sel = (eff_addr[31:8] == 24'h000004); // 0x0000_0400
    assign uart_sel   = (eff_addr[31:8] == 24'h000005); // 0x0000_0500
    assign intc_sel   = (eff_addr[31:8] == 24'h000006); // 0x0000_0600
    assign dma_sel    = (eff_addr[31:8] == 24'h000007); // 0x0000_0700
    assign power_sel  = (eff_addr[31:8] == 24'h000008); // 0x0000_0800
    assign can_ids_sel= (eff_addr[31:8] == 24'h000009); // 0x0000_0900
    assign canfd_sel   = (eff_addr[31:8] == 24'h00000A); // 0x0000_0A00
    assign mmio_sel   = aes_sel | sensor_sel | uart_sel | intc_sel |
                        dma_sel | power_sel | can_ids_sel | canfd_sel;

    // Qualify the CPU request with the decoded peripheral page. For example,
    // an SW to 0x0000_0500 makes mem_write_i=1 and uart_sel=1, so only
    // uart_write_en is asserted. All unrelated peripheral enables stay zero.
    assign aes_write_en    = mem_write_i & aes_sel;
    assign aes_read_en     = mem_read_i  & aes_sel;
    assign sensor_write_en = mem_write_i & sensor_sel;
    assign sensor_read_en  = mem_read_i  & sensor_sel;
    assign uart_write_en   = mem_write_i & uart_sel;
    assign uart_read_en    = mem_read_i  & uart_sel;
    assign intc_write_en   = mem_write_i & intc_sel;
    assign intc_read_en    = mem_read_i  & intc_sel;
    assign dma_write_en    = mem_write_i & dma_sel;
    assign dma_read_en     = mem_read_i  & dma_sel;
    assign power_write_en  = mem_write_i & power_sel;
    assign power_read_en   = mem_read_i  & power_sel;
    assign can_ids_write_en= mem_write_i & can_ids_sel;
    assign can_ids_read_en = mem_read_i  & can_ids_sel;
    assign canfd_write_en  = mem_write_i & canfd_sel;
    assign canfd_read_en   = mem_read_i  & canfd_sel;

    // Ordinary non-MMIO addresses access RAM. A narrow SB/SH store must first
    // read the existing 32-bit word so load_store_unit can preserve the bytes
    // that are not being changed. This is why the RAM read port is enabled for
    // either a load OR a store. Custom commands are excluded so their rs1/rs2
    // operand values cannot accidentally be interpreted as a RAM request.
    assign data_mem_read_en  = (mem_read_i | mem_write_i) & ~mmio_sel & ~custom_valid_i;
    assign data_mem_write_en = mem_write_i & ~mmio_sel & ~custom_valid_i;

    // Custom operands arrive through the same EX/MEM fields normally named
    // addr_i and write_data_i. Command 000 performs a direct 32-bit XOR here.
    // Commands 001-100 are interpreted by aes_mmio and return status, start
    // acknowledgement, ciphertext, or clear-command results.
    assign custom_result = (custom_cmd_i == 3'b000) ? (addr_i ^ write_data_i) : aes_custom_result;

    // Format byte, halfword, and word loads/stores according to ls_tag.
    // For loads, this block selects the addressed byte/half and performs sign
    // or zero extension. For stores, it creates a complete replacement word by
    // merging the new byte/half with the unaffected bytes from raw_mem_word.
    load_store_unit u_load_store_unit (
        .ls_tag_i           (ls_tag),
        .byte_off_i         (eff_addr[1:0]),
        .mem_word_i         (raw_mem_word),
        .store_data_i       (write_data_i),
        .load_data_o        (mem_read_data),
        .merged_store_word_o(merged_store_word)
    );

    // The CPU uses the main RAM port. DMA-lite uses the second port to move
    // complete words without changing the processor pipeline. Word stores can
    // write write_data_i directly; byte/half stores use merged_store_word.
    data_mem u_data_mem (
        .clk             (clk),
        .rst_n           (rst_n),
        .addr_i          (eff_addr),
        .write_data_i    ((ls_tag == 3'b000) ? write_data_i : merged_store_word),
        .mem_read_i      (data_mem_read_en),
        .mem_write_i     (data_mem_write_en),
        .read_data_o     (raw_mem_word),
        .dma_read_addr_i (ram_dma_read_addr),
        .dma_write_addr_i(ram_dma_write_addr),
        .dma_write_data_i(ram_dma_write_data),
        .dma_write_en_i  (ram_dma_write_en),
        .dma_read_data_o (dma_mem_read_data)
    );

    // Peripheral activity is controlled with clock-enable inputs. No derived
    // or combinationally gated clocks are created. UART, SPI, and DMA hold their
    // state when sleep_o is high. The AES compatibility wrapper blocks new
    // requests, but an already accepted reusable-core operation continues; the
    // software sequence therefore enters sleep only after AES completion.
    aes_mmio u_aes_mmio (
        .clk           (clk),
        .rst_n         (rst_n),
        .clk_en_i      (!sleep_o), // Block AES wrapper access while sleep is set.
        .addr_i        (eff_addr),
        .write_data_i  (write_data_i),
        .write_en_i    (aes_write_en),
        .read_en_i     (aes_read_en),
        // XOR command 000 is completed locally above; only AES-related custom
        // commands are presented to the AES wrapper.
        .custom_valid_i(custom_valid_i && (custom_cmd_i != 3'b000)),
        .custom_cmd_i  (custom_cmd_i),
        // In custom mode these fields contain forwarded rs1 and rs2 values,
        // not a normal memory address and store payload.
        .custom_rs1_i  (addr_i),
        .custom_rs2_i  (write_data_i),
        .custom_result_o(aes_custom_result),
        .read_data_o   (aes_read_data),
        .aes_done_irq_o(aes_done_irq),
        .ciphertext_debug_o(aes_ciphertext_debug_o),
        .active_o      (aes_active)
    );

    // Software uses ordinary loads/stores in the 0x400 page. This wrapper turns
    // those register accesses into external SPI transfers and returns received
    // sensor data through sensor_read_data.
    sensor_spi_mmio u_sensor_spi_mmio (
        .clk                 (clk),
        .rst_n               (rst_n),
        .clk_en_i            (!sleep_o),
        .addr_i              (eff_addr),
        .write_data_i        (write_data_i),
        .write_en_i          (sensor_write_en),
        .read_en_i           (sensor_read_en),
        .spi_miso_i          (spi_miso_i),
        .spi_mosi_o          (spi_mosi_o),
        .spi_sclk_o          (spi_sclk_o),
        .spi_ss_n_o          (spi_ss_n_o),
        .read_data_o         (sensor_read_data),
        .data_ready_irq_o    (sensor_ready_irq),
        .active_o            (sensor_active)
    );

    // A TXDATA write in the 0x500 page starts serialization of write_data_i[7:0]
    // on uart_tx_o. Status reads expose busy/done information to software.
    uart_mmio u_uart_mmio (
        .clk          (clk),
        .rst_n        (rst_n),
        .clk_en_i     (!sleep_o),
        .addr_i       (eff_addr),
        .write_data_i (write_data_i),
        .write_en_i   (uart_write_en),
        .read_en_i    (uart_read_en),
        .read_data_o  (uart_read_data),
        .uart_tx_o    (uart_tx_o),
        .tx_busy_o    (uart_busy),
        .tx_done_o    (uart_done),
        .tx_done_irq_o(uart_done_irq),
        .active_o     (uart_active)
    );

    // Keep the interrupt controller enabled in sleep so short completion pulses
    // are latched into pending bits. Software can read, enable, and explicitly
    // clear those pending events through the 0x600 MMIO page.
    simple_intc u_simple_intc (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .clk_en_i               (1'b1),
        .addr_i                 (eff_addr),
        .write_data_i           (write_data_i),
        .write_en_i             (intc_write_en),
        .read_en_i              (intc_read_en),
        .aes_done_irq_i         (aes_done_irq),
        .uart_tx_done_irq_i     (uart_done_irq),
        .sensor_data_ready_irq_i(sensor_ready_irq),
        .dma_done_irq_i         (dma_done_irq),
        .can_ids_alert_irq_i    (can_ids_alert_irq),
        .canfd_secoc_irq_i      (canfd_secoc_irq),
        .read_data_o            (intc_read_data),
        .irq_o                  (irq_o)
    );

    // DMA-lite is programmed through the 0x700 page. It generates source and
    // destination RAM addresses, reads one 32-bit word through its read port,
    // and commits that word through dma_mem_write_en on the second RAM port.
    dma_lite u_dma_lite (
        .clk             (clk),
        .rst_n           (rst_n),
        .clk_en_i        (!sleep_o),
        .addr_i          (eff_addr),
        .write_data_i    (write_data_i),
        .write_en_i      (dma_write_en),
        .read_en_i       (dma_read_en),
        .dma_read_data_i (dma_mem_read_data),
        .read_data_o     (dma_read_data),
        .dma_read_addr_o (dma_mem_read_addr),
        .dma_write_addr_o(dma_mem_write_addr),
        .dma_write_data_o(dma_mem_write_data),
        .dma_write_en_o  (dma_mem_write_en),
        .busy_o          (dma_busy),
        .done_o          (dma_done),
        .done_irq_o      (dma_done_irq),
        .active_o        (dma_active)
    );

    // DMA-lite keeps priority because it cannot accept wait states. The CAN-FD
    // writer holds its current record word until grant, then advances. This
    // provides deterministic sharing of data_mem's second port.
    assign canfd_dma_grant   = !dma_busy;
    assign ram_dma_read_addr = dma_mem_read_addr;
    assign ram_dma_write_addr = dma_mem_write_en ? dma_mem_write_addr :
                                 canfd_dma_write_addr;
    assign ram_dma_write_data = dma_mem_write_en ? dma_mem_write_data :
                                 canfd_dma_write_data;
    assign ram_dma_write_en = dma_mem_write_en |
                              (canfd_dma_write_en && canfd_dma_grant);

    canfd_secoc_mmio u_canfd_secoc_mmio (
        .clk                (clk),
        .rst_n              (rst_n),
        .clk_en_i           (!sleep_o),
        .addr_i             (eff_addr),
        .write_data_i       (write_data_i),
        .write_en_i         (canfd_write_en),
        .read_en_i          (canfd_read_en),
        .read_data_o        (canfd_read_data),
        .irq_o              (canfd_secoc_irq),
        .active_o           (canfd_active),
        .ids_submit_o       (canfd_ids_submit),
        .ids_frame_id_o     (canfd_ids_frame_id),
        .ids_frame_dlc_o    (canfd_ids_frame_dlc),
        .ids_frame_payload_o(canfd_ids_frame_payload),
        .ids_frame_fd_o     (canfd_ids_frame_fd),
        .dma_req_o          (canfd_dma_req),
        .dma_grant_i        (canfd_dma_grant),
        .dma_write_addr_o   (canfd_dma_write_addr),
        .dma_write_data_o   (canfd_dma_write_data),
        .dma_write_en_o     (canfd_dma_write_en)
    );

    // The CPU reads complete MCP2515 CAN frames through the existing SPI page,
    // then writes ID, DLC, and 64 payload bits into this 0x900 page. A CTRL
    // submit performs one deterministic classification and raises a sticky IDS
    // alert for DoS, fuzzy, or spoof signatures.
    can_ids_mmio u_can_ids_mmio (
        .clk          (clk),
        .rst_n        (rst_n),
        .clk_en_i     (!sleep_o),
        .addr_i       (eff_addr),
        .write_data_i (write_data_i),
        .write_en_i   (can_ids_write_en),
        .read_en_i    (can_ids_read_en),
        .hw_submit_i  (canfd_ids_submit && can_ids_hw_ready),
        .hw_frame_id_i(canfd_ids_frame_id),
        .hw_frame_dlc_i(canfd_ids_frame_dlc),
        .hw_frame_payload_i(canfd_ids_frame_payload),
        .hw_frame_fd_i(canfd_ids_frame_fd),
        .hw_ready_o   (can_ids_hw_ready),
        .read_data_o  (can_ids_read_data),
        .alert_irq_o  (can_ids_alert_irq),
        .alert_debug_o(can_ids_alert_debug_o),
        .active_o     (can_ids_active)
    );

    // This block stays active because it owns sleep_o and must count sleep
    // cycles as well as CPU and peripheral activity. cpu_active_i is tied high
    // here; power_mgmt_mmio itself excludes cycles for which sleep_o is high.
    power_mgmt_mmio u_power_mgmt_mmio (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .addr_i                  (eff_addr),
        .write_data_i            (write_data_i),
        .write_en_i              (power_write_en),
        .read_en_i               (power_read_en),
        .cpu_active_i            (1'b1),
        .aes_active_i            (aes_active),
        .uart_active_i           (uart_active),
        .dma_active_i            (dma_active),
        .sensor_active_i         (sensor_active),
        .can_ids_active_i        (can_ids_active | canfd_active),
        .read_data_o             (power_read_data),
        .sleep_o                 (sleep_o),
        .activity_counter_debug_o(activity_counter_debug_o)
    );

    // One read-data multiplexer returns exactly one value toward WB. Priority:
    //   1. custom command result
    //   2. selected peripheral register when mem_read_i=1
    //   3. ordinary formatted RAM load
    //   4. zero when no read/custom result is requested
    // case (1'b1) is a compact priority/one-hot mux: the first select signal
    // equal to one chooses its corresponding read-data wire.
    always_comb begin
        read_data_o = 32'h0;
        if (custom_valid_i) begin
            // Custom instructions write their returned value through the same
            // MEM/WB path used by a normal load instruction.
            read_data_o = custom_result;
        end else if (mem_read_i) begin
            case (1'b1)
                aes_sel:    read_data_o = aes_read_data;
                sensor_sel: read_data_o = sensor_read_data;
                uart_sel:   read_data_o = uart_read_data;
                intc_sel:   read_data_o = intc_read_data;
                dma_sel:    read_data_o = dma_read_data;
                power_sel:  read_data_o = power_read_data;
                can_ids_sel:read_data_o = can_ids_read_data;
                canfd_sel:   read_data_o = canfd_read_data;
                // If no peripheral page matches, complete an ordinary RAM
                // load. DEAD_BAAD remains a recognizable defensive value if
                // mmio_sel is ever asserted without a corresponding case arm.
                default:    read_data_o = mmio_sel ? 32'hDEAD_BAAD : mem_read_data;
            endcase
        end
    end

    // Export the AES completion event separately for FPGA/debug observation.
    assign aes_done_o = aes_done_irq;
endmodule
