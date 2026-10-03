# RISC-V, AES, CAN-IDS, and CAN-FD/SecOC

This package supports the manuscript *A RISC-V Security Processor with AES Acceleration and Secure CAN-FD Monitoring*. It contains the processor and security RTL, focused UVM environments, the C-DPI CMAC reference, archived verification logs, FPGA reports, and the VCD underlying the displayed receive/DMA waveform.

The processor handles software control while the security peripherals encrypt data, authenticate protected frames, reject stale freshness values, screen trusted traffic, and move accepted records into memory. The CAN-FD block operates at the complete-frame boundary; an external CAN-FD protocol core and transceiver are still required for a physical bus.

## Start here

```powershell
git clone https://github.com/Varadain/riscv-aes-canfd-secoc.git
cd riscv-aes-canfd-secoc
python scripts/validate_evidence.py
python scripts/check_artifact_hashes.py
```

These checks need Python 3.9 or later and Git. They validate the archived files, not new RTL behavior. Running the verification or FPGA flow also needs the separately licensed tools described below.

## Architecture and register map

The top module is `riscv_aes_advancements`. Its five-stage pipeline retains forwarding, load-use stalling, and branch flushing. MMIO connects the following peripherals:

| Base | Peripheral | Purpose |
| --- | --- | --- |
| `0x0300` | AES / AES-CTR | Encryption, key controls, counter-mode data path |
| `0x0400` | Sensor / SPI | Sensor registers and external SPI master interface |
| `0x0500` | UART | Serial output |
| `0x0600` | Interrupt controller | Pending/enable state; IDS bit 4 and SecOC bit 5 |
| `0x0700` | DMA-lite | Memory-to-memory record movement |
| `0x0800` | Activity counters | Sleep requests and activity observations |
| `0x0900` | CAN-IDS | Identifier/payload/timing rules and alert counters |
| `0x0A00` | CAN-FD / SecOC | Four-entry TX/RX FIFOs, CMAC, freshness, authenticated RX DMA |

The trusted receive path is CAN-FD/SecOC verification, followed by IDS screening and RX DMA. A rejected frame raises a security event but is not released to either IDS or DMA. The IDS examines the first eight payload bytes; the fixed CMAC profile authenticates all 64 payload bytes.

## Evidence and scope

The reported runs were recorded on 16 July 2026. Packaging on 3 October 2026 did not rerun simulation or synthesis. The original 33-source synthesis bundle has SHA-256 `9fc6ee8605a86637b84872689ffb0b2c9dbc4285f4f7121932f2b5d5bf461157`. The public RTL was extracted from that exact bundle except for the vendor-generated SPI core.

- Directed SoC checks: 161 passed, 0 failed.
- CAN-IDS UVM: seeds 1, 7, 19, 42, 99; 209 transactions each; 38/38 portable bins.
- CAN-FD/SecOC UVM: the same five seeds; 46 transactions each; 16/16 portable bins.
- FPGA: Cyclone V `5CGXFC7C7F23C8`, Quartus 23.1, 50 MHz target.
- Utilization: 22,261 ALMs, 22,113 registers; maximum frequency 56.91 MHz.
- Vectorless power: 582.88 mW, low confidence; not measured board power.

The CAN-FD security controller accepts frame-level transactions; it is not an ISO 11898 MAC/PHY. The fixed SecOC-style profile is not a complete AUTOSAR stack. IDS labels are generated verification labels, not a field-dataset accuracy evaluation. Questa Starter Edition used UVM components, seeded procedural stimulus, portable bin collectors, and concurrent assertions; native solver/covergroup closure is not claimed.

## Files

`evidence/verification` contains unmodified archived logs and per-seed CSV files. `evidence/quartus` contains map, fit, timing, and power reports. `evidence/canfd_dma_debug.vcd` is the recorded waveform source. `cadence/uvm_can_ids` and `cadence/uvm_canfd_secoc` retain the original verification-script directory layout; that directory name does not indicate ASIC implementation evidence.

`SHA256SUMS.json` records the packaged file hashes. `scripts/validate_evidence.py` checks CSV aggregates against the raw UVM logs and FPGA summaries without running a simulator:

```powershell
python scripts/validate_evidence.py
```

## Focused verification

Use Questa Intel FPGA Starter Edition 2023.3 or a compatible licensed Questa installation. The recorded logs use UVM 1.1d. Install your own simulator and libraries; none are distributed here. Add its binaries to PATH. CAN-FD/SecOC also needs an x64 C compiler and Questa's `svdpi.h`; the original Windows runner uses the `python-zig` executable from the author's Python 3.12 Scripts installation. Adapt that compiler location for your system.

```powershell
foreach ($seed in 1,7,19,42,99) {
  & ./cadence/uvm_can_ids/run_can_ids_uvm_questa.ps1 -Seed $seed -RandomTransactions 200
  & ./cadence/uvm_canfd_secoc/run_canfd_secoc_uvm_questa.ps1 -Seed $seed -RandomTransactions 40
}
```

The scripts create/delete only their generated simulation work libraries in the project tree. Inspect their paths before use. `-NativeCovergroups` is optional and requires a suitable licence; it was not used for the reported evidence. Keep new run outputs separate from the archived `evidence` directory.

## Full SoC and FPGA reproduction

The vendor-generated `sensor_spi_ip` module is deliberately omitted. Its source carries Altera licence restrictions and must not be republished without authorization. Regenerate an Avalon SPI master using Quartus/Platform Designer under your vendor licence, with module name `sensor_spi_ip`: 50 MHz input, 1 MHz SPI, 8-bit data, one slave, CPOL 0, CPHA 0, MSB first, no extra delay. Preserve the original port interface expected by `sensor_spi_mmio.sv`; place the generated QIP at `ip/sensor_spi_ip/sensor_spi_ip.qip`.

The preserved QSF references this external QIP. After regeneration, run map, fit, assembler, STA and power with the `riscv_aes_advancements` revision. The SDC constrains the internal clock to 20 ns; it is not a board-ready constraint set. Exact pin assignments and external input/output delays must be added before hardware use. Regenerated vendor IP and tool versions can change fitted results, so report the new run rather than presenting the archived values as a guaranteed reproduction.

The SoC testbench is `riscv_core_tb.sv`. Compile the design sources from the QSF and the regenerated SPI model with `vlog -sv`, then run `work.riscv_core_tb` to completion. The monolithic restricted-IP bundle, commercial libraries, simulator binaries, FPGA bitstream, and ASIC files are not included.

## Visualization

`scripts/create_project_figures_original.py` preserves the original plotting implementation. Its original workspace-relative paths must be adapted to this public layout before rerunning; it is not presented as a portable command. It uses Python, Matplotlib, the recorded VCD, and the RTL hierarchy. Plot generation does not replace simulation or synthesis.

## Related work and publication

The AES architecture was reported in the GCON paper by Inamdar, Kulkarni, and Nanaware, DOI https://doi.org/10.1109/GCON69192.2026.11648274. The baseline processor paper by Inamdar and Kulkarni was accepted for ISAIA 2026, with presentation scheduled for 10 October 2026. This artifact package accompanies the additional CAN security integration and verification work; it must not be used to imply that the earlier AES or processor concepts are newly introduced.

The public artifact repository is https://github.com/Varadain/riscv-aes-canfd-secoc. `CITATION.cff` identifies this software artifact; it does not claim that the journal manuscript has been accepted or published. A permanent release or commit link can be cited in the manuscript. A DOI-backed archive may be added later; this repository does not currently have a DOI.

## Rights and excluded files

No open-source software licence is selected by this upload. Public visibility does not grant a licence to redistribute or reuse the implementation; the authors should agree on a licence before adding one. Existing third-party notices are retained.

The restricted vendor SPI source, commercial libraries, tool binaries, author photos, journal submission documents, publisher-formatted conference PDFs, bitstreams, build databases, and ASIC implementation files are excluded. The original restricted-IP synthesis bundle is identified only by its SHA-256, not redistributed.
