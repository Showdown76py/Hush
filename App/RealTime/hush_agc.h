// Gain automatique piloté par la voix, pour la sortie du voice processing.
//
// Contrairement au gain automatique du VPIO, celui-ci ne bouge que pendant la parole : quand personne
// ne parle, le gain est figé, donc le résidu de musique et le bruit de fond ne sont jamais remontés.
// Traitement par blocs, sans allocation ni verrou (utilisable dans un callback audio).
#ifndef HUSH_AGC_H
#define HUSH_AGC_H

#include <stdint.h>

typedef struct {
    // Réglages
    float targetDB;        // niveau RMS visé pour la parole (par bloc), en dBFS
    float minGainDB;
    float maxGainDB;
    float riseDBPerSec;    // vitesse max de montée du gain
    float fallDBPerSec;    // vitesse max de descente du gain
    float speechMarginDB;  // la parole doit dépasser le bruit de fond d'au moins cette marge
    float sampleRate;

    // État
    float gainDB;          // gain courant
    float floorDB;         // estimation du bruit de fond
    float speechDB;        // niveau de parole lissé
    float lastGain;        // gain linéaire appliqué à la fin du bloc précédent (rampe sans « zipper »)
    int speaking;          // le dernier bloc contenait de la parole
} hush_agc_t;

// Valeurs par défaut ; `initialGainDB` permet de reprendre le gain de la session précédente.
void hush_agc_init(hush_agc_t *agc, float sampleRate, float initialGainDB);

// Applique le gain (et le limiteur doux) au bloc, en place.
void hush_agc_process(hush_agc_t *agc, float *x, uint32_t n);

#endif
