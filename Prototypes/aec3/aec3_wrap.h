// minimal c wrapper around webrtc::AudioProcessing (aec3 + denoise) mono 48 kHz 10 ms blocks
#ifndef AEC3_WRAP_H
#define AEC3_WRAP_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct aec3 aec3_t;
aec3_t *aec3_create(int noiseSuppression /*0..4, 0 = off*/);
// preset: 0 = aec3 defaults, 1 = voice preserved, 2 = voice very preserved. agc = auto gain
aec3_t *aec3_create_tuned(int noiseSuppression, int preset, int agc);
void aec3_destroy(aec3_t *a);
// ref: 480 samples of system output, mic: 480 from mic, out: 480 cleaned
int aec3_process(aec3_t *a, const float *ref, const float *mic, float *out);
int aec3_delay_ms(aec3_t *a);   // echo delay estimated by aec3 (-1 if unknown)
float aec3_erle_db(aec3_t *a);  // estimated echo attenuation
#ifdef __cplusplus
}
#endif
#endif
