<p align="center">
  <img src="docs/screenshots/onboarding-1-light.png" width="420" alt="Hush">
</p>

<h1 align="center">Hush</h1>

<p align="center"><b>A clean microphone for Discord, Zoom, Meet, OBS… on your Mac.</b><br>
Your friends hear your voice — not the music or videos playing on your speakers.</p>

<p align="center">English · <a href="README.fr.md">Français</a></p>

---

## The problem

On a MacBook, the built-in microphone picks up everything coming out of the speakers. Discord only cancels
**its own** sound, so Spotify, a YouTube video or a game goes straight to your friends.

Apple's voice processing (the one FaceTime uses) can remove **all** of your Mac's sound. Hush applies it to your
microphone and exposes the result as a new microphone, **“Hush Microphone”**, that you pick in any app.

```
Mac microphone ──► Hush (Apple voice processing) ──► “Hush Microphone” ──► Discord, Zoom, OBS…
                         ▲
        speaker sound (echo reference)
```

<p align="center">
  <img src="docs/screenshots/menu-light.png" width="300" alt="Hush menu (light)">
  <img src="docs/screenshots/menu-dark.png" width="300" alt="Hush menu (dark)">
</p>

## Install (for everyone)

1. Download **Hush-x.y.z.dmg** from [Releases](https://github.com/Showdown76py/Hush/releases).
2. Open the DMG and drag **Hush** into **Applications**.
3. Open Hush from Applications. If macOS refuses to open it, see [below](#macos-wont-open-hush).
4. Follow the 5 welcome screens:
   1. a one-sentence explanation;
   2. **allow the microphone**;
   3. **install the virtual microphone** (macOS asks for your password once);
   4. **try it**: play music, talk for 10 seconds, then listen to “without Hush” and “with Hush”;
   5. set up Discord.

### Discord setup

Discord › **User Settings** › **Voice & Video**:

| Setting | Value |
|---|---|
| Input device | **Hush Microphone** |
| Echo Cancellation | off |
| Noise Suppression | None |
| Automatic Gain Control | off |

Hush already does this work, and leaving Discord's processing on would clean your voice twice and degrade it.
In Zoom, Meet or OBS, just pick “Hush Microphone” as the microphone.

<p align="center"><img src="docs/screenshots/discord-dark.png" width="480" alt="Discord settings diagram"></p>

### macOS won't open Hush

Builds published **without an Apple Developer account** aren't notarized by Apple. On first launch, macOS says
“Apple could not verify Hush is free of malware”. To open it anyway:

- **macOS 15 and later**: try to open Hush once, then go to **System Settings › Privacy & Security**,
  scroll down, click **Open Anyway** next to Hush and confirm.
- **macOS 14**: right-click (or Control-click) Hush in Applications › **Open** › **Open**.
- **Or in Terminal** (any macOS):
  ```bash
  xattr -dr com.apple.quarantine /Applications/Hush.app
  ```

You only need to do this once. Builds signed with an Apple Developer account open without any warning.

### Uninstall

Hush › Settings › **Uninstall Virtual Microphone…**, then move Hush to the Trash. Or in Terminal:
```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Hush.driver && sudo killall coreaudiod
```

## Using Hush

- **Automatic** (default): Hush only runs while an app is using “Hush Microphone” (for example while you're in a
  Discord voice channel). The rest of the time, your Mac sounds exactly as usual.
- **Always on**: processing runs all the time.
- **Off**: no processing, and “Hush Microphone” passes your microphone through unchanged, so there's no need to
  switch microphones in Discord: just flip the switch.

The menu shows two live meters: what the microphone hears, and what is sent to apps. With music playing, the first
one moves and the second one stays quiet.

Settings: source microphone, open at login, an option to lower other sounds more, and removal of the virtual
microphone. The interface is in English and French.

## FAQ

**Why is my voice sometimes slightly cut when music is playing?**
That's the “double-talk” suppressor in Apple's voice processing. When you talk while loud sound comes out of the
speakers, it briefly attenuates what it can't separate, so that no echo gets through. It can barely be tuned.
Lowering the speaker volume a little, or using headphones, almost always avoids it.

**Why does the music get a little quieter while Hush is on?**
As soon as voice processing runs, macOS lowers other sounds. Hush asks for the smallest reduction allowed:
**about 8 dB** instead of 30 dB by default. Apple's APIs don't allow going lower (we measured it, see
[the measurements](Prototypes/MEASUREMENTS.md)). That's why **Automatic** mode exists.

**Why do my speakers sound different while Hush is on?**
macOS switches the speakers to “call mode”, like in FaceTime. In Automatic mode, this only happens during your calls.

**After a call, my speakers stay quieter and then slowly come back. Why?**
When voice processing stops, macOS takes the speakers out of “call mode” gradually: the sound returns to its normal
level in about 30 to 40 seconds. We measured it: Hush isn't lowering anything (the signal sent to the speakers is
untouched); it's the Mac's internal speaker processing, and no API can speed it up. If you're in a hurry, this
command restarts the macOS audio service and brings the sound back immediately (it cuts all sound for 1 to 2
seconds and asks for your password):
```bash
sudo killall coreaudiod
```
With headphones, this doesn't happen.

**Does Hush record what I say?**
No. Everything is processed live, in memory, on your Mac. Nothing is recorded or sent anywhere, apart from the
before/after test in the welcome screens, which stays in a local temporary file.

**Does it work with headphones or AirPods?**
Yes. Hush follows audio output changes automatically (headphones, AirPods, external display…). With headphones,
there's little echo to remove anyway.

**I can hear a slight delay.**
Apple's voice processing adds about 65 ms and Hush about 15 ms. The people you talk to usually don't notice.
See the limitations below.

## Known limitations (honestly)

- **About 8 dB of ducking** on the music while processing runs: this is the floor macOS allows.
- **Speakers in “call mode”** while processing runs.
- **About 80 ms of added latency** in total (measured), of which about 65 ms comes from Apple's processing and can't be tuned.
- While Hush runs, **other apps reading the built-in microphone directly** get a quieter (about -20 dB) signal,
  partially processed by macOS. Use “Hush Microphone” in those apps.
- The virtual microphone is **mono, 48 kHz**. Apps convert automatically when needed.
- **macOS 14 or later** is required. Liquid Glass shows on macOS 26+, with an equivalent look on earlier versions.
- **Without an Apple Developer account** (ad-hoc signature):
  - Gatekeeper blocks the first launch (see above);
  - the virtual microphone works normally (verified: coreaudiod loads an ad-hoc signed driver);
  - official releases are signed with a **stable self-signed certificate**, so macOS keeps the microphone
    permission across versions. A pure ad-hoc build would ask again with every version;
  - automatic updates work, with an EdDSA signature that Sparkle checks.

## Measurements

Measured on a MacBook Air (Apple Silicon, macOS 27). Details are in [Prototypes/MEASUREMENTS.md](Prototypes/MEASUREMENTS.md) (in French):

| | Result |
|---|---|
| Music removed from the microphone | **-43.5 dB** (median, after about 3 s of convergence) |
| Music ducking | -8 dB (vs -30 dB with Apple's default) |
| Total added latency | **80.9 ms** (of which about 14 ms is Hush's own transport) |
| Mic / driver clock drift | -0.2 ppm |

An alternative based on **WebRTC AEC3** was also prototyped (`Prototypes/aec3`). It has no ducking, leaves the
speakers untouched and adds **16.6 ms** of latency, but removes less music (-28 to -35 dB). The full comparison
is in the same file.

## For developers

### Requirements

- macOS 14+ to run; **Xcode 26 or later** to build (Liquid Glass, `.icon` app icon)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

### Build and run

```bash
scripts/fetch-sparkle.sh          # downloads Sparkle (SHA-256 verified)
xcodegen generate                 # regenerates Hush.xcodeproj from project.yml
open Hush.xcodeproj               # or: xcodebuild -scheme Hush build
```

> If the repository lives in an iCloud Drive synced folder, keep Xcode's DerivedData in its default location:
> macOS adds extended attributes to bundles there, and `codesign` rejects them.

### Tests

```bash
# Driver: 2000 simulated audio cycles, with AddressSanitizer and UBSan
clang -O1 -g -fsanitize=address,undefined -std=c11 -I Shared -framework CoreAudio -framework CoreFoundation \
  Driver/Tests/driver_test.c -o build/driver_test && build/driver_test
# App
xcodebuild -scheme Hush test
```

### Installing the driver by hand (development)

```bash
Driver/build.sh                       # → build/Hush.driver (universal)
sudo scripts/install-driver.sh        # copies to /Library/Audio/Plug-Ins/HAL and restarts coreaudiod
sudo scripts/uninstall-driver.sh
```

### Releasing

```bash
./scripts/release.sh 1.0.0
```

The script builds a universal binary (arm64 + x86_64), signs it, creates the DMG in `build/release/`, then:

- **no identity**: the “Hush Self-Signed Code Signing” certificate if it is in the keychain (create it once with
  `scripts/create-signing-cert.sh`, then **back it up**), otherwise an ad-hoc signature;
- with `CODESIGN_IDENTITY="Developer ID Application: …"`: hardened runtime + timestamp;
- also with `NOTARY_PROFILE=<notarytool profile>`: notarization and stapling;
- if a Sparkle key exists (`Vendor/Sparkle/bin/generate_keys`, create it once): an EdDSA-signed `appcast.xml`
  to publish with the DMG in the GitHub release.

GitHub Actions CI builds the app, runs the driver and app tests, and produces a DMG on every push (as a workflow
artifact). Pushing a `vX.Y.Z` tag automatically publishes a GitHub release with the DMG. To have it sign
with the self-signed certificate, add the `HUSH_SIGNING_P12` (base64 `.p12`) and `HUSH_SIGNING_P12_PASSWORD` secrets.

### Architecture

```
App/            SwiftUI menu bar app
  RealTime/     audio callbacks in C: no allocation, no lock, no Swift runtime
  Sources/      engine (VoiceProcessingIO), controller (modes, auto-recovery), installer, UI
Driver/         AudioServerPlugIn in C (“Hush Microphone”): only relays audio
Shared/         app ↔ driver shared-memory contract (lock-free SPSC ring buffer)
Prototypes/     measurement tools and prototypes (VP, BlackHole, playback relay, AEC3)
scripts/        release, driver install, Sparkle
```

- **Transport**: the app writes into a lock-free ring buffer in POSIX shared memory. The driver reads it on every
  IO cycle, keeping a safety margin beyond the client app's buffer, and outputs silence when the app isn't running.
- **Auto-recovery**: output changes (headphones, AirPods), microphones plugged in or out, sample-rate changes,
  sleep and wake, coreaudiod restarts, and a watchdog on audio callbacks.
- The driver was written from scratch from the `AudioServerPlugIn.h` documentation: no BlackHole (GPL) code.

## License

MIT, see [LICENSE](LICENSE). Hush uses [Sparkle](https://sparkle-project.org) (MIT). The AEC3 prototype uses
[webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) (BSD-3).
