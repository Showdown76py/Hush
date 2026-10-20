// SPSC audio ring buffer (one producer one consumer), lock-free, no alloc
// struct is flat so it can live in shm across processes
#ifndef RING_H
#define RING_H

#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>

typedef struct {
    _Atomic uint64_t writePos;   // frames, monotonic, written by producer
    _Atomic uint64_t readPos;    // frames, monotonic, written by consumer
    uint32_t capacity;           // frames, power of two
    uint32_t channels;
    float data[];                // capacity * channels interleaved samples
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

// writes interleaved frames. if consumer lags the oldest get overwritten
// (consumer notices and resyncs)
static inline void ring_write(ring_t *r, const float *src, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&r->writePos, memory_order_relaxed);
    uint32_t mask = r->capacity - 1, ch = r->channels;
    for (uint32_t i = 0; i < frames; i++) {
        float *dst = &r->data[((w + i) & mask) * ch];
        for (uint32_t c = 0; c < ch; c++) dst[c] = src[i * ch + c];
    }
    atomic_store_explicit(&r->writePos, w + frames, memory_order_release);
}

// reads `frames` interleaved frames keeping a target latency. fill > maxFill -> jump ahead
// missing data -> pad w/ silence
// returns frames actually read (rest is silence)
static inline uint32_t ring_read(ring_t *r, float *dst, uint32_t frames, uint32_t targetFill, uint32_t maxFill) {
    uint64_t w = atomic_load_explicit(&r->writePos, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&r->readPos, memory_order_relaxed);
    uint32_t mask = r->capacity - 1, ch = r->channels;
    if (w - rd > maxFill || w < rd) rd = w - targetFill;   // too far behind (or overwritten) -> resync
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

// no resync. reads up to `frames` available frames and pads w/ silence
// returns frames actually read
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
