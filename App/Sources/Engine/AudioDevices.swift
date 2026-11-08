#if canImport(HushRT)
import HushRT
#endif
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isVirtual: Bool
}

enum AudioDevices {
    static let hushDeviceUID = "HushMicrophone_UID"
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDeviceIDs() -> [AudioDeviceID] { objectIDs(system, kAudioHardwarePropertyDevices) }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// apps reading from a device, sorted. helper processes count as their app (Discord Helper -> Discord)
    static func appsReading(deviceUID: String) -> [String] {
        guard let device = device(uid: deviceUID) else { return [] }
        var names = Set<String>()
        for process in objectIDs(system, kAudioHardwarePropertyProcessObjectList)
        where objectIDs(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput).contains(device) {
            var a = address(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(process, &a, 0, nil, &size, &pid) == noErr, pid != getpid(),
                  let name = appName(pid: pid) else { continue }
            names.insert(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func appName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        let parts = path.split(separator: "/")
        // outermost .app, helpers live inside their app's bundle
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return (path as NSString).lastPathComponent }
        let url = URL(fileURLWithPath: "/" + parts[...i].joined(separator: "/"))
        let info = Bundle(url: url)?.localizedInfoDictionary ?? Bundle(url: url)?.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Float64? {
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// hush mic excluded since as a source it would loop on itself
    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID), uid != hushDeviceUID else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
            return AudioInputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                                    isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                                    isVirtual: transport == kAudioDeviceTransportTypeVirtual)
        }
    }

    static func device(uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var a = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static var isHushDevicePresent: Bool { device(uid: hushDeviceUID) != nil }

    /// if default input is the hush mic it's missing from `inputDevices()` so fall back to built-in mic
    static func resolveSource(preferredUID: String?) -> AudioInputDevice? {
        let inputs = inputDevices()
        if let preferredUID, !preferredUID.isEmpty, let d = inputs.first(where: { $0.uid == preferredUID }) { return d }
        if let def = defaultDevice(input: true), let d = inputs.first(where: { $0.id == def }) { return d }
        return inputs.first(where: \.isBuiltIn) ?? inputs.first(where: { !$0.isVirtual }) ?? inputs.first
    }

    /// buffer size only applies to this process, other apps unaffected
    static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) {
        var a = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// listening stops when the object is freed
final class AudioPropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, handler: @escaping () -> Void) {
        self.object = object
        address = AudioDevices.address(selector, scope)
        block = { _, _ in DispatchQueue.main.async(execute: handler) }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
}
