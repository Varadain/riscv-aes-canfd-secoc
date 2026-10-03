# ============================================================
# Timing constraints for Lightweight IoT Security Processor
# Target clock: 50 MHz default board/system clock
#
# Adjust CLK_PERIOD_NS if your board clock is different:
#   20.000 ns = 50 MHz
#   10.000 ns = 100 MHz
# ============================================================

set CLK_PERIOD_NS 20.000

create_clock -name clk -period $CLK_PERIOD_NS [get_ports clk]

# Let Quartus derive device-appropriate setup/hold uncertainty.
derive_clock_uncertainty

