import csv
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "evidence"


def rows(path):
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def read_text(path):
    raw = path.read_bytes()
    encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    return raw.decode(encoding, errors="replace")


def check_log(path, assertions, bins):
    text = read_text(path)
    assert re.search(r"UVM_ERROR\s*:\s*0\b", text), path
    assert re.search(r"UVM_FATAL\s*:\s*0\b", text), path
    assert f"Concurrent assertions={assertions} failures=0" in text, path
    assert f"100.00% ({bins}/{bins} bins)" in text, path
    assert re.search(r"mismatches=0|scoreboard mismatches=0", text), path
    return text


def main():
    ids_dir = EVIDENCE / "verification/can_ids_uvm"
    ids = rows(ids_dir / "can_ids_uvm_randomized_regression.csv")
    secoc_dir = EVIDENCE / "verification/canfd_secoc_uvm"
    secoc = rows(secoc_dir / "canfd_secoc_uvm_regression.csv")
    assert [int(r["Seed"]) for r in ids] == [1, 7, 19, 42, 99]
    assert [int(r["Seed"]) for r in secoc] == [1, 7, 19, 42, 99]
    assert sum(int(r["Total"]) for r in ids) == 1045
    assert sum(int(r["TP"]) for r in ids) == 740
    assert sum(int(r["TN"]) for r in ids) == 305
    for r in ids:
        assert (int(r["Total"]), int(r["Randomized"]), int(r["CoveredBins"])) == (209, 200, 38)
        assert int(r["FP"]) == int(r["FN"]) == int(r["AssertionFailures"]) == 0
        text = check_log(ids_dir / r["Log"], 4, 38)
        for field in ("TP", "TN", "FP", "FN"):
            assert f'{field}={r[field]}' in text
    for field, expected in (("Total", 230), ("Randomized", 200), ("Accepted", 117), ("AuthFail", 56), ("FreshFail", 57)):
        assert sum(int(r[field]) for r in secoc) == expected
    for r in secoc:
        assert int(r["Mismatches"]) == int(r["AssertionFailures"]) == 0
        text = check_log(secoc_dir / r["Log"], 5, 16)
        for field, tag in (("Total", "transactions"), ("Accepted", "accepted"), ("AuthFail", "auth_fail"), ("FreshFail", "fresh_fail")):
            assert f'{tag}={r[field]}' in text
    full = read_text(EVIDENCE / "verification/questa_full_transcript.log")
    assert "PASS=161 FAIL=0" in full
    fit = read_text(EVIDENCE / "quartus/riscv_aes_advancements.fit.summary")
    assert "22,261" in fit and re.search(r"Total registers\s*:\s*22,?113\b", fit)
    power = read_text(EVIDENCE / "quartus/riscv_aes_advancements.pow.summary")
    assert "582.88" in power and "Low" in power
    timing = read_text(EVIDENCE / "quartus/riscv_aes_advancements.sta.summary")
    assert "2.429" in timing and "0.144" in timing
    timing_report = read_text(EVIDENCE / "quartus/riscv_aes_advancements.sta.rpt")
    assert "56.91" in timing_report
    print("PASS: all ten archived UVM logs agree with the CSV aggregates; FPGA summaries agree with the manuscript.")
    print("This is an artifact consistency check, not a new simulation or synthesis run.")


if __name__ == "__main__":
    main()
