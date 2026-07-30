import Foundation
#if os(macOS)
import AVFoundation
#endif

public protocol TemporaryAudioRecorder: AnyObject, Sendable {
    var isRecording: Bool { get }
    func beginTemporaryRecording() throws -> URL
    func finishTemporaryRecording() throws -> URL
    func discardTemporaryRecording() throws
}

public enum AudioRecorderError: Error, LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case failedToStart(URL)
    case missingTemporaryAudioFile

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Recording is already running."
        case .notRecording:
            "Recording has not started."
        case .failedToStart(let url):
            "Could not start microphone recording at \(url.path)."
        case .missingTemporaryAudioFile:
            "Recording stopped, but the temporary audio file is missing."
        }
    }
}

public final class AudioRecorder: TemporaryAudioRecorder, @unchecked Sendable {
    private var temporaryAudioFile: URL?
    #if os(macOS)
    private var recorder: AVAudioRecorder?
    #endif
    public private(set) var isRecording = false

    public init() {}

    public func beginTemporaryRecording() throws -> URL {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alowd-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        #if os(macOS)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw AudioRecorderError.failedToStart(url)
        }
        self.recorder = recorder
        #else
        FileManager.default.createFile(atPath: url.path, contents: nil)
        #endif

        temporaryAudioFile = url
        isRecording = true
        return url
    }

    public func finishTemporaryRecording() throws -> URL {
        guard isRecording else { throw AudioRecorderError.notRecording }
        guard let finishedAudioFile = temporaryAudioFile else { throw AudioRecorderError.missingTemporaryAudioFile }

        #if os(macOS)
        recorder?.stop()
        recorder = nil
        #endif

        isRecording = false
        // The finished recording now belongs to the caller; clearing the
        // reference means a later cancel/discard can never delete it.
        temporaryAudioFile = nil
        guard FileManager.default.fileExists(atPath: finishedAudioFile.path) else {
            throw AudioRecorderError.missingTemporaryAudioFile
        }
        return finishedAudioFile
    }

    public func discardTemporaryRecording() throws {
        #if os(macOS)
        recorder?.stop()
        recorder = nil
        #endif
        isRecording = false

        guard let temporaryAudioFile else { return }
        if FileManager.default.fileExists(atPath: temporaryAudioFile.path) {
            try FileManager.default.removeItem(at: temporaryAudioFile)
        }
        self.temporaryAudioFile = nil
    }
}
