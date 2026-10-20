// Ring buffer audio SPSC (un producteur, un consommateur), lock-free, sans allocation.
// La structure est "plate" : elle peut vivre dans une mémoire partagée entre processus.
#ifndef RING_H
#define RING_H

#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>

typedef struct {
    _Atomic uint64_t writePos;   // en frames, croissant, écrit par le producteur
    _Atomic uint64_t readPos;    // en frames, croissant, écrit par le consommateur
    uint32_t capacity;           // en frames, puissance de deux
    uint32_t channels;
    float data[];                // capacity * channels échantillons entrelacés
} ring_t;

static inline size_t ring_bytes(uint32_t capacity, uint32_t channels) {
    return sizeof(ring_t) + (size_t)capacity * channels * sizeof(float);
}

static inline void ring_init(ring_t *r, uint32_t capacity, uint32_t channels) {
    atomic_store_explicit(&r->writePos, 0, memory_order_relaxed);
    atomic_store_explicit(&r->readPos, 0, memory_order_relaxed);
    r->capacity = capacity;
    r->channels = channels;
}

static inline uint64_t ring_fill(ring_t *r) {
    return atomic_load_explicit(&r->writePos, memory_order_acquire) -
           atomic_load_explicit(&r->readPos, memory_order_acquire);
}

// Écrit des frames entrelacées. Si le consommateur est en retard, les plus anciennes sont écrasées
// (le consommateur le détecte et se recale).
static inline void ring_write(ring_t *r, const float *src, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&r->writePos, memory_order_relaxed);
    uint32_t mask = r->capacity - 1, ch = r->channels;
    for (uint32_t i = 0; i < frames; i++) {
        float *dst = &r->data[((w + i) & mask) * ch];
        for (uint32_t c = 0; c < ch; c++) dst[c] = src[i * ch + c];
    }
    atomic_store_explicit(&r->writePos, w + frames, memory_order_release);
}

// Lit `frames` frames entrelacées. Maintient une latence cible : si le remplissage dépasse
// maxFill, saute en avant ; s'il manque des données, complète avec du silence.
// Retourne le nombre de frames réellement lues (le reste est du silence).
static inline uint32_t ring_read(ring_t *r, float *dst, uint32_t frames, uint32_t targetFill, uint32_t maxFill) {
    uint64_t w = atomic_load_explicit(&r->writePos, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&r->readPos, memory_order_relaxed);
    uint32_t mask = r->capacity - 1, ch = r->channels;
    if (w - rd > maxFill || w < rd) rd = w - targetFill;   // trop en retard (ou écrasé) : on se recale
    uint64_t avail = w - rd;
    uint32_t n = avail < frames ? (uint32_t)avail : frames;
    for (uint32_t i = 0; i < n; i++) {
        const float *s = &r->data[((rd + i) & mask) * ch];
        for (uint32_t c = 0; c < ch; c++) dst[i * ch + c] = s[c];
    }
    for (uint32_t i = n * ch; i < frames * ch; i++) dst[i] = 0.0f;
    atomic_store_explicit(&r->readPos, rd + n, memory_order_release);
    return n;
}

// Lecture simple, sans recalage : lit min(disponible, frames), complète par du silence.
// Retourne le nombre de frames réellement lues.
static inline uint32_t ring_read_avail(ring_t *r, float *dst, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&r->writePos, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&r->readPos, memory_order_relaxed);
    uint32_t mask = r->capacity - 1, ch = r->channels;
    uint64_t avail = w > rd ? w - rd : 0;
    uint32_t n = avail < frames ? (uint32_t)avail : frames;
    for (uint32_t i = 0; i < n; i++) {
        const float *s = &r->data[((rd + i) & mask) * ch];
        for (uint32_t c = 0; c < ch; c++) dst[i * ch + c] = s[c];
    }
    for (uint32_t i = n * ch; i < frames * ch; i++) dst[i] = 0.0f;
    atomic_store_explicit(&r->readPos, rd + n, memory_order_release);
    return n;
}

static inline void ring_set_read(ring_t *r, uint64_t pos) {
    atomic_store_explicit(&r->readPos, pos, memory_order_release);
}

#endif
