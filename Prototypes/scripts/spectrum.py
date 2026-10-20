#!/usr/bin/env python3
"""Compare la bande passante (énergie par bande) de fichiers audio."""
import sys
import numpy as np
from levels import load

bands = [(50, 300), (300, 1000), (1000, 3000), (3000, 6000), (6000, 8000), (8000, 12000), (12000, 16000), (16000, 20000)]
print(f"{'':>12}" + "".join(f"{f'{a//1000 if a>=1000 else a}-{b//1000}k':>10}" for a, b in bands))
for path in sys.argv[1:]:
    x = load(path)[48000:]  # ignore la 1re seconde
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    f = np.fft.rfftfreq(len(x), 1 / 48000)
    tot = spec.sum()
    print(f"{path.split('/')[-2] + '/' + path.split('/')[-1][:6]:>12}" +
          "".join(f"{10*np.log10(spec[(f>=a)&(f<b)].sum()/tot + 1e-12):10.1f}" for a, b in bands))
