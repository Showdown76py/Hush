#!/usr/bin/env python3
"""absolute latency (click emitted -> detected) for each channel of a dualrec recording
usage: clicklat.py <dual.wav> <clicks.txt>"""
import subprocess, sys
import numpy as np

wav, clicks = sys.argv[1], sys.argv[2]
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", wav, "-f", "f32le", "-ac", "2", "-ar", "48000", "-"],
                     check=True, capture_output=True).stdout
x = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).astype(np.float64)
t0 = float(open(wav + ".t0").read())
SR = 48000
times = [float(l) for l in open(clicks) if l.strip()]
for ch, name in [(0, "A"), (1, "B")]:
    lat = []
    for t in times:
        i = int(round((t - t0) / 1e9 * SR))
        if i < 9600 or i + 19200 > len(x): continue
        pre = x[i - 9600:i, ch]                   # 200 ms before the click
        win = np.abs(x[i:i + 19200, ch])           # 400 ms after
        noise = np.percentile(np.abs(pre), 99) + 1e-9
        if win.max() < 4 * noise: lat.append(None); continue
        thr = max(4 * noise, 0.3 * win.max())
        lat.append(int(np.argmax(win > thr)) / SR * 1000)
    s = " ".join("  --  " if v is None else f"{v:6.1f}" for v in lat)
    print(f"{name}: {s}")
