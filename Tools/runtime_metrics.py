"""Read-only per-process counters. Energy counters have opaque OS units, not watts."""
import ctypes
import ctypes.util
import json
import pathlib
import subprocess
import time

FIELDS = """user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles billed_energy serviced_energy interval_max_phys_footprint runnable_time""".split()

class RUsage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in FIELDS]

LIB = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib", use_errno=True)
LIB.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
LIB.proc_pid_rusage.restype = ctypes.c_int

class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

TIMEBASE = Timebase()
SYSTEM = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
SYSTEM.mach_timebase_info(ctypes.byref(TIMEBASE))
SYSTEM.mach_absolute_time.restype = ctypes.c_uint64
TICK_SECONDS = TIMEBASE.numer / TIMEBASE.denom / 1e9

def monotonic_seconds():
    """The same uptime epoch as CACurrentMediaTime, including on older Python."""
    return SYSTEM.mach_absolute_time() * TICK_SECONDS

def seconds(value):
    total = 0.0
    for piece in value.split(":"):
        total = total * 60 + float(piece)
    return total

def process(pid):
    info = RUsage()
    if LIB.proc_pid_rusage(int(pid), 4, ctypes.byref(info)) == 0:
        return {"method": "proc_pid_rusage_v4",
                "cpu_seconds": (info.user_time + info.system_time) * TICK_SECONDS,
                "resident_bytes": info.resident_size, "footprint_bytes": info.phys_footprint,
                "idle_wakeups": info.pkg_idle_wkups, "interrupt_wakeups": info.interrupt_wkups,
                "billed_energy_raw": info.billed_energy, "instructions": info.instructions,
                "cycles": info.cycles, "disk_bytes_written": info.diskio_byteswritten}
    result = subprocess.run(["ps", "-p", str(pid), "-o", "time=,rss="], text=True, capture_output=True)
    parts = result.stdout.split()
    if result.returncode == 0 and len(parts) >= 2:
        return {"method": "ps_time_rss_fallback", "cpu_seconds": seconds(parts[0]),
                "resident_bytes": int(parts[1]) * 1024, "footprint_bytes": None}
    return None

def pids(suffix):
    lines = subprocess.check_output(["ps", "-axo", "pid,comm"], text=True).splitlines()
    return [int(line.split()[0]) for line in lines if line.rstrip().endswith(suffix)]

def power():
    result = subprocess.run(["pmset", "-g", "batt"], text=True, capture_output=True)
    return result.stdout.strip()

def summarize(rows, label):
    values = [(row["time"], row.get(label)) for row in rows if row.get(label)]
    if len(values) < 2:
        return {"available": False, "samples": len(values)}
    first, last = values[0], values[-1]
    elapsed = last[0] - first[0]
    cpu = []
    for (t1, a), (t2, b) in zip(values, values[1:]):
        if t2 > t1:
            cpu.append(max(0, b["cpu_seconds"] - a["cpu_seconds"]) / (t2 - t1) * 100)
    ordered = sorted(cpu)
    result = {"available": True, "samples": len(cpu), "sample_span_seconds": elapsed,
              "cpu_mean_percent": (last[1]["cpu_seconds"] - first[1]["cpu_seconds"]) / elapsed * 100,
              "cpu_p95_percent": ordered[int((len(ordered) - 1) * .95)],
              "rss_last_mb": last[1]["resident_bytes"] / 1e6,
              "rss_peak_mb": max(v["resident_bytes"] for _, v in values) / 1e6,
              "method": last[1]["method"]}
    footprints = [v["footprint_bytes"] for _, v in values if v.get("footprint_bytes") is not None]
    if footprints:
        result["footprint_peak_mb"] = max(footprints) / 1e6
    for key in ["idle_wakeups", "interrupt_wakeups", "billed_energy_raw", "instructions", "cycles", "disk_bytes_written"]:
        if key in first[1] and key in last[1]:
            result[key + "_delta"] = max(0, last[1][key] - first[1][key])
    return result
