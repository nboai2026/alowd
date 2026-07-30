import Foundation
import Testing
@testable import AlowdCore

struct AudioRecorderTests {
    @Test func beginWhileRecordingThrowsAlreadyRecording() throws {
        let recorder = AudioRecorder()
        defer { try? recorder.discardTemporaryRecording() }

        do {
            _ = try recorder.beginTemporaryRecording()
        } catch AudioRecorderError.failedToStart {
            // This machine/CI job has no usable audio input for AVAudioRecorder;
            // the contract-error tests below still run everywhere.
            return
        }
        #expect(recorder.isRecording, "Recorder must report recording after begin")
        #expect(throws: AudioRecorderError.alreadyRecording, "A second begin must be rejected while recording") {
            _ = try recorder.beginTemporaryRecording()
        }
    }

    @Test func finishWithoutBeginThrowsNotRecording() {
        let recorder = AudioRecorder()
        #expect(throws: AudioRecorderError.notRecording, "Finishing an idle recorder must throw notRecording") {
            _ = try recorder.finishTemporaryRecording()
        }
    }

    @Test func finishHandsOverFileAndLeavesRecorderIdle() throws {
        let recorder = AudioRecorder()
        let started: URL
        do {
            started = try recorder.beginTemporaryRecording()
        } catch AudioRecorderError.failedToStart {
            // No usable audio input on this machine; see note above.
            return
        }
        let finished = try recorder.finishTemporaryRecording()
        defer { try? FileManager.default.removeItem(at: finished) }

        #expect(finished == started, "Finish must return the file begin created")
        #expect(!recorder.isRecording, "Recorder must be idle after finish")
        #expect(FileManager.default.fileExists(atPath: finished.path), "The finished recording must exist on disk")

        // The finished recording now belongs to the caller: a later discard
        // must be a no-op that cannot delete it.
        try recorder.discardTemporaryRecording()
        #expect(FileManager.default.fileExists(atPath: finished.path), "Discard after finish must not delete the handed-over recording")
    }

    @Test func discardIsIdempotentAndDeletesTemporaryAudio() throws {
        let recorder = AudioRecorder()

        // Discarding an idle recorder is a harmless no-op.
        try recorder.discardTemporaryRecording()

        let audioFile: URL
        do {
            audioFile = try recorder.beginTemporaryRecording()
        } catch AudioRecorderError.failedToStart {
            // No usable audio input on this machine; see note above.
            return
        }
        try recorder.discardTemporaryRecording()
        #expect(!recorder.isRecording, "Recorder must be idle after discard")
        #expect(!FileManager.default.fileExists(atPath: audioFile.path), "Discard must delete the in-progress temp audio")

        // A second discard after cleanup must remain a no-op.
        try recorder.discardTemporaryRecording()
    }
}
