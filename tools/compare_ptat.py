"""Compare a PTAT CSV log with a TPTS log recorded at the same time on the same device.

Usage: python tools/compare_ptat.py <ptat.csv> <tpts.csv> [--offset SEC] [--max-lag SEC] [--out pairs.csv]

TPTS input may be a dashboard export (tpts_telemetry_*.csv), a stress log (msr_log_*.csv),
or a Live Monitor device log (monitor_log_*.csv).
Clocks are aligned by a coarse quarter-hour timezone search, then a fine lag search that
maximizes Package Power correlation. --offset (PTAT clock minus TPTS clock, seconds) skips the coarse step.
"""
import argparse
import bisect
import csv
import math
import re
import sys
from datetime import datetime, timezone

REASON_BITS = [
    (0, "PROCHOT"), (1, "THERMAL"), (4, "RSR_LIMIT"), (5, "RATL"), (6, "VR_THERMALERT"), (7, "VR_TDC"),
    (8, "OTHER"), (10, "PBM_PL1"), (11, "PBM_PL2"), (12, "MAX_TURBO_LIMIT"), (13, "TURBO_ATTEN"),
]
REASON_NAMES = {name for _, name in REASON_BITS}

# (label, TPTS key, PTAT column)
NUMERIC = [
    ("Package Power (W)", "pkg", "Power-Package Power(Watts)"),
    ("IA Power (W)", "ia", "Power-IA Power(Watts)"),
    ("GT Power (W)", "gt", "Power-GT Power(Watts)"),
    ("Rest of Package (W)", "rest", "Power-Rest of Package Power(Watts)"),
    ("Package Temp (C)", "temp", "Miscellaneous-MSR Package Temperature(Degree C)"),
    ("CPU0 Eff Freq (MHz)", "freq", "CPU0-Effective Frequency (UCC/UCR)(MHz)"),
    ("PL1 (W)", "pl1", "Turbo Parameters-MSR Power Limit_1 Power(Watts)"),
    ("PL2 (W)", "pl2", "Turbo Parameters-MSR Power Limit_2 Power(Watts)"),
] + [(f"CPU{c} Eff Freq (MHz)", f"eff{c}", f"CPU{c}-Effective Frequency (UCC/UCR)(MHz)") for c in range(1, 64)]
PTAT_REASON_COLUMN = "Turbo Parameters-IA Clip Reason MSR"


def num(value):
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) else None


def epoch(dt):
    return dt.replace(tzinfo=timezone.utc).timestamp() if dt.tzinfo is None else dt.timestamp()


def decode_reasons(raw):
    value = int(raw, 16) if raw and raw.startswith("0x") else None
    if value is None:
        return None
    return {name for bit, name in REASON_BITS if value >> bit & 1}


def parse_reason_text(text):
    if text is None:
        return None
    return {token for token in re.findall(r"[A-Z0-9_]+", text) if token in REASON_NAMES}


def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as handle:
        reader = csv.reader(handle)
        header = next(reader)
        index = {}
        for i, name in enumerate(header):
            index.setdefault(name.strip(), i)
        return index, list(reader)


def load_ptat(path):
    index, rows = read_csv(path)
    for required in ("Date", "Time"):
        if required not in index:
            sys.exit(f"{path}: missing PTAT column '{required}'")
    samples = []
    for row in rows:
        if len(row) <= index["Time"]:
            continue
        try:
            dt = datetime.strptime(f"{row[index['Date']]} {row[index['Time']]}", "%d/%m/%Y %H:%M:%S:%f")
        except ValueError:
            continue
        sample = {"t": epoch(dt)}
        for _, key, column in NUMERIC:
            sample[key] = num(row[index[column]]) if column in index and index[column] < len(row) else None
        if PTAT_REASON_COLUMN in index and index[PTAT_REASON_COLUMN] < len(row):
            sample["reasons"] = parse_reason_text(row[index[PTAT_REASON_COLUMN]])
        samples.append(sample)
    samples.sort(key=lambda s: s["t"])
    return samples


def rapl_watts(row, index, domain):
    def field(name):
        i = index.get(f"{domain}_{name}")
        return row[i] if i is not None and i < len(row) else ""

    if field("status") not in ("ok", "wrap"):
        return None
    before, after = num(field("energy_before")), num(field("energy_after"))
    t0, t1 = num(field("time_before_ms")), num(field("time_after_ms"))
    rng = num(field("range")) or 0
    if None in (before, after, t0, t1) or t1 <= t0:
        return None
    delta = after - before
    if delta < 0:
        delta += rng
    unit = field("unit")
    match = re.fullmatch(r"ticks_2\^-(\d+)", unit)
    uj = delta * 1e6 / (1 << int(match.group(1))) if match else delta
    return uj / (t1 - t0) / 1000


def load_tpts(path, power_unit):
    index, rows = read_csv(path)
    samples = []
    if "timestamp" in index:
        def col(row, name, scale=1.0):
            i = index.get(name)
            value = num(row[i]) if i is not None and i < len(row) else None
            return value * scale if value is not None else None

        def reasons(row, name):
            i = index.get(name)
            if i is None or i >= len(row):
                return None
            return {r for r in row[i].split(";") if r}

        for row in rows:
            try:
                dt = datetime.fromisoformat(row[index["timestamp"]].replace("Z", "+00:00"))
            except (ValueError, IndexError):
                continue
            samples.append({
                "t": epoch(dt), "pkg": col(row, "package_power_w"), "ia": col(row, "ia_power_w"),
                "gt": col(row, "gt_power_w"), "rest": col(row, "rest_of_package_power_w"),
                "temp": col(row, "temperature_c"), "freq": col(row, "cpu_freq_ghz", 1000.0),
                "pl1": None, "pl2": None,
                "reasons": reasons(row, "cpu_limit_reasons"), "reasons_1s": reasons(row, "cpu_limit_reasons_last_1s"),
            })
    elif "Timestamp" in index:
        def raw(row, name):
            i = index.get(name)
            return row[i].strip() if i is not None and i < len(row) else ""

        for row in rows:
            try:
                dt = datetime.strptime(raw(row, "Timestamp"), "%Y%m%d_%H%M%S")
            except ValueError:
                continue
            pkg, ia, gt = num(raw(row, "PKG_Power_W")), rapl_watts(row, index, "ia"), rapl_watts(row, index, "gt")
            rest = None
            if None not in (pkg, ia, gt):
                rest = max(pkg - ia - gt, 0.0)
            reg610 = raw(row, "MSR_0x610")
            pl1 = pl2 = None
            if reg610.startswith("0x") and int(reg610, 16):
                value = int(reg610, 16)
                pl1, pl2 = (value & 0x7FFF) * power_unit, (value >> 32 & 0x7FFF) * power_unit
            freq_khz = num(raw(row, "CPU_Freq_kHz"))
            per_core = {}
            for item in raw(row, "CPU_Eff_MHz_all").split(";"):
                cpu, _, mhz = item.partition(":")
                if cpu.isdigit() and cpu != "0":
                    per_core[f"eff{cpu}"] = num(mhz)
            samples.append({
                **per_core,
                "t": epoch(dt), "pkg": pkg, "ia": ia, "gt": gt, "rest": rest,
                "temp": num(raw(row, "SoC_Temp_C")), "freq": freq_khz / 1000 if freq_khz is not None else None,
                "pl1": pl1, "pl2": pl2,
                "reasons": decode_reasons(raw(row, "MSR_0x64F_all_cores")),
                "reasons_1s": decode_reasons(raw(row, "MSR_0x64F_active_last_1s")),
            })
    else:
        sys.exit(f"{path}: unrecognized TPTS log (expected 'timestamp' or 'Timestamp' column)")
    samples.sort(key=lambda s: s["t"])
    return samples


def pair(tpts, ptat, offset, tolerance):
    times = [s["t"] for s in ptat]
    pairs = []
    for sample in tpts:
        target = sample["t"] + offset
        i = bisect.bisect_left(times, target)
        best = min((j for j in (i - 1, i) if 0 <= j < len(times)), key=lambda j: abs(times[j] - target), default=None)
        if best is not None and abs(times[best] - target) <= tolerance:
            pairs.append((sample, ptat[best]))
    return pairs


def pearson(xs, ys):
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    if sxx == 0 or syy == 0:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / math.sqrt(sxx * syy)


def score(tpts, ptat, offset, tolerance):
    matched = [(a, b) for a, b in pair(tpts, ptat, offset, tolerance)
               if a["pkg"] is not None and b["pkg"] is not None]
    if len(matched) < 5:
        return None
    values = [(a["pkg"], b["pkg"]) for a, b in matched]
    r = pearson(*zip(*values))
    mae = sum(abs(x - y) for x, y in values) / len(values)
    gap = sum(abs(b["t"] - a["t"] - offset) for a, b in matched) / len(matched)
    # Correlation first; MAE covers flat idle traces; time gap centres lags that pair identical samples.
    return (round(r, 6) if r is not None else -1.0, round(-mae, 6), -gap, len(values))


def align(tpts, ptat, fixed_offset, max_lag, tolerance):
    if fixed_offset is not None:
        coarse = [fixed_offset]
    else:
        start, end = ptat[0]["t"], ptat[-1]["t"]
        coarse = []
        for quarter in range(-14 * 4, 14 * 4 + 1):
            offset = quarter * 900
            inside = sum(1 for s in tpts if start <= s["t"] + offset <= end)
            if inside >= max(5, len(tpts) * 0.3):
                coarse.append(offset)
        if not coarse:
            sys.exit("No time overlap found within +/-14 h. Check the files or pass --offset.")
    best = None
    steps = int(round(max_lag / 0.1))
    for base in coarse:
        for step in range(-steps, steps + 1):
            offset = base + step * 0.1
            result = score(tpts, ptat, offset, tolerance)
            if result and (best is None or result > best[0]):
                best = (result, offset)
    if best is None:
        sys.exit("Not enough overlapping Package Power samples to align the logs.")
    return best[1], best[0]


def percentile(values, q):
    ordered = sorted(values)
    pos = (len(ordered) - 1) * q
    low, high = math.floor(pos), math.ceil(pos)
    return ordered[low] + (ordered[high] - ordered[low]) * (pos - low)


def fmt(value, digits=3):
    return "-" if value is None else f"{value:.{digits}f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ptat")
    parser.add_argument("tpts")
    parser.add_argument("--offset", type=float, help="PTAT clock minus TPTS clock in seconds (skips timezone search)")
    parser.add_argument("--max-lag", type=float, default=5.0, help="fine lag search range in seconds (default 5)")
    parser.add_argument("--tolerance", type=float, default=0.5, help="max time gap for a sample pair in seconds")
    parser.add_argument("--power-unit", type=float, default=0.125, help="MSR 0x610 unit in W for stress logs (default 0.125)")
    parser.add_argument("--out", help="write aligned sample pairs to this CSV")
    args = parser.parse_args()

    ptat = load_ptat(args.ptat)
    tpts = load_tpts(args.tpts, args.power_unit)
    if not ptat or not tpts:
        sys.exit(f"No samples parsed (PTAT={len(ptat)}, TPTS={len(tpts)}).")

    offset, (r, neg_mae, _, _) = align(tpts, ptat, args.offset, args.max_lag, args.tolerance)
    pairs = pair(tpts, ptat, offset, args.tolerance)
    print(f"PTAT samples: {len(ptat)}  TPTS samples: {len(tpts)}  paired: {len(pairs)}")
    print(f"Offset (PTAT - TPTS): {offset:+.1f} s  [{offset / 3600:+.2f} h]  "
          f"Package Power r={fmt(r)} MAE={fmt(-neg_mae)} W at this offset")
    print()

    header = ["Metric", "N", "TPTS mean", "PTAT mean", "Bias", "MAE", "MAE %", "P95 |err|", "Max |err|", "r"]
    table = []
    for label, key, _ in NUMERIC:
        values = [(a[key], b[key]) for a, b in pairs if a.get(key) is not None and b.get(key) is not None]
        if not values:
            continue
        xs, ys = zip(*values)
        errors = [x - y for x, y in values]
        abs_errors = [abs(e) for e in errors]
        mean_ptat = sum(ys) / len(ys)
        mae = sum(abs_errors) / len(abs_errors)
        table.append([
            label, str(len(values)), fmt(sum(xs) / len(xs)), fmt(mean_ptat), fmt(sum(errors) / len(errors)), fmt(mae),
            fmt(mae / abs(mean_ptat) * 100, 1) if mean_ptat else "-",
            fmt(percentile(abs_errors, 0.95)), fmt(max(abs_errors)), fmt(pearson(xs, ys)),
        ])
    widths = [max(len(row[i]) for row in [header] + table) for i in range(len(header))]
    for row in [header] + table:
        print("  ".join(cell.ljust(widths[i]) if i == 0 else cell.rjust(widths[i]) for i, cell in enumerate(row)))

    reason_pairs = [(a, b) for a, b in pairs if b.get("reasons") is not None and a.get("reasons") is not None]
    if reason_pairs:
        exact = sum(1 for a, b in reason_pairs if a["reasons"] == b["reasons"])
        covered = [(a, b) for a, b in reason_pairs if a.get("reasons_1s") is not None]
        hit = sum(1 for a, b in covered if b["reasons"] <= (a["reasons_1s"] | a["reasons"]))
        print()
        print(f"CPU Limit Reason: Now == PTAT IA Clip Reason MSR: {exact}/{len(reason_pairs)} "
              f"({exact / len(reason_pairs) * 100:.1f}%)")
        if covered:
            print(f"CPU Limit Reason: PTAT reasons within TPTS Now+Last 1s: {hit}/{len(covered)} "
                  f"({hit / len(covered) * 100:.1f}%)")

    if args.out:
        keys = [key for _, key, _ in NUMERIC]
        with open(args.out, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(["tpts_time_utc", "ptat_time_utc"] + [f"{p}_{k}" for k in keys for p in ("tpts", "ptat")]
                            + ["tpts_reasons", "tpts_reasons_1s", "ptat_reasons"])
            for a, b in pairs:
                writer.writerow(
                    [datetime.fromtimestamp(a["t"], timezone.utc).isoformat(), datetime.fromtimestamp(b["t"], timezone.utc).isoformat()]
                    + ["" if s.get(k) is None else s[k] for k in keys for s in (a, b)]
                    + [";".join(sorted(a.get("reasons") or [])), ";".join(sorted(a.get("reasons_1s") or [])),
                       ";".join(sorted(b.get("reasons") or []))])
        print(f"\nPairs written to {args.out}")


if __name__ == "__main__":
    main()
