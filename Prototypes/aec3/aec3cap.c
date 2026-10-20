// Prototype : micro brut (AUHAL, sans voice processing) + référence = sortie système (tap Core Audio)
// → WebRTC AEC3 + débruitage → WAV (et, avec --shm, le micro virtuel Hush).
// Usage : aec3cap --dir <out> [--seconds 15] [--ns 0..4] [--bypass] [--shm]
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/AudioHardwareTapping.h>
#include <CoreAudio/CATapDescription.h>
#include <CoreAudio/CoreAudio.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "aec3_wrap.h"
#include "hush_app.h"
#include "ring.h"

#define SR 48000
#define BLOCK 480
static ring_t *gMic, *gRef;
static _Atomic uint64_t gMicFirstHost, gRefFirstHost;
static AudioUnit gMicUnit;
static float gMicScratch[8192];
static double gTicksPerSec;

static ring_t *ring_new(uint32_t cap) {
    ring_t *r = calloc(1, ring_bytes(cap, 1));
    ring_init(r, cap, 1);
    return r;
}

static OSStatus mic_cb(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                       AudioBufferList *data) {
    (void)ref; (void)data;
    AudioBufferList abl = {1, {{1, frames * 4, gMicScratch}}};
    OSStatus e = AudioUnitRender(gMicUnit, flags, ts, bus, frames, &abl);
    if (e) return e;
    uint64_t zero = 0;
    atomic_compare_exchange_strong(&gMicFirstHost, &zero, ts->mHostTime);
    ring_write(gMic, gMicScratch, frames);
    return noErr;
}

static OSStatus tap_proc(AudioObjectID dev, const AudioTimeStamp *now, const AudioBufferList *in, const AudioTimeStamp *inTime,
                         AudioBufferList *out, const AudioTimeStamp *outTime, void *ctx) {
    (void)dev; (void)now; (void)out; (void)outTime; (void)ctx;
    static float mono[8192];
    const AudioBuffer *b = &in->mBuffers[0];
    UInt32 ch = b->mNumberChannels ? b->mNumberChannels : 1;
    UInt32 frames = b->mDataByteSize / 4 / ch;
    if (frames > 8192) frames = 8192;
    const float *p = b->mData;
    for (UInt32 i = 0; i < frames; i++) {
        float s = 0;
        for (UInt32 c = 0; c < ch; c++) s += p[i * ch + c];
        mono[i] = s / ch;
    }
    uint64_t zero = 0;
    atomic_compare_exchange_strong(&gRefFirstHost, &zero, inTime->mHostTime);
    ring_write(gRef, mono, frames);
    return noErr;
}

static void write_wav(const char *path, const float *x, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    uint32_t dataBytes = (uint32_t)(n * 4), riff = 36 + dataBytes, fmtLen = 16, rate = SR, byteRate = SR * 4;
    uint16_t fmtTag = 3, chans = 1, align = 4, bits = 32;
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f); fwrite(&fmtLen, 4, 1, f);
    fwrite(&fmtTag, 2, 1, f); fwrite(&chans, 2, 1, f); fwrite(&rate, 4, 1, f); fwrite(&byteRate, 4, 1, f);
    fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f); fwrite("data", 1, 4, f); fwrite(&dataBytes, 4, 1, f);
    fwrite(x, 4, n, f);
    fclose(f);
}

static void check(OSStatus s, const char *what) {
    if (s) { fprintf(stderr, "%s a échoué : %d\n", what, (int)s); exit(1); }
}

int main(int argc, char **argv) {
    const char *dir = ".";
    double seconds = 15;
    int ns = 2, bypass = 0, useShm = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dir")) dir = argv[++i];
        else if (!strcmp(argv[i], "--seconds")) seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--ns")) ns = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--bypass")) bypass = 1;
        else if (!strcmp(argv[i], "--shm")) useShm = 1;
    }
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gTicksPerSec = 1e9 * tb.denom / tb.numer;
    gMic = ring_new(1 << 16);
    gRef = ring_new(1 << 16);
    void *shm = NULL;
    if (useShm) {
        int err = 0;
        shm = hush_app_map(&err);
        if (!shm) { fprintf(stderr, "shm: errno %d\n", err); return 1; }
        hush_app_set_latency(shm, 256, 1024);
    }

    // --- Tap global de la sortie système (sans couper le son) ---
    pid_t pid = getpid();
    AudioObjectID selfObj = 0;
    UInt32 sz = sizeof(selfObj);
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslatePIDToProcessObject, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    check(AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(pid), &pid, &sz, &selfObj), "TranslatePID");
    // CATapDescription est une classe Objective-C : on passe par le runtime via un petit helper en ObjC.
    extern AudioObjectID make_global_tap(AudioObjectID exclude, CFStringRef *outUUID);
    CFStringRef tapUUID = NULL;
    AudioObjectID tap = make_global_tap(selfObj, &tapUUID);
    if (!tap) { fprintf(stderr, "tap impossible\n"); return 1; }
    CFMutableDictionaryRef agg = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(agg, CFSTR(kAudioAggregateDeviceNameKey), CFSTR("aec3-ref"));
    CFUUIDRef u = CFUUIDCreate(NULL);
    CFStringRef aggUID = CFUUIDCreateString(NULL, u);
    CFDictionarySetValue(agg, CFSTR(kAudioAggregateDeviceUIDKey), aggUID);
    CFDictionarySetValue(agg, CFSTR(kAudioAggregateDeviceIsPrivateKey), kCFBooleanTrue);
    CFDictionarySetValue(agg, CFSTR(kAudioAggregateDeviceTapAutoStartKey), kCFBooleanTrue);
    CFMutableDictionaryRef sub = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(sub, CFSTR(kAudioSubTapUIDKey), tapUUID);
    CFArrayRef taps = CFArrayCreate(NULL, (const void **)&sub, 1, &kCFTypeArrayCallBacks);
    CFDictionarySetValue(agg, CFSTR(kAudioAggregateDeviceTapListKey), taps);
    AudioObjectID aggID = 0;
    check(AudioHardwareCreateAggregateDevice(agg, &aggID), "CreateAggregateDevice");
    AudioDeviceIOProcID procID = NULL;
    check(AudioDeviceCreateIOProcID(aggID, tap_proc, NULL, &procID), "IOProc");

    // --- Micro brut ---
    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0};
    check(AudioComponentInstanceNew(AudioComponentFindNext(NULL, &d), &gMicUnit), "AUHAL");
    UInt32 one = 1, zero = 0;
    check(AudioUnitSetProperty(gMicUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "in");
    check(AudioUnitSetProperty(gMicUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "out");
    AudioDeviceID inDev = 0;
    sz = sizeof(inDev);
    a.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    check(AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &inDev), "default input");
    UInt32 small = 256;
    a.mSelector = kAudioDevicePropertyBufferFrameSize;
    AudioObjectSetPropertyData(inDev, &a, 0, NULL, 4, &small);
    check(AudioUnitSetProperty(gMicUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inDev, 4), "device");
    AudioStreamBasicDescription f = {SR, kAudioFormatLinearPCM,
                                     kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                     4, 1, 4, 1, 32, 0};
    check(AudioUnitSetProperty(gMicUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &f, sizeof(f)), "fmt");
    SInt32 map[1] = {0};
    AudioUnitSetProperty(gMicUnit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, map, sizeof(map));
    AURenderCallbackStruct cb = {mic_cb, NULL};
    check(AudioUnitSetProperty(gMicUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof(cb)), "cb");
    check(AudioUnitInitialize(gMicUnit), "init");

    check(AudioDeviceStart(aggID, procID), "tap start");
    check(AudioOutputUnitStart(gMicUnit), "mic start");

    // Alignement initial : on jette le début du flux qui a commencé le plus tôt.
    while (!atomic_load(&gMicFirstHost) || !atomic_load(&gRefFirstHost)) usleep(1000);
    double dt = ((double)atomic_load(&gRefFirstHost) - (double)atomic_load(&gMicFirstHost)) / gTicksPerSec;
    uint64_t drop = (uint64_t)(fabs(dt) * SR);
    ring_t *early = dt > 0 ? gMic : gRef;
    while (ring_fill(early) < drop) usleep(1000);
    atomic_store(&early->readPos, atomic_load(&early->readPos) + drop);
    printf("alignement : %s en avance de %.1f ms\n", dt > 0 ? "micro" : "référence", fabs(dt) * 1000);

    aec3_t *aec = aec3_create(ns);
    size_t total = (size_t)(seconds * SR);
    float *raw = calloc(total, 4), *clean = calloc(total, 4), *refRec = calloc(total, 4);
    size_t done = 0;
    float mic[BLOCK], ref[BLOCK], out[BLOCK];
    uint64_t t0 = mach_absolute_time(), procTicks = 0, blocks = 0;
    while (done + BLOCK <= total) {
        if (ring_fill(gMic) < BLOCK || ring_fill(gRef) < BLOCK) { usleep(1000); continue; }
        ring_read_avail(gMic, mic, BLOCK);
        ring_read_avail(gRef, ref, BLOCK);
        uint64_t p0 = mach_absolute_time();
        if (bypass) memcpy(out, mic, sizeof(out));
        else aec3_process(aec, ref, mic, out);
        procTicks += mach_absolute_time() - p0;
        blocks++;
        if (shm) hush_app_write(shm, out, BLOCK, mach_absolute_time());
        memcpy(raw + done, mic, sizeof(mic));
        memcpy(clean + done, out, sizeof(out));
        memcpy(refRec + done, ref, sizeof(ref));
        done += BLOCK;
        if (done % SR == 0)
            printf("t=%2zus délai=%d ms ERLE=%.1f dB attente micro=%llu ref=%llu\n", done / SR, aec3_delay_ms(aec),
                   aec3_erle_db(aec), ring_fill(gMic), ring_fill(gRef));
    }
    double secs = (mach_absolute_time() - t0) / gTicksPerSec;
    printf("CPU AEC3 : %.2f %% d'un cœur (%.3f ms par bloc de 10 ms), durée %.1f s\n",
           100.0 * procTicks / gTicksPerSec / secs, procTicks / gTicksPerSec / blocks * 1000, secs);
    if (shm) hush_app_stop(shm);
    AudioOutputUnitStop(gMicUnit);
    AudioDeviceStop(aggID, procID);
    AudioHardwareDestroyAggregateDevice(aggID);
    extern void destroy_tap(AudioObjectID); destroy_tap(tap);
    char path[1024];
    snprintf(path, sizeof path, "%s/raw.wav", dir); write_wav(path, raw, done);
    snprintf(path, sizeof path, "%s/clean.wav", dir); write_wav(path, clean, done);
    snprintf(path, sizeof path, "%s/ref.wav", dir); write_wav(path, refRec, done);
    aec3_destroy(aec);
    return 0;
}
