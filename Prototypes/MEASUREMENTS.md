# Mesures — étapes 1 à 3 (20/10/2026)

Machine : MacBook Air (Apple Silicon), macOS 27.0.1, haut-parleurs et micro intégrés, volume 19 % puis 38 %.
Musique : un morceau pop (mp3) joué avec `afplay`.

## Ducking (étape 1)

Mesuré à la **sortie système** avec un tap Core Audio global (`systap`), comparé à un passage de
référence sans voice processing sur le même extrait (`scripts/compare.py`).

| Configuration VPIO | Ducking de la musique | Musique dans le micro (vs brut) |
|---|---|---|
| Défaut Apple | **-30 dB** | -30 dB |
| `duckingLevel=.min`, `enableAdvancedDucking=false` | **-8 dB** | -32 dB |
| idem + ducking avancé | -8 dB | -34 dB |
| idem + sortie VPIO désactivée | -8 dB | -28 dB |
| `kAUVoiceIOProperty_DuckNonVoiceAudio` | refusé (-10879, iOS uniquement) | — |
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

## Atténuation (étapes 2-3)

Micro → VPIO → ring buffer → BlackHole, relu avec ffmpeg, comparé au micro brut sur le même extrait :

- **Musique seule : -43,5 dB** (médiane par seconde après environ 3 s de convergence, entre -32 et -48 dB).
- Fichiers : `results/musique_seule_brut.wav`, `results/musique_seule_nettoyee.wav`.
- Avec la voix : `results/voix_nettoyee.wav`. Le VP applique un AGC fort (voix vers -15 dB RMS, pics à -5 dBFS).

## Latence (étape 3)

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
