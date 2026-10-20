#include "hush_agc.h"

#include <math.h>

void hush_agc_init(hush_agc_t *agc, float sampleRate, float initialGainDB) {
    agc->targetDB = -23.0f;   // par bloc de parole : environ -23 dB par seconde de vraie parole, crêtes vers -4 dBFS
    agc->minGainDB = -6.0f;
    agc->maxGainDB = 24.0f;
    agc->riseDBPerSec = 10.0f;
    agc->fallDBPerSec = 40.0f;
    agc->speechMarginDB = 12.0f;
    agc->sampleRate = sampleRate;
    if (initialGainDB < agc->minGainDB) initialGainDB = agc->minGainDB;
    if (initialGainDB > agc->maxGainDB) initialGainDB = agc->maxGainDB;
    agc->gainDB = initialGainDB;
    agc->floorDB = -70.0f;
    agc->speechDB = agc->targetDB - initialGainDB;
    agc->lastGain = powf(10.0f, initialGainDB / 20.0f);
    agc->speaking = 0;
}

static float soft_limit(float y) {
    const float knee = 0.9f, range = 0.1f;
    float a = fabsf(y);
    return a > knee ? copysignf(knee + range * tanhf((a - knee) / range), y) : y;
}

void hush_agc_process(hush_agc_t *agc, float *x, uint32_t n) {
    if (n == 0) return;
    float sum = 0;
    for (uint32_t i = 0; i < n; i++) sum += x[i] * x[i];
    float db = 10.0f * log10f(sum / (float)n + 1e-12f);
    float blockSec = (float)n / agc->sampleRate;

    // Bruit de fond : suit vite les baisses, remonte lentement (la parole ne le fait pas grimper).
    if (db < agc->floorDB) agc->floorDB += (db - agc->floorDB) * 0.3f;
    else agc->floorDB += 1.5f * blockSec;   // +1,5 dB/s au plus

    // Parole : nettement au-dessus du bruit de fond ET d'un seuil absolu (le résidu de musique laissé par
    // le voice processing reste en dessous).
    agc->speaking = db > agc->floorDB + agc->speechMarginDB && db > -54.0f;
    if (agc->speaking) {
        // Niveau de parole : suit vite une voix plus forte (0,3 s), plus lentement une voix plus faible (1 s),
        // pour que quelques blocs de résidu ne fassent pas grimper le gain.
        float tau = db > agc->speechDB ? 0.3f : 1.0f;
        agc->speechDB += (db - agc->speechDB) * blockSec / (tau + blockSec);
        float want = agc->targetDB - agc->speechDB;
        if (want > agc->maxGainDB) want = agc->maxGainDB;
        if (want < agc->minGainDB) want = agc->minGainDB;
        float step = want - agc->gainDB;
        float up = agc->riseDBPerSec * blockSec, down = agc->fallDBPerSec * blockSec;
        if (step > up) step = up;
        if (step < -down) step = -down;
        agc->gainDB += step;
    }
    // Hors parole : gain figé.

    // Rampe linéaire du gain sur le bloc, puis limiteur doux.
    float g1 = powf(10.0f, agc->gainDB / 20.0f), g0 = agc->lastGain;
    for (uint32_t i = 0; i < n; i++) {
        float g = g0 + (g1 - g0) * (float)(i + 1) / (float)n;
        x[i] = soft_limit(x[i] * g);
    }
    agc->lastGain = g1;
}
