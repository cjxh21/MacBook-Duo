#!/usr/bin/env python3
"""Controlled full-app measurements. Authorize the built app before running.

Only the processes started here are stopped. Preferences are overridden in the
process argument domain; calibration and the user's saved choices are unchanged.
Synthetic scenarios require collection to be disabled and are labeled in logs.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
from runtime_metrics import pids

parser = argparse.ArgumentParser()
parser.add_argument("--duration", type=float, default=60)
parser.add_argument("--case", action="append")
parser.add_argument("--output", default="Validation/FullApp")
parser.add_argument("--allow-desktop-overlay", action="store_true",
                    help="Explicitly allow the fixture and effect to cover the current desktop.")
args = parser.parse_args()
if not args.allow_desktop_overlay:
    parser.error("This test changes the global desktop. Use offscreen tests instead, or pass --allow-desktop-overlay only when the user is ready.")
root = Path(__file__).resolve().parent.parent
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
if pids("/HingeGlass"):
    raise SystemExit("Quit the running MacBook Duo first so the emergency shortcut belongs to the test process.")
binary = root / "MacBook Duo.app/Contents/MacOS/HingeGlass"
fixture_binary = root / "Validation/bin/desktop-fixture"
subprocess.run(["swiftc", "-parse-as-library", "-O", "-framework", "AppKit", str(root/"Tools/DesktopFixture.swift"), "-o", str(fixture_binary)], check=True)
cases = [
    ("off-no-recording", None, "saver", False, "off"),
    ("off-recording", None, "saver", True, "off"),
    ("saver-clear", "clear", "saver", False, "clearIdle"),
    ("balanced-clear", "clear", "balanced", False, "clearIdle"),
    ("responsive-clear", "clear", "responsive", False, "clearIdle"),
    ("saver-static", "static", "saver", False, "staticEffect"),
    ("responsive-moving", "moving", "responsive", False, "moving"),
    ("saver-moving", "moving", "saver", False, "moving"),
]
fixture = subprocess.Popen([str(fixture_binary)])
try:
    time.sleep(1)
    for name, scene, mode, recording, state in cases:
        if args.case and name not in args.case:
            continue
        folder = out / name
        folder.mkdir(parents=True, exist_ok=True)
        # A new filename avoids accepting a previous run's permission status.
        diagnostic = folder / ("current-" + str(time.time_ns()) + ".json")
        command = [str(binary), "--background", "--diagnostics", str(diagnostic),
                   "-performanceMode", mode, "-recording.enabled", "YES" if recording else "NO"]
        if scene:
            command += ["--start-effects", "--validation-state", scene]
        with (folder / "run.log").open("w") as log:
            child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, cwd=root)
            print(f"START {name} pid={child.pid}", flush=True)
            try:
                deadline = time.monotonic() + 20
                ready = False
                while time.monotonic() < deadline and child.poll() is None:
                    time.sleep(.5)
                    try:
                        info = json.loads(diagnostic.read_text())
                    except (OSError, ValueError):
                        continue
                    if scene and not info.get("screenCaptureAllowed"):
                        raise RuntimeError("Screen recording is not authorized for this build; use System Settings, then rerun.")
                    state_ready = info.get("state") == state or (state == "moving" and info.get("state") == "staticEffect")
                    ready = state_ready and (not scene or scene == "clear" or info.get("overlayVisible"))
                    if ready:
                        break
                if not ready:
                    raise RuntimeError("App did not reach the requested state; see " + str(diagnostic))
                time.sleep(3)
                subprocess.run([sys.executable, str(root/"Tools/monitor-runtime.py"), str(folder), str(diagnostic),
                                "--pid", str(child.pid), "--duration", str(max(60, args.duration))],
                               check=True, stdout=log, stderr=subprocess.STDOUT, cwd=root)
                report = json.loads((folder/"summary.json").read_text())
                allowed_states = {state, "staticEffect"} if state == "moving" else {state}
                report["case"] = name
                report["scope"] = "Full built app + real HID reads + real ScreenCaptureKit + Metal on a fixed desktop fixture. Simulated coordinator angles; no physical latency claim."
                report["validation_passed"] = set(report.get("states", [])) <= allowed_states and bool(report.get("states"))
                report["source_fixture"] = "Tools/DesktopFixture.swift"
                report["minimum_60_seconds"] = report["duration"] >= 60
                (folder/"summary.json").write_text(json.dumps(report, indent=2))
                d=report.get("deltas", {})
                print(f"END {name}: CPU {report['app']['cpu_mean_percent']:.3f}%, capture {d.get('captureFrames')}, render {d.get('renderFrames')}, P95 {report.get('motion_interval_p95_ms')}, state pass={report['validation_passed']}", flush=True)
                if not report["validation_passed"]:
                    raise RuntimeError("State changed during measurement; results are marked invalid.")
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=10)
finally:
    fixture.terminate()
    fixture.wait(timeout=10)
