#!/usr/bin/env python3
"""compares ducking test runs against a no-vp reference
ducking = system output level delta (systap.wav) during the vp window
aec     = mic level delta (vp.wav) vs the reference raw mic
usage: compare.py <ref_dir> <run_dir>..."""
import sys
import numpy as np
from levels import load, rms_db

SR = 48000
def per_sec(x):
    return np.array([rms_db(x[i:i+SR]) for i in range(0, len(x) - SR + 1, SR)])

ref = sys.argv[1]
ref_sys = per_sec(load(f"{ref}/systap.wav"))
ref_mic = per_sec(load(f"{ref}/vp.wav"))
for d in sys.argv[2:]:
    sysl = per_sec(load(f"{d}/systap.wav"))
    mic = per_sec(load(f"{d}/vp.wav"))
    # vp window ~ seconds 5..13 of systap (vp starts ~4 s), 1..9 of vp.wav
    duck = np.median(sysl[5:13] - ref_sys[5:13])
    aec = np.median(mic[1:9] - ref_mic[1:9])
    print(f"{d.split('/')[-1]:>14}: ducking {duck:+6.1f} dB | micro vs brut {aec:+6.1f} dB")
