// Enveloppe C minimale autour de webrtc::AudioProcessing (AEC3 + débruitage), mono 48 kHz, blocs de 10 ms.
#ifndef AEC3_WRAP_H
#define AEC3_WRAP_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct aec3 aec3_t;
aec3_t *aec3_create(int noiseSuppression /*0..4, 0 = off*/);
// preset : 0 = réglages par défaut d'AEC3, 1 = voix préservée, 2 = voix très préservée ; agc : gain automatique.
aec3_t *aec3_create_tuned(int noiseSuppression, int preset, int agc);
void aec3_destroy(aec3_t *a);
// ref : 480 échantillons de la sortie système ; mic : 480 du micro ; out : 480 nettoyés.
int aec3_process(aec3_t *a, const float *ref, const float *mic, float *out);
int aec3_delay_ms(aec3_t *a);   // retard d'écho estimé par AEC3 (-1 si inconnu)
float aec3_erle_db(aec3_t *a);  // atténuation d'écho estimée
#ifdef __cplusplus
}
#endif
#endif
