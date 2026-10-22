<p align="center">
  <img src="docs/icon.png" width="128" alt="Hush icon">
</p>

<h1 align="center">Hush</h1>

<p align="center">A clean microphone for Discord, Zoom, Meet, OBS & more on your Mac.<br>
People hear your voice, not the music playing on your speakers.</p>

<p align="center"><a href="https://hush.showdown.boo"><b>hush.showdown.boo</b></a> · <a href="https://github.com/Showdown76py/Hush/releases/latest">Download</a></p>

<p align="center">English · <a href="README.fr.md">Français</a></p>

---

On a MacBook, the built-in microphone picks up whatever the speakers play. For instance, Discord only cancels its own sound,
so your Spotify playlist, a YouTube video or a game ends up being louder than your voice in everyone's ears.

Apple's voice processing, the one FaceTime uses, removes all of the Mac's sound from the microphone. Hush runs it
on your microphone and gives you the result as a new input, "Hush Microphone", that any app can use.

<p align="center">
  <img src="docs/screenshots/menu-light.png" width="300" alt="Hush menu, light mode">
  <img src="docs/screenshots/menu-dark.png" width="300" alt="Hush menu, dark mode">
</p>

## Install

1. Download `Hush-x.y.z.dmg` from [Releases](https://github.com/Showdown76py/Hush/releases).
2. Open it and drag Hush into Applications.
3. Open Hush. If macOS blocks it, see [macOS won't open Hush](#macos-wont-open-hush).
4. The welcome screens walk you through the rest: allow the microphone, install the virtual microphone (macOS asks
   for your password once), record a 10-second before/after test, and set up Discord.

### Discord settings

In Discord, open User Settings › Voice & Video:

| Setting | Value |
|---|---|
| Input device | Hush Microphone |
| Echo Cancellation | off |
| Noise Suppression | None |
| Automatic Gain Control | off |

Hush already cleans your voice. If you leave Discord's processing on and your voice gets cleaned twice and sounds worse.
Zoom, Meet and OBS need one setting: pick "Hush Microphone" as the microphone.

<sup><sub>Some apps may have bult-in echo cancellation or noise suppression, so make sure to toggle that off.</sub></sup>

<p align="center"><img src="docs/screenshots/discord-dark.png" width="480" alt="Discord settings diagram"></p>

### macOS won't open Hush

Releases built without an Apple Developer account aren't notarized, so macOS says it "could not verify Hush is
free of malware" on first launch. To open it:

- macOS 15 or later: try to open Hush once, then go to System Settings > Privacy & Security and click Open Anyway.
- macOS 14: Control-click Hush in Applications, choose Open, then Open again.
- Any version, from Terminal:
  ```bash
  xattr -dr com.apple.quarantine /Applications/Hush.app
  ```

You only do this once.

### Uninstall

In Hush, open Settings and click Uninstall Virtual Microphone, then move Hush to the Trash. From Terminal:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/Hush.driver && sudo killall coreaudiod
```

## Using Hush

- **Automatic (default)**: Hush cleans your voice only while an app uses "Hush Microphone", during a call for
  example. The rest of the time your Mac sounds normal.
- **Always on**: the cleanup runs all the time.
- **Off**: Hush passes your microphone through untouched, so you can switch the cleanup off without changing
  microphones in your app.

The menu shows two meters: what your microphone hears and what apps receive. Play music and you'll see the first
one move while the second stays quiet.

Hush also evens out your voice level. It adjusts only while you speak, so loud and soft voices come out at the same
level and background noise never gets boosted. Settings let you pick the source microphone, a fixed voice level,
launch at login, and stronger ducking if you prefer Apple's default.

## FAQ

<details>
<summary>My voice sometimes dips while music plays.</summary>

That's the double-talk suppressor in Apple's voice processing: when you talk over loud speaker sound, it briefly
turns down what it can't separate so no echo gets through. You can't tune it. Turn the speakers down a little or
use headphones.

</details>

<details>
<summary>The music gets a bit quieter while Hush runs.</summary>

macOS lowers other audio whenever voice processing runs. Hush requests the smallest reduction Apple allows, about
8 dB instead of the default 30 dB. We measured it and couldn't go lower (see the [measurements](Prototypes/MEASUREMENTS.md)).
Automatic mode limits this to your calls.

**Note:** It appears that the volume gets quite low when Hush turns on, but your system will slowly make it normal, automatically. (see [Known Limitations](#known-limitations))

</details>

<details>
<summary>My speakers sound different while Hush runs.</summary>

macOS puts the speakers in call mode, like during a FaceTime call. When Hush turns on, the speakers sound quiet for
a few seconds and then settle. The signal Hush lets through drops by 8 dB at once and stays flat (we measured it),
so the slow change comes from the speaker processing. In Automatic mode all of this only happens during calls.

</details>

<details>
<summary>After a call, the speakers stay quiet and slowly come back.</summary>

macOS takes the speakers out of call mode over 30 to 40 seconds. The signal Hush sends is untouched; the slow ramp
happens inside the Mac's speaker processing and no API speeds it up. To get your sound back right away, restart
the audio service (it cuts all sound for a second or two and asks for your password):

```bash
sudo killall coreaudiod
```

Headphones don't have this problem.

</details>

<details>
<summary>Does Hush record me?</summary>

No. Hush processes audio live, in memory. The only recording is the before/after test in the welcome screens, kept
in a local temporary file.

</details>

<details>
<summary>Headphones, AirPods?</summary>

They work. Hush follows output changes on its own.

</details>

<details>
<summary>Is there a delay?</summary>

About 80 ms in total: Apple's processing adds about 65 ms, Hush about 15 ms. People on the other end don't notice it
in conversation.

</details>

## Known limitations

- Other audio drops by about 8 dB while the cleanup runs. This is a macOS limitation, and it can be barely heard.
- The speakers switch to call mode during the cleanup and take 30 to 40 seconds to recover afterwards.
- Added latency is about 80 ms, mostly from Apple's processing.
- While Hush runs, apps that read the built-in microphone directly get a quieter, partly processed signal (about
  -20 dB). Point them at "Hush Microphone" instead.
- The virtual microphone is mono at 48 kHz. Apps convert as needed.
- Hush needs macOS 14 or later.
- Releases carry a stable self-signed
  certificate, so macOS keeps your microphone permission across updates, and Sparkle checks an EdDSA signature on
  every update, as I don't own an Apple Developper Account.

## Measurements

We've done measurements on a MacBook Air (Apple Silicon, macOS 27). Full details, in French, in
[Prototypes/MEASUREMENTS.md](Prototypes/MEASUREMENTS.md).

| | Result |
|---|---|
| Music removed from the microphone | -43.5 dB (median, after about 3 s) |
| Music ducking | -8 dB |
| Total added latency | 80.9 ms, including 14 ms of Hush transport |
| Voice level, soft to loud speech | -20 to -25 dB, peaks at -8 dBFS |
| Mic and driver clock drift | under 1 ppm |

We also prototyped a WebRTC AEC3 engine (`Prototypes/aec3`). It avoids ducking, leaves the speakers alone and adds
only 16.6 ms, but it removes less music (-16 dB without noise suppression) and cuts your voice when you talk over
the music. So we concluded that Apple's voice processing was better in this case.

## For developers

You need Xcode 26 or later (Liquid Glass and the `.icon` app icon) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
scripts/fetch-sparkle.sh          # downloads Sparkle, checks its SHA-256
xcodegen generate                 # rebuilds Hush.xcodeproj from project.yml
open Hush.xcodeproj
```

> [!NOTE]
> If the repository sits in an iCloud Drive folder, keep Xcode's DerivedData in its default location. macOS adds extended attributes to bundles in synced folders and `codesign` rejects them.

### Tests

```bash
# Driver: 2,000 simulated audio cycles under AddressSanitizer and UBSan
clang -O1 -g -fsanitize=address,undefined -std=c11 -I Shared -framework CoreAudio -framework CoreFoundation \
  Driver/Tests/driver_test.c -o build/driver_test && build/driver_test
# App: 23 tests (shared memory, voice level, drift, limiter…)
xcodebuild -scheme Hush test
```

### Driver by hand

```bash
Driver/build.sh                       # builds build/Hush.driver (universal)
sudo scripts/install-driver.sh        # copies it to /Library/Audio/Plug-Ins/HAL and restarts coreaudiod
sudo scripts/uninstall-driver.sh
```

### Releasing

`./scripts/release.sh 1.0.0` builds a universal app (arm64 and x86_64), signs it, and writes the DMG to
`build/release/`. Signing picks, in order:

1. `CODESIGN_IDENTITY="Developer ID Application: …"`: hardened runtime and timestamp. Add
   `NOTARY_PROFILE=<notarytool profile>` to notarize and staple.
2. The "Hush Self-Signed Code Signing" certificate from your keychain (create it once with
   `scripts/create-signing-cert.sh` and back it up).
3. An ad-hoc signature.

With the Sparkle private key in your keychain, or in a file passed as `SPARKLE_KEY_FILE`, the script also writes a
signed `appcast.xml`. The matching public key lives in `project.yml`.

CI builds, tests and produces a DMG on every push. Push a `vX.Y.Z` tag and the Release workflow publishes a GitHub
release with the DMG and the appcast. It reads three repository secrets: `HUSH_SIGNING_P12`,
`HUSH_SIGNING_P12_PASSWORD` and `SPARKLE_PRIVATE_KEY`. Back these keys up. Lose the Sparkle key and existing users
stop receiving updates.

### Architecture

```
App/            SwiftUI menu bar app
  RealTime/     audio callbacks in C: no allocation, no locks, no Swift runtime
  Sources/      engine (VoiceProcessingIO), controller (modes, recovery), installer, UI
Driver/         AudioServerPlugIn in C ("Hush Microphone"), relays audio and nothing else
Shared/         app/driver contract: lock-free single-producer ring buffer in shared memory
Prototypes/     measurement tools and engine experiments (BlackHole, playback relay, AEC3)
scripts/        release, driver install, Sparkle
```

The app writes cleaned audio into a lock-free ring buffer in POSIX shared memory. The driver reads it on each IO
cycle with a safety margin past the client's buffer, and sends silence when the app isn't running. The app restarts
the cleanup on its own after output changes, plugged or unplugged microphones, sample rate changes, sleep, and
coreaudiod restarts. The driver follows the `AudioServerPlugIn.h` documentation and contains no BlackHole (GPL) code.

## License

MIT, see [LICENSE](LICENSE). Hush ships [Sparkle](https://sparkle-project.org) (MIT). The AEC3 prototype uses
[webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) (BSD-3).
