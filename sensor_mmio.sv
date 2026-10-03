// ============================================================
// Sensor MMIO Peripheral
//
// Base address: 0x0000_0400
//   0x00 SENSOR_DATA    readable sample register
//   0x04 SENSOR_STATUS  [0] data_ready
//   0x08 SENSOR_CONTROL [0] enable, [1] clear data_ready
//
// This is a synthesizable sensor model for early integration. It periodically
// changes the sample register so software can be developed before a real
// SPI/I2C sensor is connected.
//
// Software-visible behavior:
//   - data_ready=1 means SENSOR_DATA contains a sample not yet acknowledged.
//   - Reading SENSOR_DATA clears data_ready.
//   - CONTROL[1] also clears data_ready without reading the sample.
//   - When enabled, a deterministic new sample is created every 256 enabled
//     clock cycles. This timing is a demonstration model, not a physical sensor.
//
// WHY THE INTERFACE SIGNALS EXIST:
//   clk/rst_n hold the model and status registers in a known clock domain.
//   clk_en_i allows sleep control to pause sampling without a gated clock.
//   addr/write_data/write_en/read_en provide the CPU-visible MMIO transaction.
//   read_data_o returns the selected sensor register.
//   data_ready_irq_o prevents software from continuously polling for a sample.
//   active_o tells the activity monitor when periodic sampling is enabled.
// ============================================================
module sensor_mmio (
    input  logic        clk,              // Common SoC clock
    input  logic        rst_n,            // Active-low asynchronous reset
    input  logic        clk_en_i,         // Pauses sampling and MMIO side effects
    input  logic [31:0] addr_i,           // Sensor-page byte address
    input  logic [31:0] write_data_i,     // CPU store/injected sample value
    input  logic        write_en_i,       // Selected sensor write request
    input  logic        read_en_i,        // Selected sensor read request
    output logic [31:0] read_data_o,      // Selected register value
    output logic        data_ready_irq_o, // Level follows sticky data_ready
    output logic        active_o          // Sampling enabled indication
);

    localparam logic [5:0] OFF_DATA    = 6'h00;
    localparam logic [5:0] OFF_STATUS  = 6'h04;
    localparam logic [5:0] OFF_CONTROL = 6'h08;

    // Sensor sample and status visible to CPU software.
    logic [5:0]  reg_offset;
    logic [31:0] sensor_data_reg;
    logic        data_ready_reg;
    logic        enable_reg;
    // Simple free-running interval counter used to create a new sample.
    logic [7:0]  sample_tick;

    // The high page address was decoded by mem_stage; these six bits select the
    // local word-aligned sensor register.
    assign reg_offset = addr_i[5:0];
    assign data_ready_irq_o = data_ready_reg;
    assign active_o = enable_reg;

    // Sensor model and MMIO side effects.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sensor_data_reg <= 32'h1234_5678;
            data_ready_reg  <= 1'b1;
            enable_reg      <= 1'b1;
            sample_tick     <= 8'h0;
        end else if (clk_en_i) begin
            if (enable_reg) begin
                sample_tick <= sample_tick + 8'd1;
                if (sample_tick == 8'hff) begin
                    // Deterministic changing pattern used by tests and demos.
                    // Counter wrap on this edge begins the next 256-cycle period.
                    sensor_data_reg <= sensor_data_reg + 32'h0001_0101;
                    data_ready_reg  <= 1'b1;
                end
            end

            if (write_en_i) begin
                case (reg_offset)
                    // Allows the testbench or demo software to inject a sample.
                    OFF_DATA: sensor_data_reg <= write_data_i; // test/demo injection hook
                    OFF_CONTROL: begin
                        // CONTROL[0] enables sampling; CONTROL[1] acknowledges
                        // and clears the data-ready event.
                        enable_reg <= write_data_i[0];
                        if (write_data_i[1]) begin
                            data_ready_reg <= 1'b0;
                        end
                    end
                    default: ;
                endcase
            end

            if (read_en_i && (reg_offset == OFF_DATA)) begin
                // Reading the sample consumes the ready indication.
                data_ready_reg <= 1'b0;
            end
        end
    end

    // CPU load-data multiplexer.
    always_comb begin
        read_data_o = 32'h0;
        if (read_en_i) begin
            case (reg_offset)
                OFF_DATA:    read_data_o = sensor_data_reg;
                OFF_STATUS:  read_data_o = {31'h0, data_ready_reg};
                OFF_CONTROL: read_data_o = {31'h0, enable_reg};
                default:     read_data_o = 32'h0;
            endcase
        end
    end

endmodule
