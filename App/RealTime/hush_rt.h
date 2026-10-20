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
// Passage direct : quand `shm` n'est pas NULL, le micro brut (unité "raw") est écrit tel quel dans
// la mémoire partagée. Ne jamais l'activer pendant que le voice processing écrit (un seul producteur).
// La désactivation attend la fin d'un éventuel callback en cours.
void hush_rt_set_passthrough(hush_rt_t *rt, void *_Nullable shm);
// Niveau de la voix traitée. Remplace le gain automatique du voice processing, qui remonte le bruit de
// fond quand la musique est forte. Par défaut : gain automatique piloté par la voix (hush_agc.h) ;
// sinon gain fixe (dB) avec limiteur doux. Modifiables à chaud.
void hush_rt_set_auto_gain(hush_rt_t *rt, int enabled);
void hush_rt_reset_auto_gain(hush_rt_t *rt, float initialGainDB);   // repris au callback suivant
float hush_rt_auto_gain_db(const hush_rt_t *rt);
void hush_rt_set_gain_db(hush_rt_t *rt, float db);
void hush_rt_apply_gain(float *x, uint32_t n, float gain);
// Estimation de la dérive d'horloge du micro par ses horodatages (le driver suit l'horloge hôte à 48 kHz
// exactement) : renvoie -1 (retirer un échantillon), +1 (en ajouter un) ou 0, au rythme exact de la dérive.
typedef struct {
    uint64_t firstHost;
    double frames;               // frames produites avant l'horodatage courant
    double n, meanX, meanY, cxy, cxx;   // régression linéaire en ligne (Welford) secondes ~ frames
    double ppm;                  // dérive estimée (positive : le micro va plus vite que 48 kHz)
    double accumulator;          // frames en excès accumulées
} hush_drift_t;
void hush_drift_reset(hush_drift_t *d);
int hush_drift_update(hush_drift_t *d, uint64_t hostTime, uint32_t frames, double hostTicksPerSecond);

// Rééchantillonnage linéaire d'un bloc (n → m), bords conservés (utilisé par la correction de dérive).
void hush_rt_resample_linear(const float *src, uint32_t n, float *dst, uint32_t m);
// Correction de dérive d'horloge par glissement d'échantillons (activée par défaut).
void hush_rt_set_drift_correction(hush_rt_t *rt, int enabled);
void hush_rt_reset_drift(hush_rt_t *rt);              // à chaque (re)démarrage du voice processing
double hush_rt_drift_ppm(const hush_rt_t *rt);        // diagnostic (lecture non synchronisée)

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
