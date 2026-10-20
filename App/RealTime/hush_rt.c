#include "hush_rt.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "hush_shm.h"

#define SCRATCH_FRAMES 8192u

struct hush_rt {
    AudioUnit vpUnit;
    AudioUnit rawUnit;
    _Atomic(hush_shm_t *) shm;
    _Atomic(hush_shm_t *) passShm;
    _Atomic int passBusy;
    _Atomic int driftEnabled;

    float *vpScratch;    // SCRATCH_FRAMES + 1 (place pour un échantillon dupliqué)
    float *rawScratch;

    _Atomic float levelClean;
    _Atomic float levelRaw;
    _Atomic uint64_t vpCallbacks;
    _Atomic uint64_t vpErrors;
    _Atomic int32_t lastError;
    _Atomic int64_t driftSlips;

    // Correction de dérive (thread temps réel du VP uniquement)
    hush_shm_t *driftShm;
    uint64_t driftUnderruns;
    uint32_t driftClients;
    uint32_t driftCallbacks;
    uint32_t driftSinceSlip;
    double driftAvg;
    double driftBaseline;   // < 0 : pas encore établie

    // Enregistrement
    float *record;
    _Atomic uint32_t recordWanted;
    _Atomic uint32_t recordCount;
    _Atomic int recordSource;
};

hush_rt_t *hush_rt_create(void) {
    hush_rt_t *rt = calloc(1, sizeof(*rt));
    if (!rt) return NULL;
    rt->vpScratch = calloc(SCRATCH_FRAMES + 1, sizeof(float));
    rt->rawScratch = calloc(SCRATCH_FRAMES, sizeof(float));
    rt->record = calloc(HUSH_RT_RECORD_MAX_FRAMES, sizeof(float));
    if (!rt->vpScratch || !rt->rawScratch || !rt->record) { hush_rt_destroy(rt); return NULL; }
    atomic_store(&rt->driftEnabled, 1);
    rt->driftBaseline = -1;
    return rt;
}

void hush_rt_destroy(hush_rt_t *rt) {
    if (!rt) return;
    free(rt->vpScratch);
    free(rt->rawScratch);
    free(rt->record);
    free(rt);
}

void hush_rt_set_vp_unit(hush_rt_t *rt, AudioUnit unit) { rt->vpUnit = unit; }
void hush_rt_set_raw_unit(hush_rt_t *rt, AudioUnit unit) { rt->rawUnit = unit; }
void hush_rt_set_shm(hush_rt_t *rt, void *shm) { atomic_store(&rt->shm, (hush_shm_t *)shm); }
void hush_rt_set_passthrough(hush_rt_t *rt, void *shm) {
    atomic_store(&rt->passShm, (hush_shm_t *)shm);
    if (shm == NULL) {
        // Attend qu'aucun callback ne soit en train d'écrire avec l'ancien pointeur.
        while (atomic_load(&rt->passBusy) != 0) usleep(100);
    }
}

void hush_rt_set_drift_correction(hush_rt_t *rt, int enabled) { atomic_store(&rt->driftEnabled, enabled); }

static float rms(const float *x, UInt32 n) {
    float acc = 0;
    for (UInt32 i = 0; i < n; i++) acc += x[i] * x[i];
    return n ? sqrtf(acc / (float)n) : 0;
}

static void record_push(hush_rt_t *rt, int source, const float *x, UInt32 n) {
    if (atomic_load_explicit(&rt->recordSource, memory_order_relaxed) != source) return;
    uint32_t wanted = atomic_load_explicit(&rt->recordWanted, memory_order_acquire);
    uint32_t count = atomic_load_explicit(&rt->recordCount, memory_order_relaxed);
    if (count >= wanted) return;
    uint32_t k = wanted - count < n ? wanted - count : n;
    memcpy(rt->record + count, x, k * sizeof(float));
    atomic_store_explicit(&rt->recordCount, count + k, memory_order_release);
}

// Retourne -1 pour retirer un échantillon, +1 pour en dupliquer un, 0 sinon.
// Principe : on mémorise le remplissage moyen du ring côté driver une fois le régime établi, puis on
// le maintient en glissant un échantillon de temps en temps (au plus un toutes les 32 callbacks).
static int drift_decision(hush_rt_t *rt, hush_shm_t *s) {
    uint32_t clients = atomic_load_explicit(&s->clientsRunning, memory_order_relaxed);
    uint64_t underruns = atomic_load_explicit(&s->underruns, memory_order_relaxed);
    if (s != rt->driftShm || clients != rt->driftClients || underruns != rt->driftUnderruns || clients == 0) {
        rt->driftShm = s;
        rt->driftClients = clients;
        rt->driftUnderruns = underruns;
        rt->driftCallbacks = 0;
        rt->driftBaseline = -1;
        return 0;
    }
    double fill = (double)atomic_load_explicit(&s->lastFill, memory_order_relaxed);
    if (rt->driftCallbacks == 0) rt->driftAvg = fill;
    rt->driftAvg += (fill - rt->driftAvg) / 256.0;
    rt->driftCallbacks++;
    rt->driftSinceSlip++;
    if (rt->driftBaseline < 0) {
        if (rt->driftCallbacks >= 1000) rt->driftBaseline = rt->driftAvg;   // ~2,7 s à 128 frames
        return 0;
    }
    if (rt->driftSinceSlip < 32) return 0;
    double delta = rt->driftAvg - rt->driftBaseline;
    if (delta > 64) { rt->driftSinceSlip = 0; return -1; }
    if (delta < -64) { rt->driftSinceSlip = 0; return 1; }
    return 0;
}

OSStatus hush_rt_vp_input(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)data;
    hush_rt_t *rt = refCon;
    if (frames > SCRATCH_FRAMES) frames = SCRATCH_FRAMES;
    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = 1;
    abl.mBuffers[0].mDataByteSize = frames * sizeof(float);
    abl.mBuffers[0].mData = rt->vpScratch;
    OSStatus err = AudioUnitRender(rt->vpUnit, flags, ts, bus, frames, &abl);
    atomic_fetch_add_explicit(&rt->vpCallbacks, 1, memory_order_relaxed);
    if (err != noErr) {
        atomic_fetch_add_explicit(&rt->vpErrors, 1, memory_order_relaxed);
        atomic_store_explicit(&rt->lastError, err, memory_order_relaxed);
        return err;
    }
    atomic_store_explicit(&rt->levelClean, rms(rt->vpScratch, frames), memory_order_relaxed);
    record_push(rt, 0, rt->vpScratch, frames);

    hush_shm_t *s = atomic_load_explicit(&rt->shm, memory_order_acquire);
    if (s) {
        UInt32 n = frames;
        if (atomic_load_explicit(&rt->driftEnabled, memory_order_relaxed)) {
            int d = drift_decision(rt, s);
            if (d < 0 && n > 1) {
                n -= 1;                                             // on retire le dernier échantillon
                atomic_fetch_add_explicit(&rt->driftSlips, 1, memory_order_relaxed);
            } else if (d > 0) {
                rt->vpScratch[n] = rt->vpScratch[n - 1];            // on duplique le dernier échantillon
                n += 1;
                atomic_fetch_sub_explicit(&rt->driftSlips, 1, memory_order_relaxed);
            }
        }
        hush_app_write(s, rt->vpScratch, n, mach_absolute_time());
    }
    return noErr;
}

OSStatus hush_rt_silence_output(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                                UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)refCon; (void)ts; (void)bus; (void)frames;
    if (!data) return noErr;
    for (UInt32 i = 0; i < data->mNumberBuffers; i++) memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
    *flags |= kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
}

OSStatus hush_rt_raw_input(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                           UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)data;
    hush_rt_t *rt = refCon;
    if (frames > SCRATCH_FRAMES) frames = SCRATCH_FRAMES;
    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = 1;
    abl.mBuffers[0].mDataByteSize = frames * sizeof(float);
    abl.mBuffers[0].mData = rt->rawScratch;
    OSStatus err = AudioUnitRender(rt->rawUnit, flags, ts, bus, frames, &abl);
    if (err != noErr) return err;
    atomic_store_explicit(&rt->levelRaw, rms(rt->rawScratch, frames), memory_order_relaxed);
    record_push(rt, 1, rt->rawScratch, frames);
    atomic_fetch_add(&rt->passBusy, 1);              // avant de lire le pointeur (voir hush_rt_set_passthrough)
    hush_shm_t *pass = atomic_load(&rt->passShm);
    if (pass) hush_app_write(pass, rt->rawScratch, frames, mach_absolute_time());
    atomic_fetch_sub(&rt->passBusy, 1);
    return noErr;
}

float hush_rt_level_clean(const hush_rt_t *rt) { return atomic_load_explicit(&((hush_rt_t *)rt)->levelClean, memory_order_relaxed); }
float hush_rt_level_raw(const hush_rt_t *rt) { return atomic_load_explicit(&((hush_rt_t *)rt)->levelRaw, memory_order_relaxed); }
uint64_t hush_rt_vp_callbacks(const hush_rt_t *rt) { return atomic_load(&((hush_rt_t *)rt)->vpCallbacks); }
uint64_t hush_rt_vp_errors(const hush_rt_t *rt) { return atomic_load(&((hush_rt_t *)rt)->vpErrors); }
int32_t hush_rt_last_error(const hush_rt_t *rt) { return atomic_load(&((hush_rt_t *)rt)->lastError); }
int64_t hush_rt_drift_slips(const hush_rt_t *rt) { return atomic_load(&((hush_rt_t *)rt)->driftSlips); }

void hush_rt_record_start(hush_rt_t *rt, int source, uint32_t frames) {
    if (frames > HUSH_RT_RECORD_MAX_FRAMES) frames = HUSH_RT_RECORD_MAX_FRAMES;
    atomic_store(&rt->recordWanted, 0);
    atomic_store(&rt->recordCount, 0);
    atomic_store(&rt->recordSource, source);
    atomic_store_explicit(&rt->recordWanted, frames, memory_order_release);
}
uint32_t hush_rt_record_progress(const hush_rt_t *rt) { return atomic_load(&((hush_rt_t *)rt)->recordCount); }
int hush_rt_record_done(const hush_rt_t *rt) {
    hush_rt_t *r = (hush_rt_t *)rt;
    uint32_t w = atomic_load(&r->recordWanted);
    return w > 0 && atomic_load(&r->recordCount) >= w;
}
const float *hush_rt_record_buffer(const hush_rt_t *rt) { return rt->record; }
