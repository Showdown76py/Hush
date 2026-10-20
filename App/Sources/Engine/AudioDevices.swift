#if canImport(HushRT)
import HushRT
#endif
import CoreAudio
import Foundation

/// Un périphérique audio d'entrée, tel que présenté dans les réglages.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isVirtual: Bool
}

/// Accès en lecture au modèle d'objets Core Audio (HAL), hors temps réel.
enum AudioDevices {
    static let hushDeviceUID = "HushMicrophone_UID"
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
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

    /// Entrées audio utilisables comme source (le micro virtuel Hush est exclu pour éviter une boucle).
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

    /// Choisit le micro source : celui demandé s'il existe, sinon l'entrée par défaut du système
    /// (sauf si c'est le micro Hush lui-même), sinon le micro intégré.
    static func resolveSource(preferredUID: String?) -> AudioInputDevice? {
        let inputs = inputDevices()
        if let preferredUID, !preferredUID.isEmpty, let d = inputs.first(where: { $0.uid == preferredUID }) { return d }
        if let def = defaultDevice(input: true), let d = inputs.first(where: { $0.id == def }) { return d }
        return inputs.first(where: \.isBuiltIn) ?? inputs.first(where: { !$0.isVirtual }) ?? inputs.first
    }

    /// Fixe la taille de buffer IO de ce processus pour un périphérique (réduit la latence).
    @discardableResult
    static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) -> OSStatus {
        var a = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// Abonnement à une propriété Core Audio ; l'écoute s'arrête à la libération de l'objet.
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
