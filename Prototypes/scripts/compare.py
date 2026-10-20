#!/usr/bin/env python3
"""Compare des runs du test de ducking à une référence sans VP.
Ducking = écart de niveau de la sortie système (systap.wav) pendant la fenêtre VP.
AEC     = écart de niveau du micro (vp.wav) par rapport au micro brut de la référence.
Usage : compare.py <ref_dir> <run_dir>..."""
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
    # fenêtre VP ≈ secondes 5..13 de systap (VP démarre vers 4 s) ; 1..9 de vp.wav
    duck = np.median(sysl[5:13] - ref_sys[5:13])
    aec = np.median(mic[1:9] - ref_mic[1:9])
    print(f"{d.split('/')[-1]:>14}: ducking {duck:+6.1f} dB | micro vs brut {aec:+6.1f} dB")
