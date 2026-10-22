#!/usr/bin/env python3
"""Builds the before/after demo clips for the website.

Per language, one stereo file (left = raw MacBook mic, right = the same mic through Hush) and a json of
level envelopes for the player's meter. Everything is simulated from:
  - scripts/site-audio/voice-{en,fr}.mp3 (ElevenLabs voices)
  - "Be Chillin" by Alexander Nakarada, FreePD, CC0 (downloaded, sha-256 pinned)

The Hush side follows what was measured on the real app (docs/DEVELOPMENT.md, Prototypes/MEASUREMENTS.md):
speaker music -43.5 dB, noise suppressed, voice band-limited by Apple's voice processing, short dips when
talking over loud music (double-talk suppressor), hush_agc speech level at -23 dB.

usage: scripts/make-site-audio.py [out_dir]   (default: site/assets/audio). Needs numpy and ffmpeg.
"""
import hashlib
import json
import os
import subprocess
import sys
import urllib.request

import numpy as np

SR = 48000
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.expanduser("~/Library/Caches/io.github.showdown76py.Hush")
MUSIC_URL = "https://archive.org/download/freepd/upbeat/Be%20Chillin.mp3"
MUSIC_SHA256 = "1abaa9455ced505f10306b34d1fe569a43be28809ae39e62f422c69f312a74cb"

BAR = 1.79115            # 134 bpm, from onset autocorrelation over 16 bars
LOOP = 8 * BAR           # 14.33 s
LOOP_START = 41.19       # a downbeat once the groove is in
XFADE = 0.25
VOICE_AT = 1.0

RNG = np.random.default_rng(76)


def db(x):
    return 10 ** (x / 20)


def decode(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).astype(np.float64)


def ffilter(x, af):
    p = subprocess.run(["ffmpeg", "-v", "error", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", "-",
                        "-af", af, "-f", "f32le", "-"],
                       input=x.astype(np.float32).tobytes(), capture_output=True, check=True)
    y = np.frombuffer(p.stdout, np.float32).astype(np.float64)
    return np.pad(y, (0, max(0, len(x) - len(y))))[: len(x)]


def ffilter_loop(x, af):
    # filter 3 periods and keep the middle one so iir tails wrap and the loop stays seamless
    n = len(x)
    return ffilter(np.tile(x, 3), af)[n:2 * n]


def cconv(x, h):
    n = len(x)
    return np.fft.irfft(np.fft.rfft(x) * np.fft.rfft(h, n), n)


def room(rt60, drr_db, pre_ms):
    # direct path + exponentially decaying noise tail, energy ratio set by drr
    n = int(rt60 * SR)
    t = np.arange(n) / SR
    tail = RNG.standard_normal(n) * np.exp(-6.91 * t / rt60)
    tail[: int(pre_ms * SR / 1000)] = 0
    tail *= db(-drr_db) / np.sqrt(np.sum(tail ** 2))
    tail[0] += 1
    return tail


def rms(x):
    return np.sqrt(np.mean(x ** 2) + 1e-20)


def frames(x, ms):
    hop = int(SR * ms / 1000)
    n = len(x) // hop
    return np.sqrt(np.mean(x[: n * hop].reshape(n, hop) ** 2, axis=1) + 1e-20)


def follow(env, attack, release, hop_s):
    a, r = np.exp(-hop_s / attack), np.exp(-hop_s / release)
    out, y = np.empty_like(env), env[0]
    for i, v in enumerate(env):
        y = a * y + (1 - a) * v if v < y else r * y + (1 - r) * v
        out[i] = y
    return out


def music_loop():
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, "be-chillin.mp3")
    if not os.path.exists(path):
        urllib.request.urlretrieve(MUSIC_URL, path)
    with open(path, "rb") as f:
        if hashlib.sha256(f.read()).hexdigest() != MUSIC_SHA256:
            sys.exit(f"bad checksum for {path}")
    x = decode(path)
    a, n, k = int(LOOP_START * SR), int(LOOP * SR), int(XFADE * SR)
    seg = x[a: a + n + k].copy()
    w = np.sin(np.linspace(0, np.pi / 2, k)) ** 2
    out = seg[:n]
    out[:k] = seg[:k] * np.sqrt(w) + seg[n: n + k] * np.sqrt(1 - w)
    return out


def pink(n):
    spec = np.fft.rfft(RNG.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / SR)
    spec[1:] /= np.sqrt(f[1:] / 100)
    spec[0] = 0
    return ffilter_loop(np.fft.irfft(spec, n), "highpass=f=60")


def build(lang, music, out_dir):
    n = len(music)
    hop = int(SR * 0.02)

    # what a laptop mic hears from its own speakers: no lows, some chassis resonance,
    # mild speaker distortion and a small room
    m = music / np.max(np.abs(music))
    m = np.tanh(1.8 * m) / np.tanh(1.8)
    m = ffilter_loop(m, "highpass=f=190:poles=2,highpass=f=190:poles=2,equalizer=f=2600:t=q:w=1.2:g=3,"
                        "lowpass=f=13000")
    music_mic = cconv(m, room(0.38, 2, 3))

    voice = np.zeros(n)
    v = decode(os.path.join(HERE, "site-audio", f"voice-{lang}.mp3"))
    i = int(VOICE_AT * SR)
    voice[i: i + len(v)] = v[: n - i]
    voice_mic = ffilter(cconv(voice, room(0.38, 9, 2)), "highpass=f=80")
    speech = frames(voice, 20) > db(-45)

    def speech_rms(x):
        f = frames(x, 20)
        return np.sqrt(np.mean(f[speech[: len(f)]] ** 2))

    # raw mic: music about as loud as the voice, like a MacBook with the volume up
    noise = pink(n)
    voice_mic *= db(-27) / speech_rms(voice_mic)
    music_mic *= db(-25) / rms(music_mic)
    noise *= db(-64) / rms(noise)
    raw = voice_mic + music_mic + noise

    # apple voice processing: band-limited voice, noise suppressed
    vp = ffilter(voice_mic, "highpass=f=100,lowpass=f=11500:poles=2,lowpass=f=11500:poles=2,"
                            "equalizer=f=3200:t=q:w=1.4:g=1.5")
    # double-talk suppressor ducks a few dB when the speaker music is loud next to the voice
    over = 20 * np.log10(frames(music_mic, 20) / (frames(voice_mic, 20) + 1e-9))
    duck_db = np.where(speech[: len(over)], -np.clip((over + 4) * 0.9, 0, 7), 0.0)
    duck = np.repeat(db(follow(duck_db, 0.01, 0.12, 0.02)), hop)
    vp *= np.pad(duck, (0, max(0, n - len(duck))), "edge")[:n]
    # hush_agc: speech blocks around -23 dB, soft limit on peaks
    vp *= db(-23) / speech_rms(vp)
    vp = np.tanh(vp / db(-3)) * db(-3)
    residual = ffilter_loop(music_mic, "lowpass=f=6000") * db(-43.5)
    clean_noise = noise * db(-18)
    clean = vp + residual + clean_noise

    peak = max(np.max(np.abs(raw)), np.max(np.abs(clean)))
    if peak > db(-1):
        raw, clean = raw * db(-1) / peak, clean * db(-1) / peak

    stereo = np.stack([raw, clean], axis=1).astype(np.float32)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", "-",
                    "-c:a", "aac", "-b:a", "192k", os.path.join(out_dir, f"demo-{lang}.m4a")],
                   input=stereo.tobytes(), check=True)

    # meter envelopes, 50 ms frames, linear rms x1000
    def env(x):
        return [int(round(min(1, v) * 1000)) for v in frames(x, 50)]

    meta = {
        "loop": round(LOOP, 4),
        "frame": 0.05,
        "off": {"voice": env(voice_mic), "music": env(music_mic + noise)},
        "on": {"voice": env(vp), "music": env(residual + clean_noise)},
    }
    with open(os.path.join(out_dir, f"demo-{lang}.json"), "w") as f:
        json.dump(meta, f, separators=(",", ":"))

    gap = frames(clean, 20)[~speech].mean() / frames(raw, 20)[~speech].mean()
    print(f"{lang}: raw speech {20 * np.log10(speech_rms(voice_mic)):.1f} dB, music {20 * np.log10(rms(music_mic)):.1f} dB"
          f" | hush speech {20 * np.log10(speech_rms(vp)):.1f} dB, residual {20 * np.log10(rms(residual)):.1f} dB,"
          f" deepest dip {np.min(duck_db):.1f} dB, music-only parts {20 * np.log10(gap):.1f} dB")


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "site/assets/audio"
    os.makedirs(out_dir, exist_ok=True)
    music = music_loop()
    for lang in ("en", "fr"):
        build(lang, music, out_dir)


if __name__ == "__main__":
    main()
