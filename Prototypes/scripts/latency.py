#!/usr/bin/env python3
"""latency between two channels of one recording (sample aligned) via
cross correlation over sliding windows. usage: latency.py <stereo.wav> [ch_ref ch_test]"""
import subprocess, sys
import numpy as np

path = sys.argv[1]
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "2", "-ar", "48000", "-"],
                     check=True, capture_output=True).stdout
x = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2)
ref, test = x[:, 0].astype(np.float64), x[:, 1].astype(np.float64)
SR, W, MAXLAG = 48000, 48000, 9600  # 1 s windows, max latency searched 200 ms
lags = []
for start in range(0, len(ref) - W - MAXLAG, W // 2):
    a = ref[start:start + W]
    if np.sqrt(np.mean(a ** 2)) < 1e-5: continue      # silent window
    b = test[start:start + W + MAXLAG]
    n = 1 << int(np.ceil(np.log2(len(a) + len(b))))
    c = np.fft.irfft(np.conj(np.fft.rfft(a, n)) * np.fft.rfft(b, n), n)[:MAXLAG]
    norm = np.sqrt(np.sum(a ** 2) * np.sum(b[:W] ** 2)) + 1e-12
    k = int(np.argmax(np.abs(c)))
    if abs(c[k]) / norm > 0.3:
        lags.append(k)
if not lags:
    print("aucune corrélation fiable"); sys.exit(1)
lags = np.array(lags) / SR * 1000
print(f"fenêtres={len(lags)} latence médiane={np.median(lags):.1f} ms min={lags.min():.1f} max={lags.max():.1f}")
