// Contrat de mémoire partagée entre l'app Hush (producteur) et le driver HAL (consommateur).
// Toute la logique (latence cible, resynchronisation) est pilotée par des champs écrits par l'app :
// le driver se contente de lire le ring et de publier ses statistiques.
#ifndef HUSH_SHM_H
#define HUSH_SHM_H

#include <stdint.h>
#include <stdatomic.h>
#include "ring.h"

#ifndef HUSH_SHM_NAME
#define HUSH_SHM_NAME      "/hush.mic.v1"
#endif
#define HUSH_SHM_MAGIC     0x48555348u   // 'HUSH'
#define HUSH_SHM_VERSION   1u
#define HUSH_SAMPLE_RATE   48000u
#define HUSH_RING_FRAMES   8192u         // ~170 ms, puissance de deux
#define HUSH_CHANNELS      1u
// Au-delà de ce délai sans écriture de l'app, le driver produit du silence.
#define HUSH_WRITER_TIMEOUT_NS 200000000ull

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t reserved0;

    // Écrit par l'app
    _Atomic uint64_t writerHeartbeat;   // mach_absolute_time() de la dernière écriture
    _Atomic uint32_t targetFill;        // frames de latence visées par le driver
    _Atomic uint32_t maxFill;           // au-delà, le driver se recale sur targetFill

    // Écrit par le driver (statistiques, lecture seule pour l'app)
    _Atomic uint64_t readerHeartbeat;   // mach_absolute_time() de la dernière lecture
    _Atomic uint64_t underruns;         // lectures incomplètes (complétées par du silence)
    _Atomic uint32_t lastFill;          // remplissage observé à la dernière lecture
    _Atomic uint32_t clientsRunning;    // nombre de clients IO actifs sur le micro virtuel

    uint8_t pad[64];                    // isole l'en-tête du ring (lignes de cache)
    ring_t ring;                        // doit rester en dernier (tableau flexible)
} hush_shm_t;

static inline size_t hush_shm_bytes(void) {
    return sizeof(hush_shm_t) + (size_t)HUSH_RING_FRAMES * HUSH_CHANNELS * sizeof(float);
}

static inline int hush_shm_valid(const hush_shm_t *s, size_t mappedBytes) {
    return mappedBytes >= hush_shm_bytes() && s->magic == HUSH_SHM_MAGIC && s->version == HUSH_SHM_VERSION &&
           s->ring.capacity == HUSH_RING_FRAMES && s->ring.channels == HUSH_CHANNELS;
}

static inline void hush_shm_init(hush_shm_t *s) {
    s->sampleRate = HUSH_SAMPLE_RATE;
    atomic_store(&s->writerHeartbeat, 0);
    atomic_store(&s->targetFill, 512);
    atomic_store(&s->maxFill, 2048);
    atomic_store(&s->readerHeartbeat, 0);
    atomic_store(&s->underruns, 0);
    atomic_store(&s->lastFill, 0);
    atomic_store(&s->clientsRunning, 0);
    ring_init(&s->ring, HUSH_RING_FRAMES, HUSH_CHANNELS);
    s->version = HUSH_SHM_VERSION;
    atomic_thread_fence(memory_order_release);
    s->magic = HUSH_SHM_MAGIC;
}

// --- Accès côté app (utilisables depuis Swift via un pointeur opaque) ---
typedef struct {
    uint32_t lastFill;
    uint32_t clientsRunning;
    uint64_t underruns;
    uint64_t readerHeartbeat;
} hush_reader_stats_t;

static inline int hush_app_attach(void *mem, size_t bytes) {   // 1 si l'en-tête a dû être initialisé
    hush_shm_t *s = (hush_shm_t *)mem;
    if (hush_shm_valid(s, bytes)) return 0;
    hush_shm_init(s);
    return 1;
}
static inline void hush_app_set_latency(void *mem, uint32_t targetFill, uint32_t maxFill) {
    hush_shm_t *s = (hush_shm_t *)mem;
    atomic_store_explicit(&s->targetFill, targetFill, memory_order_relaxed);
    atomic_store_explicit(&s->maxFill, maxFill, memory_order_relaxed);
}
// Appelée depuis le callback audio : pas d'allocation, pas de verrou.
static inline void hush_app_write(void *mem, const float *frames, uint32_t count, uint64_t hostTime) {
    hush_shm_t *s = (hush_shm_t *)mem;
    ring_write(&s->ring, frames, count);
    atomic_store_explicit(&s->writerHeartbeat, hostTime, memory_order_release);
}
static inline void hush_app_stop(void *mem) {   // le driver passe immédiatement au silence
    hush_shm_t *s = (hush_shm_t *)mem;
    atomic_store_explicit(&s->writerHeartbeat, 0, memory_order_release);
}
static inline hush_reader_stats_t hush_app_reader_stats(const void *mem) {
    hush_shm_t *s = (hush_shm_t *)mem;
    hush_reader_stats_t r;
    r.lastFill = atomic_load_explicit(&s->lastFill, memory_order_relaxed);
    r.clientsRunning = atomic_load_explicit(&s->clientsRunning, memory_order_relaxed);
    r.underruns = atomic_load_explicit(&s->underruns, memory_order_relaxed);
    r.readerHeartbeat = atomic_load_explicit(&s->readerHeartbeat, memory_order_relaxed);
    return r;
}

#endif
