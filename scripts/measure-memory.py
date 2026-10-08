#!/usr/bin/env python3
"""Read-only RSS/CPU sampling for an existing process; no extra dependencies."""
import argparse
import csv
import ctypes
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('pid', type=int)
parser.add_argument('--samples', type=int, default=10)
parser.add_argument('--interval', type=float, default=1, help='seconds between samples (0.1–60)')
args = parser.parse_args()
if args.pid <= 0 or not 1 <= args.samples <= 360 or not 0.1 <= args.interval <= 60:
    parser.error('use a positive PID, 1–360 samples, and an interval of 0.1–60 seconds')

# Public macOS rusage_info_v2 layout (sys/resource.h). No task port, debugger,
# target-process mutation or elevated entitlement is required.
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins',
        'wired_size', 'resident_size', 'phys_footprint', 'proc_start_abstime', 'proc_exit_abstime',
        'child_user_time', 'child_system_time', 'child_pkg_idle_wkups', 'child_interrupt_wkups',
        'child_pageins', 'child_elapsed_abstime', 'diskio_bytesread', 'diskio_byteswritten')]

libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int
writer = csv.writer(sys.stdout)
writer.writerow(['sample', 'elapsed_s', 'rss_mib', 'cpu_percent', 'footprint_mib', 'disk_written_bytes'])
started = time.monotonic()
for index in range(args.samples):
    result = subprocess.run(['ps', '-p', str(args.pid), '-o', 'rss=,pcpu='],
                            capture_output=True, text=True, check=False)
    fields = result.stdout.split()
    if result.returncode or len(fields) != 2:
        sys.exit('Process exited or its resource usage is unavailable.')
    usage = Usage()
    available = libproc.proc_pid_rusage(args.pid, 2, ctypes.byref(usage)) == 0
    writer.writerow([index + 1, f'{time.monotonic() - started:.2f}', f'{int(fields[0]) / 1024:.2f}', fields[1],
                     f'{usage.phys_footprint / 1024**2:.2f}' if available else '',
                     usage.diskio_byteswritten if available else ''])
    sys.stdout.flush()
    if index + 1 < args.samples:
        time.sleep(args.interval)
