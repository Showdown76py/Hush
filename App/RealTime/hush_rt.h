// Partie temps réel de l'app Hush, en C : callbacks audio sans allocation, sans verrou et sans
// runtime Swift. Le code Swift configure les audio units et lit l'état via ces fonctions.
#ifndef HUSH_RT_H
#define HUSH_RT_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

typedef struct hush_rt hush_rt_t;

hush_rt_t *_Nullable hush_rt_create(void);
void hush_rt_destroy(hush_rt_t *rt);

// Configuration (hors temps réel, unités arrêtées)
void hush_rt_set_vp_unit(hush_rt_t *rt, AudioUnit _Nullable unit);
void hush_rt_set_raw_unit(hush_rt_t *rt, AudioUnit _Nullable unit);
// Mémoire partagée avec le driver (NULL = pas de sortie). Peut être changée à chaud.
void hush_rt_set_shm(hush_rt_t *rt, void *_Nullable shm);
// Correction de dérive d'horloge par glissement d'échantillons (activée par défaut).
void hush_rt_set_drift_correction(hush_rt_t *rt, int enabled);

// Callbacks à brancher sur les audio units
// Signatures identiques à AURenderCallback (nullabilité comprise, pour Swift).
OSStatus hush_rt_vp_input(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data);
OSStatus hush_rt_silence_output(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                                UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data);
OSStatus hush_rt_raw_input(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                           UInt32 bus, UInt32 frames, AudioBufferList *_Nullable data);

// État lu par l'UI (valeurs linéaires RMS du dernier bloc, 0..1)
float hush_rt_level_clean(const hush_rt_t *rt);
float hush_rt_level_raw(const hush_rt_t *rt);
// Compteurs pour le chien de garde et le diagnostic
uint64_t hush_rt_vp_callbacks(const hush_rt_t *rt);
uint64_t hush_rt_vp_errors(const hush_rt_t *rt);
int32_t hush_rt_last_error(const hush_rt_t *rt);
int64_t hush_rt_drift_slips(const hush_rt_t *rt);   // >0 : échantillons retirés, <0 : dupliqués

// Enregistrement pour le test avant/après (tampons pré-alloués, 12 s max par source)
#define HUSH_RT_RECORD_MAX_FRAMES (48000u * 12u)
void hush_rt_record_start(hush_rt_t *rt, int source /*0 = nettoyé, 1 = brut parallèle*/, uint32_t frames);
uint32_t hush_rt_record_progress(const hush_rt_t *rt);    // frames enregistrées
int hush_rt_record_done(const hush_rt_t *rt);
const float *hush_rt_record_buffer(const hush_rt_t *rt);

CF_ASSUME_NONNULL_END

#endif
