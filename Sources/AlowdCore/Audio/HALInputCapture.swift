import Foundation
#if os(macOS)
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import IOKit

/// Picks the microphone to record from when the system default is a poor one.
enum AudioInputDevices {
    /// The Mac's built-in microphone when the default input is a Bluetooth
    /// headset; nil means record from the default input.
    ///
    /// Opening a Bluetooth headset's microphone switches it from music to
    /// call mode: whatever is playing drops to phone quality until the mic
    /// closes, and the first second of speech is lost while it switches. The
    /// built-in mic avoids both. It is skipped when the lid is closed, since
    /// it then records silence.
    static func builtInReplacingBluetoothDefault() -> AudioDeviceID? {
        guard let defaultInput = defaultInputDevice(), isBluetooth(defaultInput) else { return nil }
        guard !isLidClosed() else { return nil }
        return allDevices().first { device in
            transportType(of: device) == kAudioDeviceTransportTypeBuiltIn
                && hasInputStreams(device)
                && isAlive(device)
        }
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        let device: AudioDeviceID? = property(
            of: AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice
        )
        return device.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let transport = transportType(of: device)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(of device: AudioDeviceID) -> UInt32? {
        property(of: device, kAudioDevicePropertyTransportType)
    }

    private static func isAlive(_ device: AudioDeviceID) -> Bool {
        let alive: UInt32? = property(of: device, kAudioDevicePropertyDeviceIsAlive)
        return alive == 1
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func allDevices() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func property<Value>(
        of object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (state?.takeRetainedValue() as? Bool) ?? false
    }
}

/// Records one specific input device through a bare HAL output unit.
///
/// AVAudioEngine cannot: it always opens the system default devices. Asking
/// its input node for another device is accepted and then ignored, so with
/// Bluetooth headphones as the default it still switches them to call mode
/// and never delivers a buffer.
final class HALInputCapture: @unchecked Sendable {
    /// Buffers are handed on at about the engine tap's size, so consumers see
    /// the same rhythm whichever capture is running.
    private static let deliveryFrames: AVAudioFrameCount = 4096
    private static let maxFramesPerSlice: UInt32 = 4096

    /// Mono Float32 at the device's own rate; the unit cannot resample input.
    let format: AVAudioFormat
    private let unit: AudioUnit
    private let renderBuffer: AVAudioPCMBuffer
    private let pending: AVAudioPCMBuffer
    /// Set once before the unit starts; only the render thread reads it after.
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let lock = NSLock()
    private var disposed = false

    /// Nil when the device cannot be opened for input.
    init?(device: AudioDeviceID) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &instance) == noErr,
              let unit = instance else { return nil }

        func set<Value: BitwiseCopyable>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: Value) -> Bool {
            var value = value
            return AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<Value>.size)) == noErr
        }

        // Element 1 is the unit's input side; element 0, its output, stays off.
        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1)),
              set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0)),
              set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device),
              set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, Self.maxFramesPerSlice),
              AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &formatSize) == noErr,
              deviceFormat.mSampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: deviceFormat.mSampleRate, channels: 1, interleaved: false),
              set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription.pointee),
              let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maxFramesPerSlice),
              let pending = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.deliveryFrames + Self.maxFramesPerSlice)
        else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        self.unit = unit
        self.format = format
        self.renderBuffer = renderBuffer
        self.pending = pending

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                Unmanaged<HALInputCapture>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr, AudioUnitInitialize(unit) == noErr else {
            dispose()
            return nil
        }
    }

    deinit {
        dispose()
    }

    /// Starts delivering buffers of `format` to `onBuffer` on the audio thread.
    func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> Bool {
        self.onBuffer = onBuffer
        return AudioOutputUnitStart(unit) == noErr
    }

    /// Stops and releases the device; the capture cannot be restarted.
    func stop() {
        dispose()
    }

    private func dispose() {
        lock.lock()
        let alreadyDisposed = disposed
        disposed = true
        lock.unlock()
        guard !alreadyDisposed else { return }
        // Stop returns once the render callback has finished, so nothing
        // touches this object after the unit is gone.
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// Runs on the audio thread: pulls the new frames and hands them on in
    /// delivery-sized buffers.
    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard frames <= renderBuffer.frameCapacity else { return noErr }
        renderBuffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, renderBuffer.mutableAudioBufferList)
        guard status == noErr,
              let source = renderBuffer.floatChannelData?[0],
              let destination = pending.floatChannelData?[0] else { return status }

        destination.advanced(by: Int(pending.frameLength)).update(from: source, count: Int(frames))
        pending.frameLength += frames
        if pending.frameLength >= Self.deliveryFrames {
            onBuffer?(pending)
            pending.frameLength = 0
        }
        return noErr
    }
}
#endif
