// Création d'un tap global (classe Objective-C CATapDescription).
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

AudioObjectID make_global_tap(AudioObjectID exclude, CFStringRef *outUUID) {
    CATapDescription *d = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[ @(exclude) ]];
    d.UUID = [NSUUID UUID];
    d.muteBehavior = CATapUnmuted;
    d.privateTap = YES;
    AudioObjectID tap = 0;
    if (AudioHardwareCreateProcessTap(d, &tap) != noErr) return 0;
    *outUUID = (__bridge_retained CFStringRef)d.UUID.UUIDString;
    return tap;
}

void destroy_tap(AudioObjectID tap) { AudioHardwareDestroyProcessTap(tap); }
