import AudioToolbox
import CoreAudio
import Foundation

/// Lowers the default output's volume while recording and puts it back exactly.
/// The original is kept in user defaults, so a crash mid-recording is undone at next launch.
/// shortcut: default output device only; per-device ducking when someone records with several outputs active.
public enum Ducker {
    private static let key = "glide.duckedVolume"

    public static func duck(to fraction: Float = 0.25) {
        guard UserDefaults.standard.object(forKey: key) == nil, let device = defaultOutput(), let volume = volume(of: device)
        else { return }
        UserDefaults.standard.set(["device": Int(device), "volume": Double(volume)], forKey: key)
        setVolume(volume * fraction, of: device)
    }

    public static func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: key),
            let device = saved["device"] as? Int, let volume = saved["volume"] as? Double
        else { return }
        setVolume(Float(volume), of: AudioDeviceID(device))
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func volume(of device: AudioDeviceID) -> Float? {
        var address = volumeAddress
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr ? volume : nil
    }

    private static func setVolume(_ volume: Float, of device: AudioDeviceID) {
        var address = volumeAddress
        var value = Float32(volume)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
