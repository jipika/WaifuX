#!/usr/bin/env python3
"""Sample the complete WaifuX process group; CPU/RSS estimates, not an energy test."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--scenario', required=True)
parser.add_argument('--seconds', type=float, default=600)
parser.add_argument('--interval', type=float, default=5)
parser.add_argument('--extra-pids', type=int, nargs='*', default=[])
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.seconds <= 0 or args.interval <= 0:
    parser.error('seconds and interval must be positive')
app = str(args.app.resolve()) + '/'

def cpu_seconds(value):
    result = 0.0
    for part in value.split(':'):
        result = result * 60 + float(part)
    return result

def processes():
    output = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,time=,comm='], text=True)
    rows = {}
    for line in output.splitlines():
        parts = line.split(None, 4)
        if len(parts) != 5:
            continue
        pid, parent, rss, cpu, command = parts
        rows[int(pid)] = {'pid': int(pid), 'parent': int(parent), 'rssKB': int(rss), 'cpuSeconds': cpu_seconds(cpu), 'executable': command}
    selected = {pid for pid, row in rows.items() if row['executable'].startswith(app)} | set(args.extra_pids)
    while True:
        descendants = {pid for pid, row in rows.items() if row['parent'] in selected}
        if descendants <= selected:
            break
        selected |= descendants
    return {pid: row for pid, row in rows.items() if pid in selected}

started = datetime.now(timezone.utc).isoformat()
previous = processes()
if not previous:
    parser.error('No running process found for this bundle; supply extra PIDs for development executables')
start = previous_time = time.monotonic()
samples = []
while time.monotonic() - start < args.seconds:
    time.sleep(min(args.interval, max(0, args.seconds - (time.monotonic() - start))))
    current_time = time.monotonic()
    current = processes()
    elapsed = current_time - previous_time
    delta = sum(max(0, row['cpuSeconds'] - previous.get(pid, row)['cpuSeconds']) for pid, row in current.items())
    samples.append({'elapsedSeconds': current_time - start, 'cpuPercentEstimate': delta / elapsed * 100, 'rssMB': sum(row['rssKB'] for row in current.values()) / 1024, 'processes': list(current.values())})
    previous, previous_time = current, current_time

def percentile(values, fraction):
    return sorted(values)[min(len(values) - 1, int((len(values) - 1) * fraction))]

cpu = [sample['cpuPercentEstimate'] for sample in samples]
rss = [sample['rssMB'] for sample in samples]
report = {'scenario': args.scenario, 'startedAtUTC': started, 'app': app, 'durationSeconds': time.monotonic() - start, 'summary': {'cpuMeanPercentEstimate': statistics.mean(cpu), 'cpuP95PercentEstimate': percentile(cpu, .95), 'rssMeanMB': statistics.mean(rss), 'rssP95MB': percentile(rss, .95)}, 'limits': ['CPU deltas omit work by processes born or exiting between samples.', 'RSS sums shared pages and is not private memory or physical footprint.', 'Wakeups, GPU, decode activity and energy require Instruments/powermetrics.', 'Run after builds and unrelated workloads finish; compare identical scenarios and repeat.'], 'samples': samples}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, indent=2))
print(json.dumps(report['summary'], indent=2))
print(args.output.resolve())
