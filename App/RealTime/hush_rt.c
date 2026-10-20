#include "hush_rt.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "hush_agc.h"
#include "hush_shm.h"

#define SCRATCH_FRAMES 8192u

struct hush_rt {
    AudioUnit vpUnit;
    AudioUnit rawUnit;
    _Atomic(hush_shm_t *) shm;
    _Atomic(hush_shm_t *) passShm;
    _Atomic int passBusy;
    _Atomic int driftEnabled;
    _Atomic float gain;          // gain fixe appliqué à la voix traitée (linéaire), si pas de gain automatique
    _Atomic int autoGain;        // gain automatique piloté par la voix (hush_agc)
    _Atomic int agcResetPending; // demande de réinitialisation, appliquée au début du callback suivant
    _Atomic float agcResetGainDB;
    _Atomic float agcGainDB;     // gain automatique courant (pour le mémoriser)
    hush_agc_t agc;              // thread temps réel du VP uniquement

    float *vpScratch;    // SCRATCH_FRAMES + 1 (place pour un échantillon dupliqué)
    float *rawScratch;
    float *driftScratch; // SCRATCH_FRAMES + 1 (bloc rééchantillonné)

    _Atomic float levelClean;
    _Atomic float levelRaw;
    _Atomic uint64_t vpCallbacks;
    _Atomic uint64_t vpErrors;
    _Atomic int32_t lastError;
    _Atomic int64_t driftSlips;

    // Correction de dérive (thread temps réel du VP uniquement)
    hush_drift_t drift;
    _Atomic int driftResetPending;
    double hostTicksPerSecond;

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
    rt->driftScratch = calloc(SCRATCH_FRAMES + 1, sizeof(float));
    rt->record = calloc(HUSH_RT_RECORD_MAX_FRAMES, sizeof(float));
    if (!rt->vpScratch || !rt->rawScratch || !rt->driftScratch || !rt->record) { hush_rt_destroy(rt); return NULL; }
    atomic_store(&rt->driftEnabled, 1);
    atomic_store(&rt->gain, 1.0f);
    atomic_store(&rt->autoGain, 1);
    hush_agc_init(&rt->agc, 48000.0f, 10.0f);
    atomic_store(&rt->agcGainDB, 10.0f);
    hush_drift_reset(&rt->drift);
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    rt->hostTicksPerSecond = 1e9 * (double)tb.denom / (double)tb.numer;
    return rt;
}

void hush_rt_destroy(hush_rt_t *rt) {
    if (!rt) return;
    free(rt->vpScratch);
    free(rt->rawScratch);
    free(rt->driftScratch);
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

void hush_rt_set_gain_db(hush_rt_t *rt, float db) {
    atomic_store(&rt->gain, powf(10.0f, db / 20.0f));
}

void hush_rt_reset_drift(hush_rt_t *rt) { atomic_store_explicit(&rt->driftResetPending, 1, memory_order_release); }
double hush_rt_drift_ppm(const hush_rt_t *rt) { return rt->drift.ppm; }

void hush_rt_set_auto_gain(hush_rt_t *rt, int enabled) { atomic_store(&rt->autoGain, enabled); }

void hush_rt_reset_auto_gain(hush_rt_t *rt, float initialGainDB) {
    atomic_store(&rt->agcResetGainDB, initialGainDB);
    atomic_store_explicit(&rt->agcResetPending, 1, memory_order_release);
}

float hush_rt_auto_gain_db(const hush_rt_t *rt) { return atomic_load(&((hush_rt_t *)rt)->agcGainDB); }

// Gain fixe puis limiteur doux : linéaire jusqu'à 0,9, puis compression progressive vers 1,0.
void hush_rt_apply_gain(float *x, uint32_t n, float gain) {
    const float knee = 0.9f, range = 0.1f;
    for (uint32_t i = 0; i < n; i++) {
        float y = x[i] * gain;
        float a = fabsf(y);
        if (a > knee) y = copysignf(knee + range * tanhf((a - knee) / range), y);
        x[i] = y;
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

// Rééchantillonne linéairement un bloc de n échantillons en m (m = n ± 1), en conservant exactement
// le premier et le dernier échantillon : aucune discontinuité aux bords du bloc.
void hush_rt_resample_linear(const float *src, uint32_t n, float *dst, uint32_t m) {
    if (n == 0 || m == 0) return;
    if (n == 1 || m == 1) { for (uint32_t i = 0; i < m; i++) dst[i] = src[0]; return; }
    double step = (double)(n - 1) / (double)(m - 1);
    for (uint32_t i = 0; i < m; i++) {
        double pos = i * step;
        uint32_t k = (uint32_t)pos;
        if (k >= n - 1) { dst[i] = src[n - 1]; continue; }
        float frac = (float)(pos - k);
        dst[i] = src[k] + (src[k + 1] - src[k]) * frac;
    }
}

void hush_drift_reset(hush_drift_t *d) {
    memset(d, 0, sizeof(*d));
}

// La pente (secondes par frame) est estimée par régression sur tous les horodatages depuis le début,
// ce qui moyenne leur gigue : quelques ppm de précision après 10 s, bien mieux ensuite.
int hush_drift_update(hush_drift_t *d, uint64_t hostTime, uint32_t frames, double hostTicksPerSecond) {
    if (d->firstHost == 0 || hostTime < d->firstHost) {
        hush_drift_reset(d);
        d->firstHost = hostTime;
    }
    double x = d->frames, y = (double)(hostTime - d->firstHost) / hostTicksPerSecond;
    d->frames += frames;
    d->n += 1;
    double dx = x - d->meanX;
    d->meanX += dx / d->n;
    d->meanY += (y - d->meanY) / d->n;
    d->cxy += dx * (y - d->meanY);
    d->cxx += dx * (x - d->meanX);
    if (y < 10.0 || d->cxx <= 0) return 0;   // estimation encore imprécise
    double rate = d->cxx / d->cxy;            // frames par seconde
    double ppm = (rate / 48000.0 - 1.0) * 1e6;
    if (ppm > 1000.0) ppm = 1000.0;           // horodatages aberrants : on borne
    if (ppm < -1000.0) ppm = -1000.0;
    d->ppm = ppm;
    if (fabs(ppm) < 1.0) return 0;            // horloges verrouillées : rien à corriger
    d->accumulator += (double)frames * ppm * 1e-6;
    if (d->accumulator >= 1.0) { d->accumulator -= 1.0; return -1; }
    if (d->accumulator <= -1.0) { d->accumulator += 1.0; return 1; }
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
    if (atomic_exchange_explicit(&rt->driftResetPending, 0, memory_order_acquire)) hush_drift_reset(&rt->drift);
    if (atomic_exchange_explicit(&rt->agcResetPending, 0, memory_order_acquire))
        hush_agc_init(&rt->agc, 48000.0f, atomic_load_explicit(&rt->agcResetGainDB, memory_order_relaxed));
    if (atomic_load_explicit(&rt->autoGain, memory_order_relaxed)) {
        hush_agc_process(&rt->agc, rt->vpScratch, frames);
        atomic_store_explicit(&rt->agcGainDB, rt->agc.gainDB, memory_order_relaxed);
    } else {
        float gain = atomic_load_explicit(&rt->gain, memory_order_relaxed);
        if (gain != 1.0f) hush_rt_apply_gain(rt->vpScratch, frames, gain);
    }
    atomic_store_explicit(&rt->levelClean, rms(rt->vpScratch, frames), memory_order_relaxed);
    record_push(rt, 0, rt->vpScratch, frames);

    hush_shm_t *s = atomic_load_explicit(&rt->shm, memory_order_acquire);
    if (s) {
        UInt32 n = frames;
        const float *out = rt->vpScratch;
        if (atomic_load_explicit(&rt->driftEnabled, memory_order_relaxed)) {
            int d = hush_drift_update(&rt->drift, ts->mHostTime, frames, rt->hostTicksPerSecond);
            if (d != 0 && n > 2) {
                // Bloc rééchantillonné en n ± 1 échantillons (variation de hauteur ≈ 1/n, inaudible),
                // au lieu de retirer ou dupliquer un échantillon sec, qui ferait un clic.
                uint32_t m = d < 0 ? n - 1 : n + 1;
                hush_rt_resample_linear(rt->vpScratch, n, rt->driftScratch, m);
                out = rt->driftScratch;
                n = m;
                atomic_fetch_add_explicit(&rt->driftSlips, d < 0 ? 1 : -1, memory_order_relaxed);
            }
        }
        hush_app_write(s, out, n, mach_absolute_time());
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
