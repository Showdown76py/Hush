// driver test bench. compiles HushDriver.c directly w/ a test-only shm name
// and fakes the coreaudiod host and the app
#define HUSH_SHM_NAME "/hush.test.v1"
#include "../HushDriver.c"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "ÉCHEC %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static AudioServerPlugInHostInterface gFakeHost;   // no host function ever gets called

static UInt32 GetU32(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    UInt32 v = 0xDEADBEEF, size = 0;
    OSStatus st = Hush_GetPropertyData(gDriverRef, obj, 0, &a, 0, NULL, sizeof(v), &size, &v);
    CHECK(st == noErr && size == 4, "GetU32 %u sel=%.4s st=%d size=%u", obj, (char *)&sel, (int)st, size);
    return v;
}

static void TestProperties(void) {
    AudioObjectPropertyAddress a = {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID ids[4] = {0};
    UInt32 size = 0;
    CHECK(Hush_GetPropertyDataSize(gDriverRef, kObjectID_PlugIn, 0, &a, 0, NULL, &size) == noErr && size == 4, "taille DeviceList");
    CHECK(Hush_GetPropertyData(gDriverRef, kObjectID_PlugIn, 0, &a, 0, NULL, sizeof(ids), &size, ids) == noErr && ids[0] == kObjectID_Device, "DeviceList");

    a.mSelector = kAudioObjectPropertyName;
    CFStringRef name = NULL;
    CHECK(Hush_GetPropertyData(gDriverRef, kObjectID_Device, 0, &a, 0, NULL, sizeof(name), &size, &name) == noErr, "Name");
    CHECK(name && CFStringCompare(name, CFSTR("Hush Microphone"), 0) == kCFCompareEqualTo, "nom du périphérique");

    a.mSelector = kAudioPlugInPropertyTranslateUIDToDevice;
    CFStringRef uid = CFSTR(HUSH_DEVICE_UID);
    AudioObjectID found = 0;
    CHECK(Hush_HasProperty(gDriverRef, kObjectID_PlugIn, 0, &a), "HasProperty TranslateUID");
    CHECK(Hush_GetPropertyData(gDriverRef, kObjectID_PlugIn, 0, &a, sizeof(uid), &uid, sizeof(found), &size, &found) == noErr &&
          found == kObjectID_Device, "TranslateUID");

    // no output stream, one input stream
    a = (AudioObjectPropertyAddress){kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    CHECK(Hush_GetPropertyDataSize(gDriverRef, kObjectID_Device, 0, &a, 0, NULL, &size) == noErr && size == 0, "pas de flux de sortie");
    a.mScope = kAudioObjectPropertyScopeInput;
    CHECK(Hush_GetPropertyDataSize(gDriverRef, kObjectID_Device, 0, &a, 0, NULL, &size) == noErr && size == 4, "un flux d'entrée");

    CHECK(GetU32(kObjectID_Device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeVirtual, "transport");
    CHECK(GetU32(kObjectID_Device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1, "défaut entrée");
    CHECK(GetU32(kObjectID_Device, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 0, "pas défaut sortie");
    CHECK(GetU32(kObjectID_Stream, kAudioStreamPropertyDirection, kAudioObjectPropertyScopeGlobal) == 1, "direction entrée");

    a = (AudioObjectPropertyAddress){kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription f;
    CHECK(Hush_GetPropertyData(gDriverRef, kObjectID_Stream, 0, &a, 0, NULL, sizeof(f), &size, &f) == noErr &&
          f.mSampleRate == 48000 && f.mChannelsPerFrame == 1 && f.mBitsPerChannel == 32, "format du flux");
    Boolean settable = false;
    CHECK(Hush_IsPropertySettable(gDriverRef, kObjectID_Stream, 0, &a, &settable) == noErr && settable, "format réglable");
    CHECK(Hush_SetPropertyData(gDriverRef, kObjectID_Stream, 0, &a, 0, NULL, sizeof(f), &f) == noErr, "réécrire le même format");
    f.mSampleRate = 44100;
    CHECK(Hush_SetPropertyData(gDriverRef, kObjectID_Stream, 0, &a, 0, NULL, sizeof(f), &f) == kAudioDeviceUnsupportedFormatError, "refus 44,1 kHz");

    // unknown property -> HasProperty false, too small size rejected
    a = (AudioObjectPropertyAddress){'zzzz', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CHECK(!Hush_HasProperty(gDriverRef, kObjectID_Device, 0, &a), "propriété inconnue");
    a.mSelector = kAudioDevicePropertyNominalSampleRate;
    UInt32 tiny = 0;
    CHECK(Hush_GetPropertyData(gDriverRef, kObjectID_Device, 0, &a, 0, NULL, sizeof(tiny), &size, &tiny) == kAudioHardwareBadPropertySizeError, "taille trop petite");
    CHECK(Hush_HasProperty(gDriverRef, 99, 0, &a) == false, "objet inconnu");
}

static hush_shm_t *MapAsApp(void) {
    int fd = shm_open(HUSH_SHM_NAME, O_RDWR, 0);
    CHECK(fd >= 0, "l'app ouvre la mémoire partagée (errno=%d)", errno);
    if (fd < 0) return NULL;
    void *p = mmap(NULL, hush_shm_bytes(), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    CHECK(p != MAP_FAILED, "mmap app");
    hush_shm_t *s = p;
    CHECK(hush_shm_valid(s, hush_shm_bytes()), "en-tête valide");
    return s;
}

static void Read(float *buf, UInt32 frames) {
    CHECK(Hush_DoIOOperation(gDriverRef, kObjectID_Device, kObjectID_Stream, 0, kAudioServerPlugInIOOperationReadInput,
                             frames, NULL, buf, NULL) == noErr, "DoIOOperation");
}

static void TestIO(void) {
    hush_shm_t *s = MapAsApp();
    if (!s) return;
    CHECK(Hush_StartIO(gDriverRef, kObjectID_Device, 1) == noErr, "StartIO");
    CHECK(atomic_load(&s->clientsRunning) == 1, "clientsRunning");

    float buf[512];
    // 1. no app -> silence
    for (int i = 0; i < 512; i++) buf[i] = 1;
    Read(buf, 512);
    int silent = 1;
    for (int i = 0; i < 512; i++) silent &= buf[i] == 0;
    CHECK(silent, "silence sans app");

    // 2. app writes a ramp in 480 blocks, driver reads 512 blocks -> exact continuity
    atomic_store(&s->targetFill, 1024);
    atomic_store(&s->maxFill, 4096);
    float block[480];
    uint64_t produced = 0;
    for (int k = 0; k < 4; k++) {     // priming 1920 frames
        for (int i = 0; i < 480; i++) block[i] = (float)(produced + i);
        ring_write(&s->ring, block, 480);
        produced += 480;
    }
    atomic_store(&s->writerHeartbeat, mach_absolute_time());
    float expected = -1;
    int discontinuities = 0;
    uint64_t consumed = 0;
    for (int cycle = 0; cycle < 2000; cycle++) {
        while (produced < consumed + 512 + 1024 + 512) {   // producer at same avg rate, ahead
            for (int i = 0; i < 480; i++) block[i] = (float)(produced + i);
            ring_write(&s->ring, block, 480);
            produced += 480;
        }
        atomic_store(&s->writerHeartbeat, mach_absolute_time());
        Read(buf, 512);
        consumed += 512;
        for (int i = 0; i < 512; i++) {
            if (expected >= 0 && buf[i] != expected) discontinuities++;
            expected = buf[i] + 1;
        }
    }
    CHECK(discontinuities == 0, "flux continu (%d discontinuités)", discontinuities);
    CHECK(atomic_load(&s->underruns) == 0, "aucun underrun (%llu)", (unsigned long long)atomic_load(&s->underruns));
    // fill stays stable (no drift no growth) between target - producer block and target + reader block + margin
    UInt32 fill = atomic_load(&s->lastFill);
    CHECK(fill >= 512 + 1024 - 480 && fill <= 512 + 1024 + 480, "latence tenue autour de la cible (fill=%u)", fill);

    // 3. producer starved -> padded w/ silence + underrun counted
    Read(buf, 512); Read(buf, 512); Read(buf, 512); Read(buf, 512);
    CHECK(atomic_load(&s->underruns) > 0, "underrun détecté");

    // 4. stale heartbeat -> silence
    atomic_store(&s->writerHeartbeat, mach_absolute_time() - 10 * gWriterTimeoutTicks);
    for (int i = 0; i < 480; i++) block[i] = 0.5f;
    ring_write(&s->ring, block, 480);
    Read(buf, 512);
    silent = 1;
    for (int i = 0; i < 512; i++) silent &= buf[i] == 0;
    CHECK(silent, "silence quand l'app est figée");

    // 5. reader way behind -> resync to target instead of reading old audio
    atomic_store(&s->writerHeartbeat, mach_absolute_time());
    for (int k = 0; k < 10; k++) { for (int i = 0; i < 480; i++) block[i] = (float)k; ring_write(&s->ring, block, 480); }
    atomic_store(&s->writerHeartbeat, mach_absolute_time());
    Read(buf, 512);
    CHECK(ring_fill(&s->ring) <= 1024 + 512, "recalage après retard (fill=%llu)", (unsigned long long)ring_fill(&s->ring));

    CHECK(Hush_StopIO(gDriverRef, kObjectID_Device, 1) == noErr, "StopIO");
    CHECK(atomic_load(&s->clientsRunning) == 0, "clientsRunning après StopIO");
}

// real case seen w/ Discord: 1024 frame client, producer (VPIO) in irregular ~128 blocks
// 48 kHz timed sim w/ jitter -> no underrun in steady state
static void TestBigClientBuffer(void) {
    hush_shm_t *s = MapAsApp();
    if (!s) return;
    Hush_StartIO(gDriverRef, kObjectID_Device, 3);
    atomic_store(&s->targetFill, 256);
    atomic_store(&s->maxFill, 1024);
    uint64_t before = atomic_load(&s->underruns);
    float out[1024], chunk[160];
    // producer follows an ideal clock, each callback lands 0 to 1.5 ms late
    // (non cumulative jitter like a hw clocked callback)
    double ideal = 0, nextWrite = 0, nextRead = 0.005;
    unsigned seed = 1;
    int reads = 0;
    while (reads < 3000) {
        if (nextWrite <= nextRead) {
            seed = seed * 1103515245 + 12345;
            uint32_t n = 127 + (seed >> 16) % 3;                 // 127..129 frames
            for (uint32_t i = 0; i < n; i++) chunk[i] = 0.1f;
            ring_write(&s->ring, chunk, n);
            atomic_store(&s->writerHeartbeat, mach_absolute_time());
            ideal += n / 48000.0;
            seed = seed * 1103515245 + 12345;
            nextWrite = ideal + ((seed >> 16) % 1000) / 1000.0 * 0.0015;
        } else {
            Read(out, 1024);
            reads++;
            nextRead += 1024 / 48000.0;
        }
    }
    uint64_t during = atomic_load(&s->underruns) - before;
    CHECK(during <= 1, "client 1024 frames : %llu underruns (amorçage inclus)", (unsigned long long)during);
    UInt32 fill = atomic_load(&s->lastFill);
    CHECK(fill >= 1024 && fill <= 1024 + 256 + 1024, "latence bornée (fill=%u)", fill);
    Hush_StopIO(gDriverRef, kObjectID_Device, 3);
}

static void TestClock(void) {
    Hush_StartIO(gDriverRef, kObjectID_Device, 2);
    Float64 st; UInt64 ht, seed;
    CHECK(Hush_GetZeroTimeStamp(gDriverRef, kObjectID_Device, 2, &st, &ht, &seed) == noErr && st == 0, "premier zéro");
    usleep(400000);   // > 1 period (16384 frames = 341 ms)
    Float64 st2; UInt64 ht2;
    Hush_GetZeroTimeStamp(gDriverRef, kObjectID_Device, 2, &st2, &ht2, &seed);
    CHECK(st2 == kZeroTimeStampPeriod && ht2 > ht, "horloge avance d'une période");
    Float64 secs = (Float64)(ht2 - ht) / (gHostTicksPerFrame * 48000);
    CHECK(fabs(secs - 16384.0 / 48000.0) < 1e-6, "période = 16384 frames à 48 kHz (%f s)", secs);
    Hush_StopIO(gDriverRef, kObjectID_Device, 2);
}

int main(void) {
    shm_unlink(HUSH_SHM_NAME);
    void *drv = Hush_Create(NULL, kAudioServerPlugInTypeUUID);
    CHECK(drv == gDriverRef, "factory");
    CHECK(Hush_Create(NULL, IUnknownUUID) == NULL, "factory refuse un autre type");
    void *iface = NULL;
    CFUUIDBytes b = CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID);
    CHECK(Hush_QueryInterface(gDriverRef, b, &iface) == S_OK && iface == gDriverRef, "QueryInterface");
    CHECK(Hush_Initialize(gDriverRef, &gFakeHost) == noErr, "Initialize");
    CHECK(atomic_load(&gShm) != NULL, "mémoire partagée créée par le driver");
    TestProperties();
    TestIO();
    TestBigClientBuffer();
    TestClock();
    shm_unlink(HUSH_SHM_NAME);
    if (failures) { fprintf(stderr, "%d échec(s)\n", failures); return 1; }
    printf("driver_test: tous les tests passent\n");
    return 0;
}
