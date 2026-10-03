#!/usr/bin/env python3
"""Read-only RSS/CPU sampling for an existing process; no extra dependencies."""
import argparse
import csv
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('pid', type=int)
parser.add_argument('--samples', type=int, default=10)
args = parser.parse_args()
if args.pid <= 0 or not 1 <= args.samples <= 60:
    parser.error('use a positive PID and 1–60 samples')
writer = csv.writer(sys.stdout)
writer.writerow(['sample', 'rss_mib', 'cpu_percent'])
for index in range(args.samples):
    result = subprocess.run(['ps', '-p', str(args.pid), '-o', 'rss=,pcpu='],
                            capture_output=True, text=True, check=False)
    fields = result.stdout.split()
    if result.returncode or len(fields) != 2:
        sys.exit('Process exited or its resource usage is unavailable.')
    writer.writerow([index + 1, f'{int(fields[0]) / 1024:.2f}', fields[1]])
    sys.stdout.flush()
    if index + 1 < args.samples:
        time.sleep(1)
