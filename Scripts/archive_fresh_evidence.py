import csv
import hashlib
import json
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Evidence" / "2026-10-03"
PROJECT = "riscv_aes_advancements"


def read(path):
    raw = path.read_bytes()
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        # Windows Quartus reports contain CP1252 degree symbols.
        return raw.decode("cp1252")


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def values(path):
    result = {}
    for line in read(path).splitlines():
        if " : " in line:
            key, value = line.split(" : ", 1)
            result[key.strip()] = value.strip()
    return result


def count(value):
    return int(re.search(r"[\d,]+", value)[0].replace(",", ""))


def main():
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    assert commit == "e31227ddf8db7af6dcc089848dd589938981cbe0", commit
    changed = subprocess.check_output(["git", "diff", "--name-only", "HEAD", "--", "RTL", "UVM", "Testbench", "FPGA"], cwd=ROOT, text=True)
    if changed.strip():
        raise ValueError(f"Experimental inputs changed: {changed}")
    fit = values(ROOT / f"Build/Quartus/{PROJECT}.fit.summary")
    power = values(ROOT / f"Build/Quartus/{PROJECT}.pow.summary")
    assert "Successful" in fit["Fitter Status"] and "Oct" in fit["Fitter Status"]
    assert "Successful" in power["Power Analyzer Status"] and "Oct" in power["Power Analyzer Status"]
    assert fit["Device"] == "5CGXFC7C7F23C8"
    flow = {}
    for stage, tool_name in (("map", "Analysis & Synthesis"), ("fit", "Fitter"), ("asm", "Assembler"), ("sta", "Timing Analyzer"), ("pow", "Power Analyzer")):
        log_path = ROOT / f"Build/QuartusRunLogs/quartus_{stage}.log"
        log = read(log_path)
        result = re.search(r"was successful\. (\d+) errors?, (\d+) warnings?", log)
        assert result and result[1] == "0", log_path
        flow[stage] = {"errors": int(result[1]), "warnings": int(result[2]), "tool": tool_name}
        copy(log_path, OUT / "Logs" / log_path.name)
    for path in (ROOT / "Build/Quartus").iterdir():
        if path.suffix in (".summary", ".rpt"):
            copy(path, OUT / "Quartus" / path.name)
    uvm = {}
    for name, folder, csv_name, assertions, bins in (
        ("CAN_IDS", "20261003_CAN_IDS", "can_ids_uvm_randomized_regression.csv", 4, 38),
        ("CANFD_SecOC", "20261003_CANFD_SecOC", "canfd_secoc_uvm_regression.csv", 5, 16),
    ):
        directory = ROOT / "Build/Regressions" / folder
        with (directory / csv_name).open(encoding="utf-8-sig", newline="") as stream:
            rows = list(csv.DictReader(stream))
        assert [int(r["Seed"]) for r in rows] == [1, 7, 19, 42, 99]
        for row in rows:
            log_path = directory / row["Log"]
            text = read(log_path)
            assert re.search(r"UVM_ERROR\s*:\s*0\b", text), log_path
            assert re.search(r"UVM_FATAL\s*:\s*0\b", text), log_path
            assert f"Concurrent assertions={assertions} failures=0" in text, log_path
            assert f"100.00% ({bins}/{bins} bins)" in text, log_path
            assert re.search(r"mismatches=0|scoreboard mismatches=0", text), log_path
            copy(log_path, OUT / "Verification" / name / log_path.name)
        for filename in (csv_name, "SUMMARY.txt"):
            copy(directory / filename, OUT / "Verification" / name / filename)
        total_fields = ("Total", "Randomized", "TP", "TN", "FP", "FN") if name == "CAN_IDS" else ("Total", "Randomized", "Accepted", "AuthFail", "FreshFail", "Mismatches")
        uvm[name] = {field: sum(int(r[field]) for r in rows) for field in total_fields}
        uvm[name].update({"seeds": [1, 7, 19, 42, 99], "bins_per_seed": bins, "assertions": assertions, "assertion_failures": 0})
    processor = {}
    directory = ROOT / "Build/Questa/Processor"
    for mode, expected in (("All", 161), ("SecurityExtension", 36), ("CanFdSecoc", 17), ("FullSocScenario", 18)):
        path = directory / f"processor_{mode}.log"
        text = read(path)
        match = re.search(r"RV32I-style directed verification summary: PASS=(\d+) FAIL=(\d+)", text)
        assert match and int(match[1]) == expected and match[2] == "0", path
        assert not re.search(r"\*\* (?:Error|Fatal):|UI-Msg \(Error\)", text), path
        processor[mode] = {"pass": int(match[1]), "fail": int(match[2])}
        copy(path, OUT / "Verification/Processor" / path.name)
    copy(directory / "compile.log", OUT / "Verification/Processor/compile.log")
    with (OUT / "Verification/Processor/processor_regression.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=("Mode", "Pass", "Fail"))
        writer.writeheader()
        writer.writerows({"Mode": mode, "Pass": result["pass"], "Fail": result["fail"]} for mode, result in processor.items())
    copy(directory / "canfd_dma_debug.vcd", OUT / "Waveforms/canfd_dma_debug.vcd")
    sta = read(ROOT / f"Build/Quartus/{PROJECT}.sta.summary")
    timing = [{"check": m[1].strip(), "slack_ns": float(m[2]), "tns_ns": float(m[3])}
              for m in re.finditer(r"Type\s*:\s*([^\n]+)\s+Slack\s*:\s*([-\d.]+)\s+TNS\s*:\s*([-\d.]+)", sta)]
    assert len(timing) == 12 and all(t["slack_ns"] > 0 and t["tns_ns"] == 0 for t in timing)
    sta_report = read(ROOT / f"Build/Quartus/{PROJECT}.sta.rpt")
    fmax = float(re.search(r";\s*([\d.]+) MHz\s*;\s*[\d.]+ MHz\s*;\s*clk\s*;", sta_report)[1])
    fit_report = read(ROOT / f"Build/Quartus/{PROJECT}.fit.rpt")
    hierarchy = {}
    for line in fit_report.splitlines():
        fields = [field.strip() for field in line.split(";")[1:-1]]
        if len(fields) == 17 and fields[15] in ("riscv_aes_advancements", "data_mem", "canfd_secoc_mmio", "aes_mmio", "can_ids_mmio"):
            hierarchy[fields[15]] = {"alms": float(fields[1].split()[0]), "registers": int(fields[7].split()[0])}
    assert len(hierarchy) == 5, hierarchy
    quartus = {"version": fit["Quartus Prime Version"], "device": fit["Device"], "family": fit["Family"],
               "alms": count(fit["Logic utilization (in ALMs)"]), "registers": count(fit["Total registers"]),
               "pins": count(fit["Total pins"]), "fmax_mhz": fmax, "target_mhz": 50,
               "timing": timing, "hierarchy": hierarchy, "flow": flow,
               "thermal_mw": float(power["Total Thermal Power Dissipation"].split()[0]),
               "dynamic_mw": float(power["Core Dynamic Thermal Power Dissipation"].split()[0]),
               "static_mw": float(power["Core Static Thermal Power Dissipation"].split()[0]),
               "io_mw": float(power["I/O Thermal Power Dissipation"].split()[0]),
               "power_confidence": power["Power Estimation Confidence"], "activity_file_supplied": False}
    summary = {"source_release": "v1.1.0", "source_commit": commit, "run_date": "2026-10-03",
               "archived_at_utc": datetime.now(timezone.utc).isoformat(), "questa_version": "2023.3", "uvm_library": "1.1d",
               "native_covergroups": False, "class_constraint_solver": False, "uvm": uvm, "processor": processor, "quartus": quartus}
    inputs = [p for folder in ("RTL", "UVM", "Testbench", "FPGA/Quartus", "Scripts") for p in (ROOT / folder).rglob("*")
              if p.is_file() and p.suffix in (".sv", ".c", ".ps1", ".sdc", ".qsf", ".qpf", ".py")]
    # Vendor files remain local; only dependency hashes and configuration are archived.
    inputs.extend(p for p in (ROOT / "IP/sensor_spi_ip").iterdir() if p.is_file())
    provenance = {"source_commit": commit, "tracked_experimental_inputs_unchanged": True,
                  "local_only_vendor_spi": {"module": "sensor_spi_ip", "input_hz": 50000000, "spi_hz": 1000000,
                                            "word_bits": 8, "slaves": 1, "cpol": 0, "cpha": 0, "msb_first": True},
                  "input_sha256": {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(inputs)}}
    for filename, content in (("RUN_SUMMARY.json", summary), ("PROVENANCE.json", provenance)):
        (OUT / filename).write_text(json.dumps(content, indent=2) + "\n", encoding="utf-8")
    hashes = {p.relative_to(OUT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(OUT.rglob("*")) if p.is_file() and p.name != "SHA256SUMS.json"}
    (OUT / "SHA256SUMS.json").write_text(json.dumps(hashes, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
