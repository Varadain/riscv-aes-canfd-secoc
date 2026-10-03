# Reproduction steps

## Integrity and recorded evidence

From the repository root, with Python 3.9 or later and Git:

```powershell
python Scripts/validate_evidence.py
python Scripts/check_artifact_hashes.py
```

The evidence checker reads the archived CSV/log/report files. The hash checker verifies version-controlled artifact bytes. Neither command invokes an EDA tool. Regenerate the manifest with `--write` only after an intentional repository update.

## Focused UVM tests

Install your own Questa libraries and binaries, and add the binaries to PATH. The recorded configuration uses Questa Intel FPGA Starter Edition 2023.3 and UVM 1.1d. The runners also check the conventional Intel Questa installation path.

```powershell
& ./UVM/CAN_IDS/run_can_ids_uvm_questa.ps1 -Seed 1 -RandomTransactions 200
& ./UVM/CANFD_SecOC/run_canfd_secoc_uvm_questa.ps1 -Seed 1 -RandomTransactions 40
```

For the original five-seed configurations:

```powershell
& ./UVM/CAN_IDS/run_can_ids_uvm_regression.ps1
& ./UVM/CANFD_SecOC/run_canfd_secoc_uvm_regression.ps1
```

Logs, work libraries, and the DPI library are generated under `Build/Questa/CAN_IDS/` and `Build/Questa/CANFD_SecOC/`. Regression summaries go into timestamped `Build/Regressions/` folders. The runners delete only their own generated work-library directories after checking the resolved build boundary.

CAN-FD/SecOC needs an x64 C compiler and Questa's `svdpi.h`. The preserved compiler choice is `python-zig.exe` under the user's Python 3.12 Scripts installation; adapt that compiler location for another system. The C-DPI source is `UVM/CANFD_SecOC/secoc_cmac_ref.c`; it includes the shared AES implementation from `UVM/ReferenceModels/aes_ctr_ref.c`.

Use `-DumpVcd` for optional waveform capture. `-NativeCovergroups` needs a suitable simulator licence and was not used for the archived evidence. Do not describe the portable bin summaries as native UCDB closure.

## Full SoC and FPGA

The licensed `sensor_spi_ip` module is not distributed. Regenerate an Avalon SPI master in Quartus/Platform Designer: module name `sensor_spi_ip`, 50 MHz input, 1 MHz SPI, 8-bit words, one slave, CPOL 0, CPHA 0, MSB first, and no extra delay. Preserve the port interface expected by `RTL/Peripherals/sensor_spi_mmio.sv`. Place its QIP at `IP/sensor_spi_ip/sensor_spi_ip.qip`.

Open `FPGA/Quartus/riscv_aes_advancements.qpf` or run from its directory:

```powershell
Push-Location FPGA/Quartus
try {
  foreach ($tool in 'quartus_map','quartus_fit','quartus_asm','quartus_sta','quartus_pow') {
    & $tool riscv_aes_advancements
    if ($LASTEXITCODE -ne 0) { throw "$tool failed; check its reports" }
  }
}
finally {
  Pop-Location
}
```

The QSF retains the original source order and target device; only repository paths and generated-output placement were changed. FPGA outputs go into `Build/Quartus/`. The SDC constrains the internal clock to 20 ns, not a complete board interface. Add physical pins and external delays before hardware validation.

The directed testbench is `Testbench/riscv_core_tb.sv`. Compile the design files listed in the QSF and the regenerated SPI model with `vlog -sv`, then run `work.riscv_core_tb`. Different tool versions or regenerated IP can change fitted results.

## Figures

`Scripts/create_project_figures.py` uses Python and Matplotlib. It reads `Evidence/Waveforms/canfd_dma_debug.vcd` and the public `RTL/` files, then writes waveform and hierarchy figures under `Build/Figures/`.

```powershell
python Scripts/create_project_figures.py
```

The waveform transitions come from the archived VCD; plotting does not create or replace experimental observations.
