#!/usr/bin/env python3
"""Affiche le niveau RMS (dBFS) par fenêtre d'une seconde d'un fichier audio."""
import subprocess, sys
import numpy as np

def load(path, sr=48000):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "1", "-ar", str(sr), "-"],
                         check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32)

def rms_db(x):
    return 20 * np.log10(np.sqrt(np.mean(np.square(x, dtype=np.float64))) + 1e-12)

if __name__ == "__main__":
    for path in sys.argv[1:]:
        x = load(path)
        print(path.split("/")[-1], f"{len(x)/48000:.1f}s")
        print("  " + " ".join(f"{rms_db(x[i:i+48000]):6.1f}" for i in range(0, len(x) - 47999, 48000)))
