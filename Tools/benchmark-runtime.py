#!/usr/bin/env python3
"""Run legacy/new component benchmarks sequentially with the same fixture and display."""
import argparse
import json
import pathlib
import subprocess
import time
from runtime_metrics import process, pids, power, summarize, monotonic_seconds

parser = argparse.ArgumentParser()
parser.add_argument("--duration", type=float, default=60)
parser.add_argument("--output", default="Validation/Performance")
parser.add_argument("--case", action="append", help="Restrict to named case(s).")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
output = pathlib.Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
binary = root / "Validation/bin/runtime-benchmark"
cases = [
    ("old-off", ["--legacy", "--state", "off"]),
    ("new-off", ["--state", "off"]),
    ("new-off-recording", ["--state", "off", "--record"]),
    ("old-clear", ["--legacy", "--state", "clear"]),
    ("new-saver-clear", ["--state", "clear", "--mode", "saver"]),
    ("old-static", ["--legacy", "--state", "static"]),
    ("new-saver-static", ["--state", "static", "--mode", "saver"]),
    ("old-moving", ["--legacy", "--state", "moving"]),
    ("new-responsive-moving", ["--state", "moving", "--mode", "responsive"]),
    ("new-saver-moving-dynamic", ["--state", "moving", "--mode", "saver", "--dynamic-content"]),
    ("new-responsive-moving-dynamic", ["--state", "moving", "--mode", "responsive", "--dynamic-content"]),
]
ws = pids("/WindowServer")
for name, flags in cases:
    if args.case and name not in args.case:
        continue
    folder = output / name
    folder.mkdir(exist_ok=True)
    result_path = folder / "renderer.json"
    before = power()
    with (folder / "run.log").open("w") as log:
        child = subprocess.Popen([str(binary), *flags, "--duration", str(args.duration), "--output", str(result_path)], stdout=log, stderr=subprocess.STDOUT, cwd=root)
        print(f"START {name} pid={child.pid}", flush=True)
        rows = []
        while child.poll() is None:
            rows.append({"time": monotonic_seconds(), "app": process(child.pid), "WindowServer": process(ws[0]) if ws else None})
            time.sleep(1)
    if child.returncode:
        raise SystemExit(f"{name} failed ({child.returncode}); see {folder/'run.log'}")
    result = json.loads(result_path.read_text())
    stable = [row for row in rows if result["measurement_start"] <= row["time"] <= result["measurement_end"]]
    summary = {"case": name, "app": summarize(stable, "app"), "WindowServer": summarize(stable, "WindowServer"),
               "renderer": {k:v for k,v in result.items() if k != "motion_frame_intervals"},
               "power_before": before, "power_after": power(), "power_watts": None,
               "power_note": "powermetrics requires root; rusage energy counters are opaque OS units and are not watts.",
               "WindowServer_note": "Whole WindowServer process; load from other apps is included.",
               "minimum_60_seconds": result["duration"] >= 60 and not result["aborted"]}
    summary["app"]["cpu_mean_percent"] = result["process_cpu_mean_percent"]
    summary["app"]["exact_cpu_window_seconds"] = result["duration"]
    (folder / "process-samples.json").write_text(json.dumps(rows, indent=2))
    (folder / "summary.json").write_text(json.dumps(summary, indent=2))
    print(f"END {name}: CPU {result['process_cpu_mean_percent']:.3f}%, render {result['render_frames']}, GPU {result['gpu_seconds']:.3f}s, P95 {result['frame_interval_p95_ms']:.2f}ms", flush=True)
