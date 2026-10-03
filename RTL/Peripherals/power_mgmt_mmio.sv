// ============================================================
// Power and Activity Monitor MMIO
//
// Base address: 0x0000_0800
//   0x00 POWER_CTRL          [0] sleep_request, [1] clear counters
//   0x04 CPU_ACTIVE_CYCLES
//   0x08 AES_ACTIVE_CYCLES
//   0x0C UART_ACTIVE_CYCLES
//   0x10 SLEEP_CYCLES
//   0x14 DMA_ACTIVE_CYCLES
//   0x18 SENSOR_ACTIVE_CYCLES
//   0x1C CAN_IDS_ACTIVE_CYCLES
//
// These counters measure clock-cycle activity, not physical power directly.
// They provide comparable switching/activity evidence for experiments. Actual
// FPGA or ASIC power must still be obtained from a power-analysis tool.
//
// Counter interpretation:
//   counter value N means the corresponding activity input was high for N clock
//   edges since reset or the last clear operation. Counters wrap naturally after
//   2^32 increments; saturation and overflow interrupts are not implemented.
//
// sleep_o is a software-controlled clock-enable request used by mem_stage. It
// pauses UART, sensor/SPI, and DMA and blocks new AES-wrapper requests. The
// reusable AES primitive is allowed to finish an already accepted operation, so
// software enters sleep only after AES done. sleep_o does not gate the physical
// clock and does not halt the CPU pipeline by itself.
//
// WHY THE INTERFACE SIGNALS EXIST:
//   clk/rst_n maintain software-visible control and cycle counters.
//   addr/write_data/write_en/read_en provide the control/counter MMIO page.
//   each *_active_i is sampled separately to attribute activity by subsystem.
//   read_data_o exposes counters; sleep_o requests peripheral state freezing.
//   activity_counter_debug_o preserves a compact top-level observation point.
// ============================================================
module power_mgmt_mmio (
    input  logic        clk,                    // Common SoC clock
    input  logic        rst_n,                  // Active-low asynchronous reset
    input  logic [31:0] addr_i,                 // Power-page byte address
    input  logic [31:0] write_data_i,           // Control bit values
    input  logic        write_en_i,             // Selected register write
    input  logic        read_en_i,              // Selected register read
    input  logic        cpu_active_i,           // CPU activity indication
    input  logic        aes_active_i,           // AES busy/activity indication
    input  logic        uart_active_i,          // UART busy/activity indication
    input  logic        dma_active_i,           // DMA busy/activity indication
    input  logic        sensor_active_i,        // Sensor/SPI activity indication
    input  logic        can_ids_active_i,       // CAN-IDS frame-classification pulse
    output logic [31:0] read_data_o,            // Control/counter readback
    output logic        sleep_o,                // Peripheral clock-enable request
    output logic [31:0] activity_counter_debug_o // Compact top-level observation
);

    localparam logic [5:0] OFF_CTRL   = 6'h00;
    localparam logic [5:0] OFF_CPU    = 6'h04;
    localparam logic [5:0] OFF_AES    = 6'h08;
    localparam logic [5:0] OFF_UART   = 6'h0C;
    localparam logic [5:0] OFF_SLEEP  = 6'h10;
    localparam logic [5:0] OFF_DMA    = 6'h14;
    localparam logic [5:0] OFF_SENSOR = 6'h18;
    localparam logic [5:0] OFF_CAN_IDS = 6'h1C;

    // One monotonically increasing counter is kept for each activity class.
    logic [5:0]  reg_offset;
    logic [31:0] cpu_active_cycles;
    logic [31:0] aes_active_cycles;
    logic [31:0] uart_active_cycles;
    logic [31:0] sleep_cycles;
    logic [31:0] dma_active_cycles;
    logic [31:0] sensor_active_cycles;
    logic [31:0] can_ids_active_cycles;
    // Combinational write-decode pulse for clearing all counters together.
    logic        clear_counters;

    assign reg_offset = addr_i[5:0];

    // Compact XOR summary used only as a top-level debug output so FPGA tools
    // retain observable activity logic. It is not a total-cycle count, power
    // estimate, checksum for security, or replacement for individual counters.
    assign activity_counter_debug_o = aes_active_cycles ^ uart_active_cycles ^
                                      sleep_cycles ^ dma_active_cycles ^
                                      sensor_active_cycles ^ can_ids_active_cycles;
    assign clear_counters = write_en_i && (reg_offset == OFF_CTRL) && write_data_i[1];

    // Sleep control and cycle accumulation.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sleep_o              <= 1'b0;
            cpu_active_cycles    <= 32'h0;
            aes_active_cycles    <= 32'h0;
            uart_active_cycles   <= 32'h0;
            sleep_cycles         <= 32'h0;
            dma_active_cycles    <= 32'h0;
            sensor_active_cycles <= 32'h0;
            can_ids_active_cycles <= 32'h0;
        end else begin
            if (write_en_i && (reg_offset == OFF_CTRL)) begin
                // CTRL[0] is a software-requested sleep state.
                sleep_o <= write_data_i[0];
            end

            if (clear_counters) begin
                // CTRL[1] synchronously clears every measurement counter.
                cpu_active_cycles    <= 32'h0;
                aes_active_cycles    <= 32'h0;
                uart_active_cycles   <= 32'h0;
                sleep_cycles         <= 32'h0;
                dma_active_cycles    <= 32'h0;
                sensor_active_cycles <= 32'h0;
                can_ids_active_cycles <= 32'h0;
            end else begin
                // CPU active time excludes cycles intentionally counted as sleep.
                if (cpu_active_i && !sleep_o) cpu_active_cycles <= cpu_active_cycles + 32'd1;

                // Peripheral counters reflect the activity input sampled on this
                // edge. In this SoC those blocks are normally paused in sleep,
                // while the sleep counter records the idle interval itself.
                if (aes_active_i)             aes_active_cycles <= aes_active_cycles + 32'd1;
                if (uart_active_i)            uart_active_cycles <= uart_active_cycles + 32'd1;
                if (sleep_o)                  sleep_cycles <= sleep_cycles + 32'd1;
                if (dma_active_i)             dma_active_cycles <= dma_active_cycles + 32'd1;
                if (sensor_active_i)          sensor_active_cycles <= sensor_active_cycles + 32'd1;
                if (can_ids_active_i)         can_ids_active_cycles <= can_ids_active_cycles + 32'd1;
            end
        end
    end

    // CPU readback multiplexer for control and measurement registers.
    always_comb begin
        read_data_o = 32'h0;
        if (read_en_i) begin
            case (reg_offset)
                OFF_CTRL:   read_data_o = {31'h0, sleep_o};
                OFF_CPU:    read_data_o = cpu_active_cycles;
                OFF_AES:    read_data_o = aes_active_cycles;
                OFF_UART:   read_data_o = uart_active_cycles;
                OFF_SLEEP:  read_data_o = sleep_cycles;
                OFF_DMA:    read_data_o = dma_active_cycles;
                OFF_SENSOR: read_data_o = sensor_active_cycles;
                OFF_CAN_IDS:read_data_o = can_ids_active_cycles;
                default:    read_data_o = 32'h0;
            endcase
        end
    end

endmodule
