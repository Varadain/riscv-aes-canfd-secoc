from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, Rectangle


ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / "journal_report_can_ids"
FIGDIR = REPORT / "figures" / "generated"
VCD_PATH = ROOT / "canfd_dma_debug.vcd"
BUNDLE_PATH = ROOT / "cadence" / "genus_portable" / "riscv_aes_cadence_synthesis_all.sv"


SIGNALS = {
    "!": "ram_dma_write_en",
    '"': "ram_dma_write_addr",
    "#": "ram_dma_write_data",
    "%": "canfd_dma_write_en",
    "?-!": "canfd_sel",
    "O-!": "canfd_write_en",
    "P-!": "canfd_read_en",
    "k-!": "canfd_secoc_irq",
    "l-!": "canfd_active",
    "m-!": "canfd_ids_submit",
    "n-!": "canfd_ids_frame_id",
    "o-!": "canfd_ids_frame_dlc",
    "p-!": "canfd_ids_frame_payload",
    "q-!": "canfd_ids_frame_fd",
    "x-!": "canfd_dma_req",
    "y-!": "canfd_dma_write_addr",
    "z-!": "canfd_dma_write_data",
    ";F!": "secoc_irq_o",
    "<F!": "secoc_active_o",
    "=F!": "ids_submit_o",
    ">F!": "ids_frame_id_o",
    "?F!": "ids_frame_dlc_o",
    "@F!": "ids_frame_payload_o",
    "AF!": "ids_frame_fd_o",
    "BF!": "secoc_dma_req",
    "DF!": "secoc_dma_write_addr",
    "EF!": "secoc_dma_write_data",
    "FF!": "secoc_dma_write_en",
    "oF!": "last_auth_ok",
    "pF!": "last_fresh_ok",
    "qF!": "rx_accept_count",
    "=Y!": "can_ids_active",
    ";Y!": "can_ids_alert_irq",
}


def parse_vcd(path, codes):
    events = {code: [] for code in codes}
    now = 0
    in_header = True
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if in_header:
                if line.startswith("$enddefinitions"):
                    in_header = False
                continue
            if line.startswith("#"):
                try:
                    now = int(line[1:])
                except ValueError:
                    continue
                continue
            tag = line[0]
            if tag in "01xXzZ":
                code = line[1:]
                if code in events:
                    events[code].append((now, tag.lower()))
                continue
            if tag in "bB":
                parts = line.split()
                if len(parts) >= 2:
                    code = parts[1]
                    if code in events:
                        events[code].append((now, parts[0][1:].lower()))
    return events


def is_high(value):
    return value == "1"


def value_at(points, time_ps, default="0"):
    value = default
    for t, v in points:
        if t > time_ps:
            break
        value = v
    return value


def digital_points(points, start_ps, end_ps):
    start_value = value_at(points, start_ps)
    xs = [start_ps]
    ys = [1 if is_high(start_value) else 0]
    for t, value in points:
        if start_ps <= t <= end_ps:
            xs.append(t)
            ys.append(1 if is_high(value) else 0)
    xs.append(end_ps)
    ys.append(ys[-1])
    return xs, ys


def bus_int(value):
    if not value or any(ch in value for ch in "xz"):
        return None
    return int(value, 2)


def first_high(events, code):
    for t, value in events.get(code, []):
        if is_high(value):
            return t
    return None


def first_low_after(events, code, start_ps):
    for t, value in events.get(code, []):
        if t > start_ps and value == "0":
            return t
    return None


def first_nonzero_bus(events, code, start_ps, end_ps):
    for t, value in events.get(code, []):
        if start_ps <= t <= end_ps:
            as_int = bus_int(value)
            if as_int:
                return t, as_int
    return None


def plot_digital_panel(ax, events, lane_defs, start_ps, end_ps, title):
    amplitude = 0.65
    for idx, (label, code) in enumerate(lane_defs):
        ybase = len(lane_defs) - idx - 1
        xs, ys = digital_points(events.get(code, []), start_ps, end_ps)
        xs_us = [(x - start_ps) / 1_000_000 for x in xs]
        ys_lane = [ybase + amplitude * y for y in ys]
        ax.step(xs_us, ys_lane, where="post", color="#1f4e79", linewidth=1.4)
        ax.hlines(ybase, 0, (end_ps - start_ps) / 1_000_000, color="#d7dce2", linewidth=0.6)
        ax.text(-0.04, ybase + amplitude * 0.34, label, ha="right", va="center", fontsize=8.5)

    ax.set_xlim(0, (end_ps - start_ps) / 1_000_000)
    ax.set_ylim(-0.5, len(lane_defs) - 0.05)
    ax.set_xlabel("Time from window start (us)")
    ax.set_yticks([])
    ax.set_title(title, fontsize=10.5, loc="left")
    ax.grid(axis="x", color="#eceff4", linewidth=0.8)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)


def generate_waveform():
    events = parse_vcd(VCD_PATH, SIGNALS.keys())
    auth_time = first_high(events, "oF!") or first_high(events, "pF!") or 0
    release_time = first_high(events, "=F!") or first_high(events, "FF!") or auth_time

    auth_start = max(0, auth_time - 170_000)
    auth_end = auth_time + 360_000
    release_start = max(0, release_time - 125_000)
    release_end = release_time + 480_000

    auth_lanes = [
        ("CAN-FD/SecOC active", "<F!"),
        ("SecOC IRQ", ";F!"),
        ("AES-CMAC auth OK", "oF!"),
        ("Freshness OK", "pF!"),
    ]
    release_lanes = [
        ("CAN-FD page selected", "?-!"),
        ("CAN-FD MMIO write", "O-!"),
        ("CAN-FD MMIO read", "P-!"),
        ("Authenticated IDS submit", "=F!"),
        ("Frame is CAN-FD", "AF!"),
        ("CAN-FD DMA request", "BF!"),
        ("CAN-FD DMA write", "FF!"),
        ("RAM write enable", "!"),
        ("CAN-IDS active", "=Y!"),
        ("CAN-IDS alert IRQ", ";Y!"),
    ]

    fig, (ax0, ax1) = plt.subplots(2, 1, figsize=(11.0, 6.2), gridspec_kw={"height_ratios": [1.0, 1.55]})
    plot_digital_panel(
        ax0,
        events,
        auth_lanes,
        auth_start,
        auth_end,
        f"(a) SecOC authentication and freshness result around {auth_time / 1_000_000:.3f} us",
    )
    plot_digital_panel(
        ax1,
        events,
        release_lanes,
        release_start,
        release_end,
        f"(b) Authenticated IDS release and RX DMA handoff around {release_time / 1_000_000:.3f} us",
    )

    id_value = bus_int(value_at(events[">F!"], release_time))
    dlc_value = bus_int(value_at(events["?F!"], release_time))
    accept_count = bus_int(value_at(events["qF!"], release_time))
    dma_low_time = first_low_after(events, "FF!", release_time) or release_end
    dma_addrs = [
        bus_int(v)
        for t, v in events["DF!"]
        if release_time <= t < dma_low_time and bus_int(v) is not None
    ]
    dma_data = first_nonzero_bus(events, "EF!", release_time, dma_low_time)

    notes = []
    if id_value is not None and dlc_value is not None:
        notes.append(f"IDS-visible frame: ID=0x{id_value:03X}, DLC={dlc_value}")
    if accept_count is not None:
        notes.append(f"RX accept count={accept_count}")
    if dma_addrs:
        notes.append(f"DMA addresses 0x{min(dma_addrs):08X} to 0x{max(dma_addrs):08X}")
    if dma_data is not None:
        notes.append(f"first nonzero DMA word=0x{dma_data[1]:08X}")

    fig.suptitle(
        "Questa VCD evidence: authenticated CAN-FD/SecOC frame release, IDS screening, and RX DMA",
        fontsize=12.0,
        y=0.985,
    )
    fig.text(
        0.02,
        0.012,
        " | ".join(notes),
        ha="left",
        va="bottom",
        fontsize=9,
        color="#243447",
    )
    fig.tight_layout()
    fig.subplots_adjust(top=0.90, bottom=0.10, hspace=0.42)
    fig.savefig(FIGDIR / "questa_canfd_secoc_dma_waveform.pdf")
    fig.savefig(FIGDIR / "questa_canfd_secoc_dma_waveform.png", dpi=300)
    plt.close(fig)


def add_box(ax, xy, wh, title, subtitle="", face="#f5f8fb", edge="#334e68"):
    x, y = xy
    w, h = wh
    box = Rectangle((x, y), w, h, linewidth=1.1, edgecolor=edge, facecolor=face)
    ax.add_patch(box)
    ax.text(x + w / 2, y + h * 0.60, title, ha="center", va="center", fontsize=9.0, weight="bold")
    if subtitle:
        ax.text(x + w / 2, y + h * 0.30, subtitle, ha="center", va="center", fontsize=7.5)


def add_arrow(ax, start, end, label="", color="#334e68", label_offset=0.08, connectionstyle=None):
    arrow = FancyArrowPatch(
        start,
        end,
        arrowstyle="-|>",
        mutation_scale=10,
        linewidth=1.0,
        color=color,
        connectionstyle=connectionstyle,
    )
    ax.add_patch(arrow)
    if label:
        mx = (start[0] + end[0]) / 2
        my = (start[1] + end[1]) / 2
        ax.text(
            mx,
            my + label_offset,
            label,
            ha="center",
            va="bottom",
            fontsize=7.2,
            color=color,
            bbox={"facecolor": "white", "edgecolor": "none", "pad": 0.7, "alpha": 0.92},
        )


def generate_hierarchy():
    required_modules = [
        "riscv_aes_advancements",
        "if_stage",
        "id_stage",
        "ex_stage",
        "mem_stage",
        "wb_stage",
        "aes_mmio",
        "canfd_secoc_mmio",
        "can_ids_mmio",
        "dma_lite",
        "uart_mmio",
        "sensor_spi_mmio",
        "simple_intc",
        "power_mgmt_mmio",
    ]
    text = BUNDLE_PATH.read_text(encoding="utf-8", errors="replace")
    missing = [name for name in required_modules if f"module {name}" not in text]
    if missing:
        raise RuntimeError(f"Missing expected module(s) in synthesis bundle: {missing}")

    fig, ax = plt.subplots(figsize=(11.0, 6.2))
    ax.set_xlim(0, 10)
    ax.set_ylim(0, 7)
    ax.axis("off")

    ax.text(0.5, 6.55, "Current RTL Integration Overview", fontsize=12.0, weight="bold", color="#243447")
    add_box(ax, (0.55, 5.82), (8.9, 0.44), "riscv_aes_advancements", "top-level processor subsystem")

    pipeline = [
        (0.60, "IF", "fetch"),
        (2.15, "ID", "decode"),
        (3.70, "EX", "execute"),
        (5.25, "MEM", "MMIO decode"),
        (6.95, "WB", "write-back"),
    ]
    for x, title, subtitle in pipeline:
        add_box(ax, (x, 4.95), (1.15, 0.55), title, subtitle)
    for start, end in [(1.75, 2.15), (3.30, 3.70), (4.85, 5.25), (6.40, 6.95)]:
        add_arrow(ax, (start, 5.225), (end, 5.225), "")

    ax.text(0.55, 4.25, "MMIO address map", fontsize=9.0, weight="bold", color="#334e68")
    tiles = [
        (0.55, 3.45, "AES MMIO", "0x0300", "ECB/CTR"),
        (2.15, 3.45, "Sensor/SPI", "0x0400", "sensor path"),
        (3.75, 3.45, "UART", "0x0500", "serial output"),
        (5.35, 3.45, "Interrupt Ctrl", "0x0600", "IRQ bits 4, 5"),
        (0.55, 2.60, "DMA-lite", "0x0700", "record copy"),
        (2.15, 2.60, "Power counters", "0x0800", "activity counts"),
        (3.75, 2.60, "CAN-IDS", "0x0900", "rule classifier"),
        (5.35, 2.60, "CAN-FD/SecOC", "0x0A00", "FIFO, CMAC"),
        (6.95, 2.60, "Data memory", "data", "records"),
    ]
    for x, y, title, address, detail in tiles:
        add_box(ax, (x, y), (1.35, 0.58), title, f"{address} | {detail}", face="#f9fbf7", edge="#516b3a")

    ax.text(0.55, 1.78, "Authenticated receive path", fontsize=9.0, weight="bold", color="#334e68")
    path_boxes = [
        (0.55, "1", "CAN-FD/SecOC", "MAC + freshness"),
        (3.00, "2", "CAN-IDS", "trusted features"),
        (5.05, "3", "DMA + memory", "accepted record"),
        (7.15, "4", "Interrupts", "SecOC / IDS flags"),
    ]
    for x, step, title, detail in path_boxes:
        add_box(ax, (x, 0.92), (1.65, 0.62), f"{step}. {title}", detail, face="#fffaf2", edge="#8a5a25")
    for start, end, label in [
        ((2.20, 1.23), (3.00, 1.23), "release"),
        ((4.65, 1.23), (5.05, 1.23), "write"),
        ((6.70, 1.23), (7.15, 1.23), "notify"),
    ]:
        add_arrow(ax, start, end, label, label_offset=0.05, color="#8a5a25")

    ax.text(
        0.6,
        0.35,
        "Project-generated from current RTL module names and MMIO map. External CAN-FD MAC/PHY is outside this integration view.",
        fontsize=8.4,
        color="#334e68",
    )
    fig.tight_layout()
    fig.savefig(FIGDIR / "current_rtl_security_hierarchy.pdf")
    fig.savefig(FIGDIR / "current_rtl_security_hierarchy.png", dpi=300)
    plt.close(fig)


def main():
    FIGDIR.mkdir(parents=True, exist_ok=True)
    generate_waveform()
    generate_hierarchy()
    print(f"Generated figures in {FIGDIR}")


if __name__ == "__main__":
    main()
