#include "hush_agc.h"

#include <math.h>

void hush_agc_init(hush_agc_t *agc, float sampleRate, float initialGainDB) {
    agc->targetDB = -23.0f;   // measured on a real voice: -20 to -25 dB per sec, peaks ~-8 dBFS
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

    // noise floor tracks drops fast and rises slowly so speech doesn't push it up
    if (db < agc->floorDB) agc->floorDB += (db - agc->floorDB) * 0.3f;
    else agc->floorDB += 1.5f * blockSec;   // +1.5 dB/s max

    // speech = well above noise floor AND above an absolute threshold (music residue left by vp stays under it)
    agc->speaking = db > agc->floorDB + agc->speechMarginDB && db > -54.0f;
    if (agc->speaking) {
        // speech level tracks louder voice fast (0.3 s) and quieter voice slower (1 s)
        // so a few residue blocks can't push the gain up
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
    // no speech -> gain frozen

    float g1 = powf(10.0f, agc->gainDB / 20.0f), g0 = agc->lastGain;
    for (uint32_t i = 0; i < n; i++) {
        float g = g0 + (g1 - g0) * (float)(i + 1) / (float)n;
        x[i] = soft_limit(x[i] * g);
    }
    agc->lastGain = g1;
}
