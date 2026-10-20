// shm contract between the Hush app (producer) and the HAL driver (consumer)
// all logic (target latency, resync) is driven by fields the app writes
// driver just reads the ring and publishes its stats
#ifndef HUSH_SHM_H
#define HUSH_SHM_H

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdatomic.h>
#include "ring.h"

#ifndef HUSH_SHM_NAME
#define HUSH_SHM_NAME      "/hush.mic.v1"
#endif
#define HUSH_SHM_MAGIC     0x48555348u   // 'HUSH'
#define HUSH_SHM_VERSION   1u
#define HUSH_SAMPLE_RATE   48000u
#define HUSH_RING_FRAMES   8192u         // ~170 ms, power of two
#define HUSH_CHANNELS      1u
// no app write for longer than this -> driver outputs silence
#define HUSH_WRITER_TIMEOUT_NS 200000000ull

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t writerPid;   // pid of the only process allowed to write (0 = free), see hush_app_claim_writer

    // written by app
    _Atomic uint64_t writerHeartbeat;   // mach_absolute_time() of last write
    _Atomic uint32_t targetFill;        // margin added to client buffer for target latency, frames
    _Atomic uint32_t maxFill;           // tolerance. past (target + maxFill) driver drops the excess

    // written by driver (stats, read-only for app)
    _Atomic uint64_t readerHeartbeat;   // mach_absolute_time() of last read
    _Atomic uint64_t underruns;         // short reads (padded w/ silence)
    _Atomic uint32_t lastFill;          // fill seen at last read
    _Atomic uint32_t clientsRunning;    // active IO clients on the virtual mic

    uint8_t pad[64];                    // keeps header off the ring's cache lines
    ring_t ring;                        // must stay last (flexible array)
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
    atomic_store(&s->targetFill, 256);
    atomic_store(&s->maxFill, 1024);
    atomic_store(&s->readerHeartbeat, 0);
    atomic_store(&s->underruns, 0);
    atomic_store(&s->lastFill, 0);
    atomic_store(&s->clientsRunning, 0);
    ring_init(&s->ring, HUSH_RING_FRAMES, HUSH_CHANNELS);
    s->version = HUSH_SHM_VERSION;
    atomic_thread_fence(memory_order_release);
    s->magic = HUSH_SHM_MAGIC;
}

// app side access. Swift only sees shm as an opaque pointer
typedef struct {
    uint32_t lastFill;
    uint32_t clientsRunning;
    uint64_t underruns;
    uint64_t readerHeartbeat;
} hush_reader_stats_t;

static inline int hush_app_attach(void *mem, size_t bytes) {   // 1 if header had to be initialized
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
// called from audio callback. no alloc no lock
static inline void hush_app_write(void *mem, const float *frames, uint32_t count, uint64_t hostTime) {
    hush_shm_t *s = (hush_shm_t *)mem;
    ring_write(&s->ring, frames, count);
    atomic_store_explicit(&s->writerHeartbeat, hostTime, memory_order_release);
}
// one producer at a time in the ring. two writers interleave their blocks (choppy "robotic" voice)
// returns 1 if `pid` is (or becomes) the producer, 0 if another live process already is
// dead owner gets replaced automatically
static inline int hush_app_claim_writer(void *mem, uint32_t pid) {
    hush_shm_t *s = (hush_shm_t *)mem;
    uint32_t cur = __atomic_load_n(&s->writerPid, __ATOMIC_ACQUIRE);
    for (;;) {
        if (cur == pid) return 1;
        if (cur != 0 && (kill((pid_t)cur, 0) == 0 || errno == EPERM)) return 0;
        if (__atomic_compare_exchange_n(&s->writerPid, &cur, pid, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return 1;
    }
}
static inline void hush_app_release_writer(void *mem, uint32_t pid) {
    hush_shm_t *s = (hush_shm_t *)mem;
    uint32_t expected = pid;
    __atomic_compare_exchange_n(&s->writerPid, &expected, 0, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}
static inline void hush_app_stop(void *mem) {   // driver switches to silence right away
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
