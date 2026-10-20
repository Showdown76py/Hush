# Mesures (octobre 2026)

Machine : MacBook Air (Apple Silicon), macOS 27.0.1, haut-parleurs et micro intégrés, volume 19 % puis 38 %.
Musique : un morceau pop (mp3) joué avec `afplay`.

## Ducking

Mesuré à la **sortie système** avec un tap Core Audio global (`systap`), comparé à un passage de
référence sans voice processing sur le même extrait (`scripts/compare.py`).

| Configuration VPIO | Ducking de la musique | Musique dans le micro (vs brut) |
|---|---|---|
| Défaut Apple | **-30 dB** | -30 dB |
| `duckingLevel=.min`, `enableAdvancedDucking=false` | **-8 dB** | -32 dB |
| idem + ducking avancé | -8 dB | -34 dB |
| idem + sortie VPIO désactivée | -8 dB | -28 dB |
| `kAUVoiceIOProperty_DuckNonVoiceAudio` | refusé (-10879, iOS uniquement) | sans objet |
| sortie VPIO dirigée vers BlackHole | 0 dB | -12 dB (pas d'annulation, seulement débruitage) |

Conclusions :
- **-8 dB est le minimum atteignable** avec l'API publique quand le VP annule l'écho des haut-parleurs.
- Le ducking et la référence d'écho visent tous les deux le périphérique de sortie du VPIO.
- Les mesures acoustiques avec le micro intégré en parallèle sont **fausses** quand le VP tourne sur
  ce micro : le flux reçu par les autres clients est environ 25 dB plus bas. Seul le tap système est fiable.
- Le micro de l'iPhone (Continuité) n'est pas exploitable pour mesurer (coupures, niveaux incohérents).

### Expérience « relecture » (abandonnée)

Le tap système coupe les apps et rejoue leur son via la sortie du VPIO (`relay`) : 0 dB de ducking,
mais le VPIO traite sa sortie comme de la voix. Plus rien au-dessus d'environ 12 kHz (-37 → -102 dB
dans la bande 12-16 kHz), EQ modifié, et une annulation moins bonne (-14 dB). C'est inacceptable
pour de la musique.

## Musique retirée du micro

Micro → VPIO → ring buffer → BlackHole, relu avec ffmpeg, comparé au micro brut sur le même extrait :

- **Musique seule : -43,5 dB** (médiane par seconde après environ 3 s de convergence, entre -32 et -48 dB).
- Fichiers : `results/musique_seule_brut.wav`, `results/musique_seule_nettoyee.wav`.
- Avec la voix : `results/voix_nettoyee.wav`. Le VP applique un AGC fort (voix vers -15 dB RMS, pics à -5 dBFS).

## Latence

Mesures par corrélation croisée entre le flux micro intégré et la sortie BlackHole, enregistrés en
parallèle et alignés par horodatage hôte (`dualrec`, `scripts/latency.py`).

| Chemin | Latence ajoutée |
|---|---|
| Transport seul (VP en bypass), ring 768 / buffer BlackHole 256 | 45,0 ms |
| Transport seul, ring 512 / 256 | 41,9 ms |
| Transport seul, ring 256 / 128 | **31,2 ms** (0 underrun) |
| **VP actif + transport 256/128, avec la voix** | **97 ms** (médiane sur 21 fenêtres, 94 à 106 ms) |

Le VP lui-même ajoute donc environ **66 ms** (97 - 31). Le VPIO déclare `kAudioUnitProperty_Latency = 0`,
ce qui est inexploitable.

Réserve : la référence est le flux parallèle du micro intégré, altéré quand le VPIO tourne. Les
passages en bypass et en VP actif l'utilisent de la même façon, donc la différence reste
significative. Une mesure absolue par clics a échoué : dès que le VPIO tourne, le micro capte environ
25 dB plus bas et les clics se perdent dans le bruit.

Base acoustique sans l'app : haut-parleur → micro brut = 33,1 ms (constant).

## Driver HAL

Driver HAL "Hush Microphone" (AudioServerPlugIn en C, signé ad-hoc) + ring buffer en mémoire partagée POSIX.

- **Chargé par coreaudiod en signature ad-hoc** : visible dans Configuration audio et MIDI et dans Réglages Système › Son › Entrée.
- **La mémoire partagée POSIX fonctionne depuis le sandbox du driver** (créée par le driver, ouverte par l'app).
- Dérive d'horloge micro intégré / horloge du driver : **-0,2 ppm** (soit un recalage toutes les 7 h environ, sans correction).
- Remplissage du driver stable sur 3 min avec un vrai client, 0 underrun en régime établi.
- Défaut trouvé avec Discord (client à 1024 frames) : 14 underruns en 7 s → corrigé (marge au-delà du buffer
  client + ré-amorçage). Le test de non-régression reproduit exactement les 14 underruns de l'ancienne logique.

| Transport (VP en bypass) | Latence |
|---|---|
| BlackHole, ring 256, buffer 128 | 31,2 ms |
| Driver Hush, cible 512 | 16,6 ms (0 underrun) |
| Driver Hush, buffer IO 128, marge 256 | **13,8 ms** |
| **VP actif + driver Hush, avec la voix** | **80,9 ms** (médiane sur 29 fenêtres, 71 à 90 ms) |

## Comparaison avec WebRTC AEC3 (prototype `aec3/`)

AEC3 (webrtc-audio-processing 2.1, BSD-3), micro intégré **brut** (sans VPIO), référence = tap Core Audio
de la sortie système, blocs de 10 ms. Musique seule, atténuation médiane après convergence (≥ 5 s) :

| Réglage AEC3 | Atténuation de la musique |
|---|---|
| AEC seul | -17,8 dB |
| AEC + réduction de bruit haute | -28,1 dB |
| AEC + réduction de bruit très haute | -35,3 dB |

| | VP d'Apple | WebRTC AEC3 |
|---|---|---|
| Atténuation de la musique | **-43,5 dB** | -28 à -35 dB (selon la réduction de bruit) |
| Ducking de la musique | -8 dB (plancher macOS) | **0 dB** |
| Son des haut-parleurs | dégradé (mode « appel ») | **intact** |
| Latence ajoutée (pipeline complet + driver) | ~81 ms | **16,6 ms** |
| Convergence | ~3 s | ~5 s |
| CPU | (dans coreaudiod / VPIO) | 6,9 % d'un cœur (0,69 ms par bloc de 10 ms) |
| Permissions | micro | micro + enregistrement audio système (tap) |
| Qualité de la voix en double-talk | très bonne (à l'écoute) | **à évaluer à l'oreille** |

Le rejeu hors ligne (`aec3offline`) d'une prise enregistrée est identique au bit près au traitement en direct :
une seule prise vocale suffit pour comparer tous les réglages.

### AEC3 avec la voix (prise réelle, rejouée hors ligne)

Sur une prise vocale réelle (voix + musique), AEC3 coupe la voix pendant le double-talk : 5 à 7 secondes
sur 14 perdent plus de 10 dB, même sans réduction de bruit. À l'écoute, la voix est « presque inaudible ».
Des préréglages de suppresseur plus transparents (fabrique `EchoCanceller3` personnalisée) ne gagnent qu'à la marge :

| Réglage | Musique retirée | Voix gardée (médiane) | Coupures > 10 dB |
|---|---|---|---|
| Défaut, sans réduction de bruit | -16,8 dB | -6,4 dB | 5/14 |
| Défaut + réduction de bruit haute | -28,1 dB | -9,5 dB | 6/14 |
| « Voix+ », sans réduction de bruit | -15,5 dB | -5,6 dB | 3/14 |
| « Voix+ » + réduction de bruit haute | -25,4 dB | -8,4 dB | 5/14 |

Le filtre linéaire d'AEC3 plafonne à environ 16 dB sur les haut-parleurs (non linéaires) d'un MacBook : le reste ne
peut être retiré qu'en supprimant aussi la voix. **Conclusion : le VP d'Apple reste le moteur de Hush.**

## Remontée lente du volume après l'arrêt du VP

Remarquée à l'oreille, puis mesurée. Le signal envoyé aux haut-parleurs (tap) est plat. Le rapport
acoustique micro/sortie est environ 10 dB plus bas juste après l'arrêt du VP et remonte progressivement en 30 à 40 s
(de -42 à -33 dB). C'est le traitement des haut-parleurs de macOS qui quitte lentement le « mode appel » ; ce n'est
pas réglable par une API publique.

À l'activation, c'est l'inverse : le son paraît faible puis remonte en quelques secondes, alors que le tap montre
une baisse de 8 dB immédiate (creux à -9 dB pendant 1 s) puis parfaitement stable pendant 40 s. Là aussi, la
variation progressive se passe dans le traitement des haut-parleurs.

## Souffle « ventilateur » quand la musique est forte

Remarqué à l'écoute. Micro nettoyé, musique forte, personne ne parle (niveau par seconde) :

| Configuration | Bouffées max | Niveau habituel |
|---|---|---|
| Gain automatique du VPIO (défaut d'Apple) | -25 dB | -50 à -67 dB |
| Gain automatique du VPIO désactivé, sans gain | -52 dB | -63 à -88 dB |
| Gain automatique Hush piloté par la voix (`hush_agc`) | -39 dB (1 s, démarrage du VP) | -55 à -60 dB, stable |

Le gain automatique d'Apple remonte le résidu de suppression quand personne ne parle. Celui de Hush ne bouge que
pendant la parole : le résidu reste environ 35 dB sous le niveau visé pour la voix (-22 dB).

## Crépitements dans la voix

Remarqués à l'écoute. Deux causes, mesurées : (1) la correction de dérive, pilotée par le remplissage du ring, se
déclenchait sur la gigue du client (16 glissements d'un échantillon en 20 s, chacun audible) ; (2) ffmpeg perdait
des morceaux pendant l'enregistrement (18,7 s sur 21). Après correction (estimation par horodatages, rééchantillonnage
du bloc), enregistrement propre avec `dualrec` : 21,0 s exactes, 0 glissement en 40 s, dérive estimée -0,6 ppm,
voix entre -20 et -25 dB par seconde (normal, doux, fort), crête -8,3 dBFS. Crépitements absents à l'écoute.
