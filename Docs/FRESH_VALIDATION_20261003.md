# Fresh validation on 3 October 2026

## Experimental inputs

The source was cloned into a new checkout at release v1.1.0, commit `e31227ddf8db7af6dcc089848dd589938981cbe0`. The tracked RTL, UVM, Testbench, and FPGA inputs were not changed. No earlier Build directory or Quartus database was copied. A locally licensed vendor SPI module was supplied separately, with its configuration and hashes recorded in `Evidence/2026-10-03/PROVENANCE.json`; the module is not redistributed.

Tool versions: Questa Intel FPGA Starter Edition 2023.3, UVM 1.1d, and Quartus Prime 23.1std.1 Build 993 SC Lite Edition. Device: Cyclone V `5CGXFC7C7F23C8`; clock constraint: 20 ns (50 MHz).

## Verification commands and outcomes

```powershell
& ./UVM/CAN_IDS/run_can_ids_uvm_regression.ps1 -ResultsDir ./Build/Regressions/20261003_CAN_IDS
& ./UVM/CANFD_SecOC/run_canfd_secoc_uvm_regression.ps1 -ResultsDir ./Build/Regressions/20261003_CANFD_SecOC
& ./Scripts/run_processor_integration_questa.ps1
& ./Scripts/run_processor_integration_questa.ps1 -Modes CanFdSecoc -DumpCanFdWaveform
```

Both UVM suites used seeds 1, 7, 19, 42, and 99. CAN-IDS checked 1,045 transactions (1,000 generated and 45 directed), with 38/38 portable bins per seed and four concurrent assertions. CAN-FD/SecOC checked 230 transactions (200 generated and 30 directed), with 16/16 portable bins per seed and five concurrent assertions. All ten runs reported zero UVM errors/fatals, scoreboard mismatches, and assertion failures. Native covergroups and the class constraint solver were not licensed; no native UCDB closure is claimed.

Processor modes passed All 161/0, SecurityExtension 36/0, CanFdSecoc 17/0, and FullSocScenario 18/0. These suites overlap and include different DUT scopes; the totals are not additive. The 10 ns behavioral simulation clock does not establish a 100 MHz post-fit operating point. The focused waveform comes from `u_canfd_soc_eval`, not an unexercised top-level instance.

## FPGA flow

The following commands ran sequentially from `FPGA/Quartus`, with each exit code checked and full console output saved:

```powershell
quartus_map riscv_aes_advancements
quartus_fit riscv_aes_advancements
quartus_asm riscv_aes_advancements
quartus_sta riscv_aes_advancements
quartus_pow riscv_aes_advancements
```

All five stages completed with zero errors. Warning counts were map 0, fit 3, assembler 0, timing 0, and power 1. The fitter warnings concern LogicLock availability and missing board pin assignments; the power warning concerns unidentified clock domains. External input/output timing is incomplete despite positive constrained internal-clock slacks.

Fresh results: 22,261 ALMs, 22,113 registers, 107 pins, 56.91 MHz slow-corner Fmax, 2.429 ns worst setup slack, and 0.144 ns worst hold slack. The 582.88 mW power result is vectorless with low confidence, not measured board power. All 12 reported setup/hold/pulse-width checks have positive slack and zero TNS. These new results reproduce the older values without reusing the old compilation database.

## Interpretation and boundaries

The design fits on the selected FPGA and meets the constrained 50 MHz internal clock. Neither physical CAN interoperability, sustained CAN-FD throughput, workload energy, full AUTOSAR compliance, native coverage closure, nor vehicle-dataset detection accuracy was measured. The CAN-FD/SecOC hierarchy occupies 28.8% of integrated ALMs and 42.6% of registers; this motivates storage optimization but does not isolate FIFO versus crypto cost.

With checking enabled, accepted frames feed IDS and optional RX DMA in parallel. Firmware can bypass checking, the IDS uses a truncated identifier and eight-byte payload window, and freshness state is volatile and shared. Protected configuration, per-PDU persistent freshness, wire payload mapping, and a physical protocol core remain future work.

`Scripts/archive_fresh_evidence.py` is the date-specific archiver for this campaign and intentionally validates the v1.1.0 source commit before archiving. `RUN_SUMMARY.json` contains machine-readable aggregates; `SHA256SUMS.json` contains evidence hashes. New evidence does not modify the historical July archive.
