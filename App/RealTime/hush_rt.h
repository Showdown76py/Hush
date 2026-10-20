// Hush app realtime part in C. audio callbacks w/ no alloc no lock no Swift runtime
// Swift side sets up the audio units and reads state through these
#ifndef HUSH_RT_H
#define HUSH_RT_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

typedef struct hush_rt hush_rt_t;

hush_rt_t *_Nullable hush_rt_create(void);
void hush_rt_destroy(hush_rt_t *rt);

// config (not rt, units stopped)
void hush_rt_set_vp_unit(hush_rt_t *rt, AudioUnit _Nullable unit);
void hush_rt_set_raw_unit(hush_rt_t *rt, AudioUnit _Nullable unit);
// shm w/ the driver (NULL = no output). can be swapped live
void hush_rt_set_shm(hush_rt_t *rt, void *_Nullable shm);
// passthrough. when `shm` isn't NULL the raw mic ("raw" unit) goes straight into shm
// never enable while vp is writing (single producer)
// disabling waits for any in-flight callback to finish
void hush_rt_set_passthrough(hush_rt_t *rt, void *_Nullable shm);
// processed voice level, replaces vp's own AGC (disabled)
// default is voice driven auto gain (hush_agc.h), else fixed dB gain w/ soft limiter
// all changeable live
void hush_rt_set_auto_gain(hush_rt_t *rt, int enabled);
void hush_rt_reset_auto_gain(hush_rt_t *rt, float initialGainDB);   // picked up on next callback
float hush_rt_auto_gain_db(const hush_rt_t *rt);
void hush_rt_set_gain_db(hush_rt_t *rt, float db);
void hush_rt_apply_gain(float *x, uint32_t n, float gain);
// mic clock drift estimated from its timestamps (driver follows host clock at exactly 48 kHz)
// hush_drift_update returns -1 (drop a sample), +1 (add one) or 0, at the drift rate
typedef struct {
    uint64_t firstHost;
    double frames;               // frames produced before current timestamp
    double n, meanX, meanY, cxy, cxx;   // online linear regression (Welford) secs ~ frames
    double ppm;                  // estimated drift (positive = mic faster than 48 kHz)
    double accumulator;          // accumulated excess frames
} hush_drift_t;
void hush_drift_reset(hush_drift_t *d);
int hush_drift_update(hush_drift_t *d, uint64_t hostTime, uint32_t frames, double hostTicksPerSecond);

// linear resample of an n sample block to m. first and last kept exactly
// so no discontinuity at block edges
void hush_rt_resample_linear(const float *src, uint32_t n, float *dst, uint32_t m);
// on by default
void hush_rt_set_drift_correction(hush_rt_t *rt, int enabled);
void hush_rt_reset_drift(hush_rt_t *rt);              // on every vp (re)start
double hush_rt_drift_ppm(const hush_rt_t *rt);        // diagnostics (unsynchronized read)

// same signatures as AURenderCallback incl nullability so Swift can pass them
OSStatus hush_rt_vp_input(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data);
OSStatus hush_rt_silence_output(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                                UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data);
OSStatus hush_rt_raw_input(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                           UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data);

// linear RMS of last block (0..1)
float hush_rt_level_clean(const hush_rt_t *rt);
float hush_rt_level_raw(const hush_rt_t *rt);
uint64_t hush_rt_vp_callbacks(const hush_rt_t *rt);
uint64_t hush_rt_vp_errors(const hush_rt_t *rt);
int32_t hush_rt_last_error(const hush_rt_t *rt);
int64_t hush_rt_drift_slips(const hush_rt_t *rt);   // >0 samples dropped, <0 duplicated

// recording for the before/after test (preallocated buffers, 12 s max per source)
#define HUSH_RT_RECORD_MAX_FRAMES (48000u * 12u)
void hush_rt_record_start(hush_rt_t *rt, int source /*0 = cleaned, 1 = parallel raw*/, uint32_t frames);
uint32_t hush_rt_record_progress(const hush_rt_t *rt);    // frames recorded
int hush_rt_record_done(const hush_rt_t *rt);
const float *hush_rt_record_buffer(const hush_rt_t *rt);

CF_ASSUME_NONNULL_END

#endif
