#!/usr/bin/env python3
"""Profile a running app for >=60 seconds without changing its state or permissions."""
import argparse
import json
import pathlib
import time
import math
from runtime_metrics import process, pids, power, summarize, monotonic_seconds

parser = argparse.ArgumentParser()
parser.add_argument("output")
parser.add_argument("diagnostic", nargs="?", default="Validation/runtime-current.json")
parser.add_argument("--pid", type=int)
parser.add_argument("--duration", type=float, default=60)
args = parser.parse_args()
out = pathlib.Path(args.output); out.mkdir(parents=True, exist_ok=True)
diagnostic = pathlib.Path(args.diagnostic)
apps = [args.pid] if args.pid else pids("/HingeGlass")
if len(apps) != 1:
    raise SystemExit("Specify --pid when no unique running HingeGlass process exists.")
app = apps[0]; ws = pids("/WindowServer")
rows, snapshots = [], []
before = power()
start = monotonic_seconds()
while True:
    now = monotonic_seconds()
    rows.append({"time":now, "app":process(app), "WindowServer":process(ws[0]) if ws else None})
    if diagnostic.exists():
        try:
            value = json.loads(diagnostic.read_text())
            if not snapshots or value.get("time") != snapshots[-1].get("time"):
                snapshots.append(value)
        except (OSError, ValueError):
            pass
    if now - start >= max(60, args.duration):
        break
    time.sleep(min(1, max(60, args.duration) - (now - start)))
summary = {"pid":app, "duration": rows[-1]["time"] - start, "app":summarize(rows,"app"),
           "WindowServer":summarize(rows,"WindowServer"), "power_before":before, "power_after":power(),
           "power_watts":None, "WindowServer_note":"Includes other apps; not all load is attributable to MacBook Duo."}
if snapshots:
    first,last=snapshots[0],snapshots[-1]
    summary["diagnostic_first"]=first; summary["diagnostic_last"]=last
    summary["states"]=sorted(set(s.get("state","unknown") for s in snapshots))
    summary["diagnostics_span"]=last.get("time",0)-first.get("time",0)
    summary["deltas"]={key:last.get(key,0)-first.get(key,0) for key in
        ["captureFrames","contentFrames","renderFrames","pyramidBuilds","gpuSeconds","encodeSeconds","sensorReads","sensorChanges","sensorReadSeconds","schedulerUpdates"]}
    count = len(first.get("motionFrameIntervals", []))
    intervals = last.get("motionFrameIntervals", [])[count:]
    ordered = sorted(intervals)
    summary["motion_intervals_in_window"] = len(intervals)
    summary["motion_interval_p95_ms"] = ordered[math.ceil(.95 * len(ordered)) - 1] * 1000 if ordered else None
    summary["first_capture_waits_seconds"] = last.get("firstFrameWaits", [])
    summary["first_presentation_waits_seconds"] = last.get("firstPresentationWaits", [])
(out/"process-samples.json").write_text(json.dumps(rows,indent=2))
(out/"diagnostics.json").write_text(json.dumps(snapshots,indent=2))
(out/"summary.json").write_text(json.dumps(summary,indent=2))
print(json.dumps({k:v for k,v in summary.items() if not k.startswith("diagnostic_")},indent=2))
