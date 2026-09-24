import Foundation
import Testing
@testable import AlowdCore

/// StreamingAudioRecorder must honor the exact TemporaryAudioRecorder
/// contract AudioRecorder established (same errors, same handover rules),
/// while adding the live sample/level seam.
struct StreamingAudioRecorderTests {
    @Test func finishWithoutBeginThrowsNotRecording() {
        let recorder = StreamingAudioRecorder()
        #expect(throws: AudioRecorderError.notRecording, "Finishing an idle recorder must throw notRecording") {
            _ = try recorder.finishTemporaryRecording()
        }
    }

    @Test func discardOnIdleRecorderIsANoOp() throws {
        let recorder = StreamingAudioRecorder()
        try recorder.discardTemporaryRecording()
        try recorder.discardTemporaryRecording()
        #expect(!recorder.isRecording)
    }

    @Test func recordingLifecycleMatchesAudioRecorderContract() throws {
        let recorder = StreamingAudioRecorder()
        defer { try? recorder.discardTemporaryRecording() }

        let started: URL
        do {
            started = try recorder.beginTemporaryRecording()
        } catch AudioRecorderError.failedToStart {
            // This machine/CI job has no usable audio input for AVAudioEngine;
            // the lifecycle contract is still covered by the other tests.
            return
        }

        #expect(recorder.isRecording, "Recorder must report recording after begin")
        #expect(throws: AudioRecorderError.alreadyRecording, "A second begin must be rejected while recording") {
            _ = try recorder.beginTemporaryRecording()
        }

        let finished = try recorder.finishTemporaryRecording()
        defer { try? FileManager.default.removeItem(at: finished) }

        #expect(finished == started, "Finish must return the file begin created")
        #expect(!recorder.isRecording, "Recorder must be idle after finish")
        #expect(FileManager.default.fileExists(atPath: finished.path), "The finished recording must exist on disk")

        // The finished recording belongs to the caller: discard must not
        // delete it.
        try recorder.discardTemporaryRecording()
        #expect(FileManager.default.fileExists(atPath: finished.path), "Discard after finish must not delete the handed-over recording")
    }

    @Test func discardDeletesInProgressTemporaryAudio() throws {
        let recorder = StreamingAudioRecorder()
        let audioFile: URL
        do {
            audioFile = try recorder.beginTemporaryRecording()
        } catch AudioRecorderError.failedToStart {
            return
        }
        try recorder.discardTemporaryRecording()
        #expect(!recorder.isRecording, "Recorder must be idle after discard")
        #expect(!FileManager.default.fileExists(atPath: audioFile.path), "Discard must delete the in-progress temp audio")
        try recorder.discardTemporaryRecording()
    }
}

struct AudioLevelMeterTests {
    @Test func rmsOfEmptyBufferIsZero() {
        #expect(AudioLevelMeter.rms([]) == 0)
    }

    @Test func rmsOfConstantSignalIsItsMagnitude() {
        let level = AudioLevelMeter.rms([Float](repeating: 0.5, count: 1_000))
        #expect(abs(level - 0.5) < 0.0001, "RMS of a constant 0.5 signal is 0.5")
    }

    @Test func rmsOfSilenceIsZero() {
        #expect(AudioLevelMeter.rms([Float](repeating: 0, count: 100)) == 0)
    }
}

struct InputLevelBroadcasterTests {
    @Test func yieldsLevelsToSubscriberAndFinishes() async {
        let broadcaster = InputLevelBroadcaster()
        let stream = broadcaster.stream()

        let collector = Task {
            var received: [Float] = []
            for await level in stream {
                received.append(level)
            }
            return received
        }

        // Give the subscriber a beat to register before yielding.
        try? await Task.sleep(nanoseconds: 20_000_000)
        broadcaster.yield(0.25)
        broadcaster.yield(0.5)
        broadcaster.finish()

        let received = await collector.value
        #expect(received == [0.25, 0.5], "Subscriber must receive every yielded level, then finish")
    }

    @Test func supportsMultipleIndependentSubscribers() async {
        let broadcaster = InputLevelBroadcaster()
        let first = broadcaster.stream()
        let second = broadcaster.stream()

        let firstTask = Task { await first.reduce(into: [Float]()) { $0.append($1) } }
        let secondTask = Task { await second.reduce(into: [Float]()) { $0.append($1) } }

        try? await Task.sleep(nanoseconds: 20_000_000)
        broadcaster.yield(0.75)
        broadcaster.finish()

        #expect(await firstTask.value == [0.75])
        #expect(await secondTask.value == [0.75])
    }

    @Test func yieldAfterFinishReachesNoOne() async {
        let broadcaster = InputLevelBroadcaster()
        let stream = broadcaster.stream()
        let task = Task { await stream.reduce(into: [Float]()) { $0.append($1) } }

        try? await Task.sleep(nanoseconds: 20_000_000)
        broadcaster.finish()
        broadcaster.yield(0.9)

        #expect(await task.value == [], "Levels yielded after finish must be dropped")
    }
}

struct LiveSampleBufferTests {
    @Test func keepsTheWholeRecordingForSlicing() {
        let buffer = LiveSampleBuffer(maxSamples: 10)
        buffer.append([1, 2, 3])
        buffer.append([4, 5])
        #expect(buffer.count == 5)
        #expect(buffer.samples(from: 1, to: 4) == [2, 3, 4])
        #expect(buffer.samples(from: 3, to: 99) == [4, 5], "A range past the end is clamped")
        #expect(buffer.samples(from: 5, to: 5).isEmpty)
    }

    @Test func overflowStopsAccumulatingAndIsReported() {
        let buffer = LiveSampleBuffer(maxSamples: 4)
        buffer.append([1, 2, 3])
        #expect(!buffer.hasOverflowed)
        buffer.append([4, 5, 6])
        #expect(buffer.hasOverflowed, "Streaming must know its copy of the recording is incomplete")
        #expect(buffer.count == 3, "Nothing past the cap is kept")
    }

    @Test func silenceIsJudgedAgainstTheRecordingsOwnSpeakingLevel() {
        let frame = LiveSampleBuffer.frameLength
        let buffer = LiveSampleBuffer()
        buffer.append([Float](repeating: 0.3, count: frame * 20))   // speech
        buffer.append([Float](repeating: 0.01, count: frame * 10))  // room noise
        #expect(!buffer.isSilent(from: 0, to: frame * 20))
        #expect(buffer.isSilent(from: frame * 20, to: frame * 30), "Noise far below the speaking level is silence")
        #expect(!buffer.isSilent(from: frame * 15, to: frame * 30), "Any speech in the range makes it not silent")
    }

    @Test func quietVoiceStillCountsAsSpeech() {
        let frame = LiveSampleBuffer.frameLength
        let buffer = LiveSampleBuffer()
        buffer.append([Float](repeating: 0.03, count: frame * 20))
        buffer.append([Float](repeating: 0, count: frame * 10))
        #expect(!buffer.isSilent(from: 0, to: frame * 20), "A quiet speaker is measured against their own level")
        #expect(buffer.isSilent(from: frame * 20, to: frame * 30))
    }

    @Test func resetClearsEverything() {
        let buffer = LiveSampleBuffer(maxSamples: 2)
        buffer.append([1, 2, 3])
        buffer.reset()
        #expect(buffer.count == 0)
        #expect(!buffer.hasOverflowed)
    }
}
