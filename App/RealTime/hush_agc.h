// voice driven auto gain for vp output
//
// unlike VPIO's AGC this only moves during speech. nobody talking -> gain frozen
// so music residue and noise floor never get boosted
// block based, no alloc no lock (safe in an audio callback)
#ifndef HUSH_AGC_H
#define HUSH_AGC_H

#include <stdint.h>

typedef struct {
    float targetDB;        // target speech RMS (per block), dBFS
    float minGainDB;
    float maxGainDB;
    float riseDBPerSec;
    float fallDBPerSec;
    float speechMarginDB;  // speech must beat noise floor by at least this
    float sampleRate;

    float gainDB;
    float floorDB;         // noise floor estimate
    float speechDB;        // smoothed speech level
    float lastGain;        // linear gain at end of previous block (ramp, no zipper noise)
    int speaking;          // last block had speech
} hush_agc_t;

// `initialGainDB` restores previous session gain (clamped to [minGainDB, maxGainDB])
void hush_agc_init(hush_agc_t *agc, float sampleRate, float initialGainDB);

// applies gain (and soft limiter) to the block in place
void hush_agc_process(hush_agc_t *agc, float *x, uint32_t n);

#endif
