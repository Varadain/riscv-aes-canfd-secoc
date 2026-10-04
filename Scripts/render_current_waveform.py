import argparse
import hashlib
import json
from pathlib import Path

import matplotlib.pyplot as plt


PREFIX = "riscv_core_tb.u_canfd_soc_eval"
SIGNALS = {
    "SecOC active": PREFIX + ".u_canfd_secoc_mmio.active_o",
    "MAC accepted": PREFIX + ".u_canfd_secoc_mmio.last_auth_ok_reg",
    "Freshness accepted": PREFIX + ".u_canfd_secoc_mmio.last_fresh_ok_reg",
    "RX accepted count > 0": PREFIX + ".u_canfd_secoc_mmio.rx_accept_count_reg",
    "Trusted IDS submit": PREFIX + ".u_canfd_secoc_mmio.ids_submit_o",
    "RX DMA request": PREFIX + ".u_canfd_secoc_mmio.dma_req_o",
    "RX DMA write": PREFIX + ".u_canfd_secoc_mmio.dma_write_en_o",
    "Memory write": PREFIX + ".ram_dma_write_en",
    "IDS active": PREFIX + ".can_ids_active",
}


def read_signals(path):
    scope, codes, events = [], {}, {label: [] for label in SIGNALS}
    now, header, scale, date, date_lines = 0, True, False, False, []
    with path.open(encoding="utf-8", errors="strict") as stream:
        for raw in stream:
            line = raw.strip()
            if header:
                if date and line != "$end":
                    date_lines.append(line)
                if line == "$date":
                    date = True
                elif date and line == "$end":
                    date = False
                if line == "1ps":
                    scale = True
                if line.startswith("$scope "):
                    scope.append(line.split()[2])
                elif line.startswith("$upscope"):
                    scope.pop()
                elif line.startswith("$var "):
                    fields = line.split()
                    full_name = ".".join(scope + [fields[4]])
                    for label, wanted in SIGNALS.items():
                        if full_name == wanted:
                            if fields[2] != "1" and label != "RX accepted count > 0":
                                raise ValueError(f"Expected scalar signal: {wanted}")
                            codes.setdefault(fields[3], []).append(label)
                elif line.startswith("$enddefinitions"):
                    header = False
                continue
            if line.startswith("#"):
                now = int(line[1:])
            elif line and line[0] in "01xXzZ":
                for label in codes.get(line[1:], []):
                    events[label].append((now, line[0].lower()))
            elif line.startswith("b"):
                bits, code = line[1:].split()
                for label in codes.get(code, []):
                    value = "x" if any(c in bits.lower() for c in "xz") else str(int(int(bits, 2) > 0))
                    events[label].append((now, value))
    if not scale or any(not points for points in events.values()):
        raise ValueError("Missing signal transitions or unsupported VCD timescale")
    return events, " ".join(date_lines)


def first_high(points):
    return next(t for t, value in points if value == "1")


def panel(ax, events, labels, start, end, title):
    for index, label in enumerate(labels):
        lane = len(labels) - index - 1
        points = events[label]
        initial = next((v for t, v in reversed(points) if t <= start), "x")
        window = [(start, initial)] + [(t, v) for t, v in points if start < t < end]
        window.append((end, window[-1][1]))
        xs = [(t - start) / 1_000_000 for t, _ in window]
        ys = [lane + 0.65 * int(v) if v in "01" else float("nan") for _, v in window]
        ax.step(xs, ys, where="post", linewidth=1.35, color="#215b82")
        ax.text(-0.035, lane + 0.27, label, transform=ax.get_yaxis_transform(),
                ha="right", va="center", fontsize=9)
    ax.set_xlim(0, (end - start) / 1_000_000)
    ax.set_ylim(-0.35, len(labels))
    ax.set_yticks([])
    ax.set_xlabel("Time from window start (us)", fontsize=9)
    ax.set_title(title, loc="left", fontsize=10, pad=10)
    ax.grid(axis="x", alpha=0.2)
    for side in ("top", "left", "right"):
        ax.spines[side].set_visible(False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("vcd", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    events, capture = read_signals(args.vcd)
    auth = first_high(events["RX accepted count > 0"])
    release = first_high(events["Trusted IDS submit"])
    if release < auth:
        raise ValueError("IDS release precedes the observed authentication result")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig, axes = plt.subplots(2, 1, figsize=(10.5, 5.6), gridspec_kw={"height_ratios": [4, 5]})
    panel(axes[0], events, list(SIGNALS)[:4], max(0, auth - 170_000), auth + 360_000,
          f"(a) SecOC status and RX acceptance near {auth / 1_000_000:.3f} us")
    panel(axes[1], events, list(SIGNALS)[4:], max(0, release - 125_000), release + 480_000,
          f"(b) IDS release and DMA handoff near {release / 1_000_000:.3f} us")
    fig.subplots_adjust(left=0.22, right=0.985, bottom=0.095, top=0.92, hspace=0.75)
    fig.savefig(args.output.with_suffix(".pdf"))
    fig.savefig(args.output.with_suffix(".png"), dpi=300)
    plt.close(fig)
    record = {"capture_date": capture, "vcd_sha256": hashlib.sha256(args.vcd.read_bytes()).hexdigest(),
              "signals": SIGNALS, "rx_acceptance_time_ps": auth, "release_time_ps": release,
              "simulation_clock_period_ns": 10, "post_fit_timing_simulation": False}
    args.output.with_suffix(".json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
