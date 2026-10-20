// Hush — AudioServerPlugIn (driver HAL) minimal.
//
// Expose un unique périphérique d'entrée virtuel ("Hush Microphone", mono, 48 kHz, Float32)
// dont l'audio provient d'un ring buffer en mémoire partagée alimenté par l'app Hush.
// Le driver ne contient aucune logique métier : il relaie l'audio, produit du silence si l'app ne
// tourne pas, et publie quelques statistiques. Écrit à partir de la documentation de
// <CoreAudio/AudioServerPlugIn.h> ; licence MIT.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "hush_shm.h"

#ifndef HUSH_DEVICE_NAME
#define HUSH_DEVICE_NAME "Hush Microphone"
#endif
#ifndef HUSH_MANUFACTURER
#define HUSH_MANUFACTURER "Hush"
#endif
#define HUSH_DEVICE_UID "HushMicrophone_UID"
#define HUSH_MODEL_UID  "HushMicrophone_ModelUID"

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream = 3,
};

static const UInt32 kZeroTimeStampPeriod = 16384;

// ---------------------------------------------------------------------------------------------
// État global
// ---------------------------------------------------------------------------------------------

static os_log_t gLog;
static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static _Atomic UInt32 gRefCount = 1;
static UInt32 gIOClients = 0;               // protégé par gStateMutex

// Horloge (modifiée uniquement quand l'IO ne tourne pas, ou par le thread IO)
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimeStampCount = 0;
static UInt64 gWriterTimeoutTicks = 0;

// Mémoire partagée
static hush_shm_t *_Atomic gShm = NULL;
static bool gNeedResync = true;            // thread IO uniquement

static void OpenSharedMemory(void) {
    if (atomic_load(&gShm) != NULL) return;
    int fd = shm_open(HUSH_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        os_log_error(gLog, "shm_open(%{public}s) a échoué: errno=%d", HUSH_SHM_NAME, errno);
        return;
    }
    fchmod(fd, 0666);   // l'app tourne sous un autre utilisateur que le driver
    struct stat st;
    size_t need = hush_shm_bytes();
    if (fstat(fd, &st) != 0) { close(fd); return; }
    if (st.st_size == 0 && ftruncate(fd, (off_t)need) != 0) {
        os_log_error(gLog, "ftruncate a échoué: errno=%d", errno);
        close(fd);
        return;
    }
    if (st.st_size != 0 && (size_t)st.st_size < need) {
        os_log_error(gLog, "mémoire partagée trop petite (%lld < %zu)", (long long)st.st_size, need);
        close(fd);
        return;
    }
    void *p = mmap(NULL, need, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        os_log_error(gLog, "mmap a échoué: errno=%d", errno);
        return;
    }
    hush_shm_t *s = (hush_shm_t *)p;
    if (!hush_shm_valid(s, need)) hush_shm_init(s);
    atomic_store(&gShm, s);
    os_log(gLog, "mémoire partagée prête (%zu octets)", need);
}

// ---------------------------------------------------------------------------------------------
// Interface COM
// ---------------------------------------------------------------------------------------------

static HRESULT Hush_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG Hush_AddRef(void *inDriver);
static ULONG Hush_Release(void *inDriver);
static OSStatus Hush_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus Hush_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus Hush_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus Hush_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus Hush_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus Hush_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus Hush_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static Boolean Hush_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus Hush_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus Hush_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus Hush_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus Hush_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
static OSStatus Hush_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus Hush_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus Hush_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus Hush_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus Hush_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus Hush_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);
static OSStatus Hush_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    Hush_QueryInterface, Hush_AddRef, Hush_Release,
    Hush_Initialize, Hush_CreateDevice, Hush_DestroyDevice,
    Hush_AddDeviceClient, Hush_RemoveDeviceClient,
    Hush_PerformDeviceConfigurationChange, Hush_AbortDeviceConfigurationChange,
    Hush_HasProperty, Hush_IsPropertySettable, Hush_GetPropertyDataSize, Hush_GetPropertyData, Hush_SetPropertyData,
    Hush_StartIO, Hush_StopIO, Hush_GetZeroTimeStamp,
    Hush_WillDoIOOperation, Hush_BeginIOOperation, Hush_DoIOOperation, Hush_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// Point d'entrée déclaré dans Info.plist (CFPlugInFactories).
__attribute__((visibility("default")))
void *Hush_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT Hush_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG Hush_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG Hush_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    UInt32 old = atomic_load(&gRefCount);
    while (old > 0 && !atomic_compare_exchange_weak(&gRefCount, &old, old - 1)) {}
    return old > 0 ? old - 1 : 0;
}

static OSStatus Hush_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gLog = os_log_create("io.github.showdown76py.Hush.Driver", "driver");
    gHost = inHost;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    gHostTicksPerFrame = ticksPerSecond / HUSH_SAMPLE_RATE;
    gWriterTimeoutTicks = (UInt64)((Float64)HUSH_WRITER_TIMEOUT_NS * (Float64)tb.denom / (Float64)tb.numer);
    OpenSharedMemory();
    os_log(gLog, "Hush driver initialisé");
    return noErr;
}

static OSStatus Hush_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *ci, AudioObjectID *out) {
    (void)d; (void)desc; (void)ci; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Hush_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) {
    (void)d; (void)dev;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Hush_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *ci) {
    (void)ci;
    return (d == gDriverRef && dev == kObjectID_Device) ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus Hush_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo *ci) {
    (void)ci;
    return (d == gDriverRef && dev == kObjectID_Device) ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus Hush_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 a, void *i) {
    (void)a; (void)i;
    return (d == gDriverRef && dev == kObjectID_Device) ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus Hush_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 a, void *i) {
    (void)a; (void)i;
    return (d == gDriverRef && dev == kObjectID_Device) ? noErr : kAudioHardwareBadObjectError;
}

// ---------------------------------------------------------------------------------------------
// Propriétés
// ---------------------------------------------------------------------------------------------

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = HUSH_SAMPLE_RATE;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4 * HUSH_CHANNELS;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * HUSH_CHANNELS;
    f.mChannelsPerFrame = HUSH_CHANNELS;
    f.mBitsPerChannel = 32;
    return f;
}

// Copie une valeur de taille fixe. outData == NULL : on ne demande que la taille.
#define RETURN_VALUE(type, expr)                                         \
    do {                                                                 \
        *outSize = sizeof(type);                                         \
        if (outData) {                                                   \
            if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
            *(type *)outData = (expr);                                   \
        }                                                                \
        return noErr;                                                    \
    } while (0)

// Copie un tableau d'AudioObjectID (tronqué à la taille fournie).
static OSStatus ReturnIDs(const AudioObjectID *ids, UInt32 count, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    if (!outData) { *outSize = count * sizeof(AudioObjectID); return noErr; }
    UInt32 n = inDataSize / sizeof(AudioObjectID);
    if (n > count) n = count;
    memcpy(outData, ids, n * sizeof(AudioObjectID));
    *outSize = n * sizeof(AudioObjectID);
    return noErr;
}

static OSStatus GetProp(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qualSize, const void *qual,
                        UInt32 inDataSize, UInt32 *outSize, void *outData) {
    const AudioObjectID deviceList[] = {kObjectID_Device};
    const AudioObjectID streamList[] = {kObjectID_Stream};
    switch (obj) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(HUSH_MANUFACTURER));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            return ReturnIDs(deviceList, 1, inDataSize, outSize, outData);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qualSize != sizeof(CFStringRef) || qual == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)qual;
            AudioObjectID found = (uid && CFStringCompare(uid, CFSTR(HUSH_DEVICE_UID), 0) == kCFCompareEqualTo)
                                      ? kObjectID_Device : kAudioObjectUnknown;
            RETURN_VALUE(AudioObjectID, found);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
        default: return kAudioHardwareUnknownPropertyError;
        }

    case kObjectID_Device: {
        bool output = a->mScope == kAudioObjectPropertyScopeOutput;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName: RETURN_VALUE(CFStringRef, CFSTR(HUSH_DEVICE_NAME));
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR(HUSH_MANUFACTURER));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            return ReturnIDs(streamList, output ? 0 : 1, inDataSize, outSize, outData);
        case kAudioObjectPropertyControlList: return ReturnIDs(NULL, 0, inDataSize, outSize, outData);
        case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, CFSTR(HUSH_DEVICE_UID));
        case kAudioDevicePropertyModelUID: RETURN_VALUE(CFStringRef, CFSTR(HUSH_MODEL_UID));
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: return ReturnIDs(deviceList, 1, inDataSize, outSize, outData);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOClients > 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_VALUE(UInt32, output ? 0 : 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, HUSH_SAMPLE_RATE);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = {HUSH_SAMPLE_RATE, HUSH_SAMPLE_RATE};
            RETURN_VALUE(AudioValueRange, r);
        }
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kZeroTimeStampPeriod);
        case kAudioDevicePropertyClockIsStable: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (!outData) { *outSize = 2 * sizeof(UInt32); return noErr; }
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 1;
            *outSize = 2 * sizeof(UInt32);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + sizeof(AudioChannelDescription));
            *outSize = size;
            if (!outData) return noErr;
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *l = (AudioChannelLayout *)outData;
            memset(l, 0, size);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = 1;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    case kObjectID_Stream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: return ReturnIDs(NULL, 0, inDataSize, outSize, outData);
        case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, 1);   // 1 = entrée
        case kAudioStreamPropertyTerminalType: RETURN_VALUE(UInt32, kAudioStreamTerminalTypeMicrophone);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: RETURN_VALUE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r;
            r.mFormat = StreamFormat();
            r.mSampleRateRange.mMinimum = HUSH_SAMPLE_RATE;
            r.mSampleRateRange.mMaximum = HUSH_SAMPLE_RATE;
            RETURN_VALUE(AudioStreamRangedDescription, r);
        }
        default: return kAudioHardwareUnknownPropertyError;
        }

    default:
        return kAudioHardwareBadObjectError;
    }
}

static Boolean Hush_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)pid;
    if (d != gDriverRef || a == NULL) return false;
    UInt32 size = 0;
    if (a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice && obj == kObjectID_PlugIn) return true;
    return GetProp(obj, a, 0, NULL, 0, &size, NULL) == noErr;
}

static OSStatus Hush_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid,
                                        const AudioObjectPropertyAddress *a, Boolean *outSettable) {
    (void)pid;
    if (d != gDriverRef || a == NULL || outSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!Hush_HasProperty(d, obj, pid, a)) return kAudioHardwareUnknownPropertyError;
    // Formats et fréquence "réglables" pour que les clients puissent les écrire : seule la valeur
    // actuelle est acceptée.
    *outSettable = (obj == kObjectID_Stream && (a->mSelector == kAudioStreamPropertyVirtualFormat ||
                                                a->mSelector == kAudioStreamPropertyPhysicalFormat));
    return noErr;
}

static OSStatus Hush_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                         UInt32 qualSize, const void *qual, UInt32 *outSize) {
    (void)pid;
    if (d != gDriverRef || a == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    if (a->mSelector == kAudioPlugInPropertyTranslateUIDToDevice && obj == kObjectID_PlugIn) {
        *outSize = sizeof(AudioObjectID);
        return noErr;
    }
    return GetProp(obj, a, qualSize, qual, 0, outSize, NULL);
}

static OSStatus Hush_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                     UInt32 qualSize, const void *qual, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    (void)pid;
    if (d != gDriverRef || a == NULL || outSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    return GetProp(obj, a, qualSize, qual, inDataSize, outSize, outData);
}

static OSStatus Hush_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a,
                                     UInt32 qualSize, const void *qual, UInt32 inDataSize, const void *inData) {
    (void)pid; (void)qualSize; (void)qual;
    if (d != gDriverRef || a == NULL) return kAudioHardwareIllegalOperationError;
    if (obj == kObjectID_Stream && (a->mSelector == kAudioStreamPropertyVirtualFormat ||
                                    a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription) || inData == NULL) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription *f = inData;
        AudioStreamBasicDescription cur = StreamFormat();
        if (f->mSampleRate != cur.mSampleRate || f->mFormatID != cur.mFormatID || f->mChannelsPerFrame != cur.mChannelsPerFrame ||
            f->mBitsPerChannel != cur.mBitsPerChannel)
            return kAudioDeviceUnsupportedFormatError;
        return noErr;
    }
    return Hush_HasProperty(d, obj, pid, a) ? kAudioHardwareUnsupportedOperationError : kAudioHardwareUnknownPropertyError;
}

// ---------------------------------------------------------------------------------------------
// IO
// ---------------------------------------------------------------------------------------------

static OSStatus Hush_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    OpenSharedMemory();   // au cas où elle n'a pas pu être créée à l'initialisation
    pthread_mutex_lock(&gStateMutex);
    if (gIOClients == 0) {
        gAnchorHostTime = mach_absolute_time();
        gTimeStampCount = 0;
        gNeedResync = true;
    }
    gIOClients++;
    hush_shm_t *s = atomic_load(&gShm);
    if (s) atomic_store(&s->clientsRunning, gIOClients);
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus Hush_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOClients > 0) gIOClients--;
    hush_shm_t *s = atomic_load(&gShm);
    if (s) atomic_store(&s->clientsRunning, gIOClients);
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus Hush_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
                                      Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    // Horloge nominale à 48 kHz dérivée de l'horloge hôte. Appelée uniquement par le thread IO.
    Float64 ticksPerPeriod = gHostTicksPerFrame * kZeroTimeStampPeriod;
    UInt64 now = mach_absolute_time();
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gTimeStampCount + 1) * ticksPerPeriod);
    if (next <= now) gTimeStampCount++;
    *outSampleTime = (Float64)(gTimeStampCount * kZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimeStampCount * ticksPerPeriod);
    *outSeed = 1;
    return noErr;
}

static OSStatus Hush_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op,
                                       Boolean *outWillDo, Boolean *outInPlace) {
    (void)client;
    if (d != gDriverRef || dev != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (outWillDo) *outWillDo = (op == kAudioServerPlugInIOOperationReadInput);
    if (outInPlace) *outInPlace = true;
    return noErr;
}

static OSStatus Hush_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 c, UInt32 op, UInt32 n,
                                      const AudioServerPlugInIOCycleInfo *info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && dev == kObjectID_Device) ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus Hush_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 c, UInt32 op, UInt32 n,
                                    const AudioServerPlugInIOCycleInfo *info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && dev == kObjectID_Device) ? noErr : kAudioHardwareBadObjectError;
}

// Lecture temps réel : pas d'allocation, pas de verrou, pas d'appel système.
static OSStatus Hush_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client,
                                   UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info,
                                   void *ioMain, void *ioSecondary) {
    (void)client; (void)info; (void)ioSecondary;
    if (d != gDriverRef || dev != kObjectID_Device || stream != kObjectID_Stream) return kAudioHardwareBadObjectError;
    if (op != kAudioServerPlugInIOOperationReadInput || ioMain == NULL) return noErr;
    float *out = (float *)ioMain;
    hush_shm_t *s = atomic_load_explicit(&gShm, memory_order_acquire);
    UInt64 now = mach_absolute_time();
    if (s == NULL) {
        memset(out, 0, frames * sizeof(float) * HUSH_CHANNELS);
        return noErr;
    }
    atomic_store_explicit(&s->readerHeartbeat, now, memory_order_relaxed);
    UInt64 hb = atomic_load_explicit(&s->writerHeartbeat, memory_order_acquire);
    if (hb == 0 || now < hb || now - hb > gWriterTimeoutTicks || frames > HUSH_RING_FRAMES / 2) {
        // L'app ne tourne pas : silence, et recalage à la reprise.
        memset(out, 0, frames * sizeof(float) * HUSH_CHANNELS);
        gNeedResync = true;
        return noErr;
    }
    // Latence visée : un buffer client + une marge fixée par l'app. Après un trou, on joue du silence
    // jusqu'à avoir de nouveau cette marge (ré-amorçage), au lieu d'enchaîner les micro-coupures.
    UInt32 margin = atomic_load_explicit(&s->targetFill, memory_order_relaxed);
    UInt32 tolerance = atomic_load_explicit(&s->maxFill, memory_order_relaxed);
    if (margin > HUSH_RING_FRAMES / 4) margin = HUSH_RING_FRAMES / 4;
    if (tolerance > HUSH_RING_FRAMES / 4) tolerance = HUSH_RING_FRAMES / 4;
    UInt64 want = (UInt64)frames + margin;
    UInt64 w = atomic_load_explicit(&s->ring.writePos, memory_order_acquire);
    UInt64 rd = atomic_load_explicit(&s->ring.readPos, memory_order_relaxed);
    UInt64 fill = w > rd ? w - rd : 0;
    if (w < rd || fill > HUSH_RING_FRAMES - frames) {   // écrasé ou incohérent : on repart de la tête d'écriture
        ring_set_read(&s->ring, w);
        gNeedResync = true;
        fill = 0;
    }
    if (gNeedResync) {
        // Ré-amorçage : on attend d'avoir `want` frames, sans jamais relire du son déjà joué
        // (fill >= want garantit w - want >= rd).
        if (fill >= want) {
            ring_set_read(&s->ring, w - want);
            fill = want;
            gNeedResync = false;
        } else {
            memset(out, 0, frames * sizeof(float) * HUSH_CHANNELS);
            atomic_store_explicit(&s->lastFill, (UInt32)fill, memory_order_relaxed);
            return noErr;
        }
    } else if (fill > want + tolerance) {
        ring_set_read(&s->ring, w - want);   // trop de retard accumulé : on jette l'excédent
        fill = want;
    }
    atomic_store_explicit(&s->lastFill, (UInt32)fill, memory_order_relaxed);
    UInt32 got = ring_read_avail(&s->ring, out, frames);
    if (got < frames) {
        atomic_fetch_add_explicit(&s->underruns, 1, memory_order_relaxed);
        gNeedResync = true;
    }
    return noErr;
}
