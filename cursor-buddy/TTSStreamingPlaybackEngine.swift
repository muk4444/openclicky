//
//  TTSStreamingPlaybackEngine.swift
//  cursor-buddy
//
//  Shared AVAudioEngine + AVAudioPlayerNode playback plumbing used by the
//  streaming TTS clients (ElevenLabs, Cartesia, Microsoft Edge, OpenAI
//  Realtime, Deepgram). Each client owns its own engine/player instance
//  and lifecycle; these are the pure scheduling/draining/stopping
//  primitives that were previously duplicated per client.
//

import AVFoundation
import Combine
import Foundation
import os

@MainActor
enum TTSStreamingPlaybackEngine {
    static func makeStreamFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    @discardableResult
    static func scheduleSamples(
        _ samples: [Int16],
        on player: AVAudioPlayerNode,
        format: AVAudioFormat,
        startPlaybackIfNeeded: Bool = true
    ) -> AVAudioFramePosition {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return 0
        }
        let scale: Float = (1.0 / 32_768.0) * Float(AppBundleConfiguration.voicePlaybackVolume())
        for index in samples.indices {
            channel[index] = Float(samples[index]) * scale
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        // The player may have been detached between sentence enqueue
        // and this scheduling pass (e.g. user spoke again, which calls
        // `stopPlayback` → `stopPlaybackInternal` → engine teardown).
        // `AVAudioPlayerNode.engine` is a weak reference; once the
        // engine deallocates, `engine` returns nil. Calling `play()` on
        // an engineless node throws `_engine != nil` and crashes the
        // process — guard before scheduling and starting.
        guard let engine = player.engine else { return 0 }
        // If the engine isn't running, drop this buffer rather than
        // restart mid-stream — restarting AVAudioEngine while samples
        // are queued causes audible skipping/jumping. The streaming
        // session owner is responsible for keeping the engine running
        // for the full response; if it stopped, the response is over.
        guard engine.isRunning else { return 0 }
        TTSPlaybackLevelTap.attachIfNeeded(to: engine)
        let playerID = ObjectIdentifier(player)
        PendingBufferTracker.shared.increment(playerID)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            PendingBufferTracker.shared.decrement(playerID)
        }
        if startPlaybackIfNeeded && !player.isPlaying {
            player.play()
        }
        return AVAudioFramePosition(buffer.frameLength)
    }

    /// Time left for the output device to finish the final buffer.
    private static let playbackTailNanoseconds: UInt64 = 200_000_000

    static func waitForPlaybackToDrain(
        _ player: AVAudioPlayerNode,
        scheduledFrameCount: AVAudioFramePosition,
        sampleRate: Double
    ) async {
        guard scheduledFrameCount > 0 else {
            stopPlayerIfAttached(player)
            return
        }

        // Wait until every scheduled buffer has actually been played back.
        // Comparing the player's rendered sample time against the scheduled
        // frame count clipped the tail of streamed replies: sample time keeps
        // advancing while the queue runs dry between late-arriving sentence
        // fetches, so that silence was counted as played audio. The
        // wall-clock deadline remains as a conservative stuck-device guard.
        let playerID = ObjectIdentifier(player)
        let expectedDuration = Double(scheduledFrameCount) / sampleRate
        let deadline = Date().addingTimeInterval(max(expectedDuration + 3.0, 3.0))

        while !Task.isCancelled {
            if PendingBufferTracker.shared.pendingCount(playerID) == 0 {
                break
            }

            if Date() >= deadline {
                break
            }

            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        // The last buffer is reported as played when it has been rendered,
        // which is slightly before it has left the output device. Stopping
        // right away cuts that tail off mid-wave and is heard as a click.
        if !Task.isCancelled {
            try? await Task.sleep(nanoseconds: playbackTailNanoseconds)
        }

        stopPlayerIfAttached(player)
        TTSPlaybackLevelMonitor.shared.reset()
    }

    nonisolated static func stopPlayerIfAttached(_ player: AVAudioPlayerNode) {
        guard player.engine != nil else { return }
        player.stop()
    }

}

/// Loudness of OpenClicky's spoken output, for UI meters such as the notch
/// waveform. Values are roughly 0...1, in the same range the microphone
/// power level uses.
@MainActor
final class TTSPlaybackLevelMonitor: ObservableObject {
    static let shared = TTSPlaybackLevelMonitor()

    @Published private(set) var level: CGFloat = 0

    /// Fast attack, slower release, so the bars follow speech without flicker.
    func update(_ newLevel: CGFloat) {
        level = newLevel > level ? newLevel : level * 0.8 + newLevel * 0.2
    }

    func reset() {
        level = 0
    }
}

/// Installs one output tap per playback engine to feed
/// `TTSPlaybackLevelMonitor`. Kept nonisolated because the tap block runs on
/// an audio thread.
nonisolated enum TTSPlaybackLevelTap {
    nonisolated(unsafe) private static let tappedEngines = NSHashTable<AVAudioEngine>.weakObjects()
    private static let lock = NSLock()

    static func attachIfNeeded(to engine: AVAudioEngine) {
        lock.lock()
        let alreadyTapped = tappedEngines.contains(engine)
        if !alreadyTapped {
            tappedEngines.add(engine)
        }
        lock.unlock()
        guard !alreadyTapped else { return }

        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        mixer.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            let level = rootMeanSquareLevel(of: buffer)
            Task { @MainActor in
                TTSPlaybackLevelMonitor.shared.update(level)
            }
        }
    }

    private static func rootMeanSquareLevel(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for frame in 0..<frameCount {
            let sample = channel[frame]
            sumOfSquares += sample * sample
        }
        let rootMeanSquare = (sumOfSquares / Float(frameCount)).squareRoot()
        return CGFloat(min(1, rootMeanSquare * 2))
    }
}

/// Counts buffers scheduled on each player that have not finished playing.
/// Buffer completion handlers fire on an audio thread, so access is locked.
/// An unfair lock is used because it donates priority to the holder, which
/// avoids priority inversions when the main thread polls the count.
nonisolated final class PendingBufferTracker: @unchecked Sendable {
    static let shared = PendingBufferTracker()

    private let counts = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Int]())

    func increment(_ playerID: ObjectIdentifier) {
        counts.withLock { $0[playerID, default: 0] += 1 }
    }

    func decrement(_ playerID: ObjectIdentifier) {
        counts.withLock { state in
            let remaining = (state[playerID] ?? 1) - 1
            state[playerID] = remaining > 0 ? remaining : nil
        }
    }

    func pendingCount(_ playerID: ObjectIdentifier) -> Int {
        counts.withLock { $0[playerID] ?? 0 }
    }
}
