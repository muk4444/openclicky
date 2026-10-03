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

        stopPlayerIfAttached(player)
    }

    nonisolated static func stopPlayerIfAttached(_ player: AVAudioPlayerNode) {
        guard player.engine != nil else { return }
        player.stop()
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
