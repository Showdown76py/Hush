# Notes de développement

Hush est une app de barre de menus macOS (14+) qui applique le traitement de la voix d'Apple
(`kAudioUnitSubType_VoiceProcessingIO`, le même que FaceTime) au micro, puis expose le résultat via un micro
virtuel « Hush Microphone » (driver HAL maison) utilisable dans Discord, Zoom, Meet, OBS…
Langue du projet : commentaires et messages de commit en français, interface en anglais (source) + français.

Les chiffres détaillés de toutes les expériences sont dans `Prototypes/MEASUREMENTS.md`.

## Structure

```
App/RealTime/     callbacks audio en C (hush_rt.c) : aucune allocation, aucun verrou, aucun runtime Swift
App/Sources/      Engine/ (VoiceEngine, EngineController, DriverInstaller, SharedMemory…) + UI/ (SwiftUI)
App/AppIcon.icon  icône Liquid Glass en couches (Icon Composer), validable avec ictool
Driver/           AudioServerPlugIn en C (HushDriver.c) + Tests/driver_test.c (banc de test sans coreaudiod)
Shared/           contrat app ↔ driver : ring.h (SPSC lock-free), hush_shm.h, hush_app.h
Prototypes/       paquet SwiftPM d'outils de mesure + prototypes (voir plus bas) ; aec3/ = prototype WebRTC
scripts/          release.sh, fetch-sparkle.sh, install/uninstall-driver.sh, create-signing-cert.sh
project.yml       source de vérité du projet Xcode (XcodeGen) ; Hush.xcodeproj est généré ET committé
```

## Commandes

```bash
scripts/fetch-sparkle.sh && xcodegen generate          # après chaque modif de project.yml : regénérer et committer
xcodebuild -scheme Hush -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Hush-cli build
xcodebuild -scheme Hush -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Hush-cli test   # 17 tests
clang -O1 -g -fsanitize=address,undefined -std=c11 -Wall -Werror -I Shared -framework CoreAudio \
  -framework CoreFoundation Driver/Tests/driver_test.c -o build/driver_test && build/driver_test
./scripts/release.sh [version]                          # DMG universel dans build/release/
.../Hush.app/Contents/MacOS/Hush --render-screenshots <dir>   # captures (fenêtres réellement affichées)
cd Prototypes && swift build                            # outils : vpcapture, vp2out, dualrec, systap, enginecheck, whoaudio…
sudo scripts/install-driver.sh                          # installer le driver à la main (mot de passe admin)
```

## Pièges de l'environnement de développement

- **Le dépôt est dans `~/Documents`, géré par un File Provider (iCloud Drive)**. macOS y ajoute des attributs
  étendus (`com.apple.FinderInfo`, `com.apple.fileprovider.fpfs#P`) aux bundles, que `codesign` refuse
  (« resource fork, Finder information, or similar detritus not allowed »). D'où : DerivedData hors du dépôt,
  Sparkle extrait dans `~/Library/Caches/io.github.showdown76py.Hush` (Vendor/Sparkle = lien symbolique),
  `release.sh` signe dans un dossier temporaire et ne copie que le DMG dans `build/release`.
- **xcodebuild se bloque sur le téléchargement des binaires SwiftPM** (« Resolve Package Graph », sans activité
  réseau), alors que `curl` fonctionne. Sparkle est donc vendoré via `scripts/fetch-sparkle.sh` (SHA-256 épinglé).
- **`brew install abseil` met aussi à jour les paquets qui en dépendent (protobuf, mysql…)**. Utiliser
  `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1` pour installer des outils sans effet de bord.
- Toute réinstallation du driver demande un mot de passe administrateur : regrouper les changements du driver.

## Ce qui marche (décisions validées)

- **Moteur : VoiceProcessingIO d'Apple**, via l'audio unit directement (pas AVAudioEngine). -43,5 dB de musique
  retirée, voix jugée très bonne à l'écoute.
- **Ducking réglé au minimum** (`kAUVoiceIOProperty_OtherAudioDuckingConfiguration`, `.min`, advanced = false) :
  -8 dB, c'est le plancher de macOS. Option « Lower other sounds… » = niveau Apple par défaut (-30 dB).
- **Driver HAL maison** (pas de code BlackHole, licence GPL) : mono 48 kHz Float32, horloge sur l'heure hôte,
  lit un ring buffer en mémoire partagée POSIX `/hush.mic.v1`. La signature ad-hoc suffit pour coreaudiod, et
  la mémoire partagée POSIX fonctionne depuis le sandbox du driver. Latence visée = buffer du client + marge
  (`targetFill`), ré-amorçage après un trou. Silence si l'app ne tourne pas (heartbeat périmé).
- **Transport** : 13,8 à 16,6 ms (contre 31 ms via BlackHole). Total avec le VP : environ 81 ms, dont environ
  66 ms dus au VP d'Apple (non réglable).
- **Modes** : Automatique (le VP ne tourne que si `clientsRunning` > 0 dans la mémoire partagée, avec 3 s
  d'hystérésis), Toujours actif, Désactivé = **passage direct** du micro brut vers Hush Microphone (seulement
  quand une app écoute, sinon l'indicateur orange resterait allumé). Un seul producteur dans le ring à la fois :
  `hush_rt_set_passthrough(NULL)` attend la fin du callback en cours (compteur `passBusy`).
- **Niveau de la voix** : le gain automatique du VPIO (`kAUVoiceIOProperty_VoiceProcessingEnableAGC`) est
  **désactivé**, car il remonte le résidu de suppression quand la musique est forte (souffle « ventilateur »,
  bouffées jusqu'à -25 dB). Il est remplacé par `hush_agc` : gain piloté par la voix (détection = 12 dB au-dessus
  du bruit de fond suivi ET au-dessus de -54 dBFS), cible -23 dB par bloc de parole (mesuré sur une vraie voix : environ -23 dB par seconde, crêtes vers -4 dBFS), montée
  10 dB/s et descente 40 dB/s **uniquement pendant la parole**, gain figé sinon, limiteur doux, gain mémorisé
  entre les appels. Réglage « Voice level » : Automatique (défaut) ou gain fixe. Tests synthétiques dans
  `HushTests` (voix faible/forte, résidu jamais remonté, bruit seul, cri, changement de locuteur).
- **Correction de dérive** par glissement d'un échantillon, au plus tous les 32 callbacks. La dérive mesurée avec le
  micro intégré est de -0,2 ppm, donc elle sert surtout pour les micros USB.
- **Test avant/après de l'onboarding** : 5 s avec Hush (VP déjà convergé) **puis** 5 s sans, et non en simultané.
- **Signature** : `release.sh` choisit Developer ID (`CODESIGN_IDENTITY`) > certificat auto-signé
  « Hush Self-Signed Code Signing » (trousseau, créé par `scripts/create-signing-cert.sh`, sauvegardé dans
  `~/Library/Application Support/Hush-signing/`) > ad-hoc. Le certificat donne une exigence de signature stable,
  donc l'autorisation micro (TCC) survit aux mises à jour ; en ad-hoc, elle est perdue à chaque build. Le driver
  reste toujours en ad-hoc. Hardened runtime seulement en Developer ID (sinon la validation des bibliothèques
  bloque Sparkle).
- **Permission micro** : si `AVCaptureDevice.authorizationStatus == .notDetermined`, l'app la redemande d'elle-même
  (cas d'une app remplacée avec une nouvelle signature).
- **Mises à jour Sparkle** : clé publique EdDSA dans `project.yml` ; clé privée dans le trousseau du mainteneur
  (sauvegarde dans `~/Library/Application Support/Hush-signing/`) et dans le secret `SPARKLE_PRIVATE_KEY`.
  Le workflow Release publie le DMG et `appcast.xml` ; l'app lit `releases/latest/download/appcast.xml`.
- **Liquid Glass** : `hushGlass` / `hushGlassButton` dans `GlassCompat.swift` (macOS 26+, repli matériaux sur 14 et 15).

## Ce qui a été tenté et NE marche PAS (ne pas recommencer sans raison nouvelle)

| Tentative | Résultat |
|---|---|
| `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)` | échoue (-10875 à l'init du nœud de sortie) sur macOS 27 → AU VPIO directe |
| Supprimer complètement le ducking (ducking avancé, `DuckNonVoiceAudio`=2102, sortie VPIO coupée ou en sourdine) | toujours -8 dB ; 2102 = iOS uniquement (-10879) ; MuteOutput coupe aussi le micro |
| Diriger la sortie du VPIO vers BlackHole pour éviter le ducking | 0 dB de ducking mais l'annulation tombe à -12 dB : référence d'écho = périphérique de sortie du VPIO |
| « Relecture » : tap système qui coupe les apps et rejoue leur son via la sortie du VPIO | 0 dB de ducking mais le VPIO traite la sortie comme une voix (coupure > 12 kHz, EQ) : musique dégradée, inacceptable |
| Mesurer au micro intégré pendant que le VP tourne | faux : les autres clients du même micro reçoivent un flux environ 17 à 25 dB plus bas, partiellement traité. Mesurer le ducking avec le tap système (`systap`) |
| Micro de l'iPhone (Continuité) comme oreille indépendante | inutilisable : coupures, silence numérique, déconnexions |
| Latence par injection de voix de synthèse via BlackHole comme entrée du VP | le VP écrase le signal injecté |
| Latence absolue par clics sur les haut-parleurs | clics noyés : le micro est environ 25 dB plus bas dès que le VPIO tourne |
| `kAudioUnitProperty_Latency` du VPIO | renvoie 0, inexploitable |
| Buffers IO de 128 frames / cible du ring de 128 | gain marginal ; la granularité du VPIO domine |
| **WebRTC AEC3** (webrtc-audio-processing 2.1 + tap système comme référence, `Prototypes/aec3`) | 0 ducking, haut-parleurs intacts, 16,6 ms de latence, MAIS -16 dB seulement par soustraction (haut-parleurs MacBook non linéaires) ; le reste coupe la voix en double-talk (« presque inaudible » à l'écoute). Préréglages de suppresseur (fabrique `EchoCanceller3` maison) : gain marginal. **Abandonné.** |
| Accélérer la remontée du volume après l'arrêt du VP | le signal envoyé est plat ; le son émis est environ 10 dB plus bas et remonte en 30 à 40 s (traitement des haut-parleurs qui quitte le « mode appel »). Le `VPAUAggregateAudioDevice` disparaît instantanément. Rien trouvé en ligne à part `sudo killall coreaudiod`. Documenté dans la FAQ ; l'hystérésis du mode automatique reste à 3 s |
| Gain automatique du VPIO (par défaut) | remonte le résidu quand la musique est forte : souffle « ventilateur » audible → désactivé, remplacé par `hush_agc` |
| `ImageRenderer` / `cacheDisplay` pour les captures | ne dessinent ni les contrôles AppKit ni Liquid Glass → vraie fenêtre + `screencapture -l` (la fenêtre reste inactive, donc le verre est désaturé) |

## Outils de mesure (Prototypes/)

- `systap` : enregistre la sortie système (tap Core Audio global) ou un processus (`--pid`). Seule mesure fiable du ducking.
- `dualrec` : deux entrées alignées par horodatage hôte ; `scripts/latency.py` : latence par corrélation croisée.
- `enginecheck` : fait tourner le vrai moteur de l'app hors de l'app (`--switch`, `--duck-release`, `--aggregates`).
- `whoaudio` : processus qui utilisent l'entrée ou la sortie audio (`kAudioHardwarePropertyProcessObjectList`).
- `scripts/compare.py`, `levels.py`, `spectrum.py`, `clicklat.py` : analyses (ffmpeg + numpy).

## Conventions

- Temps réel : tout ce qui tourne dans un callback audio est en C, avec des tampons pré-alloués et des atomiques C11.
  Swift voit la mémoire partagée comme un pointeur opaque (helpers `hush_app_*`, car `shm_open` est variadique).
- Messages d'erreur : `HushError` (titre + conseil humains) ; jamais de code Core Audio affiché.
- Toute nouvelle chaîne d'interface va dans `App/Resources/Localizable.xcstrings`, avec sa traduction française.
- Le driver doit rester simple : pas de logique métier, la politique (latence, modes) est décidée par l'app.

## En suspens

- Vérifier que l'autorisation micro survit à une mise à jour avec le certificat auto-signé (non encore testé).
- Tester Developer ID + notarisation (pas de compte pour l'instant).
- Première release (`git tag v0.1.0 && git push --tags`) puis vérifier une mise à jour Sparkle de bout en bout.
