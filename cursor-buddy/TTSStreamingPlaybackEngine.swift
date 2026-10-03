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
        TTSPlaybackLevelMonitor.shared.noteScheduled(samples, on: player, sampleRate: format.sampleRate)
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
        TTSPlaybackLevelMonitor.shared.reset(ifTracking: player)
    }

    nonisolated static func stopPlayerIfAttached(_ player: AVAudioPlayerNode) {
        guard player.engine != nil else { return }
        player.stop()
    }

}

/// Loudness of OpenClicky's spoken output, for UI meters such as the cursor
/// waveform. Values are roughly 0...1, in the same range the microphone
/// power level uses.
///
/// The level is derived from the samples as they are scheduled and looked up
/// by the player's playback position. It deliberately does not tap the audio
/// output: the meter must never touch the signal path.
@MainActor
final class TTSPlaybackLevelMonitor: ObservableObject {
    static let shared = TTSPlaybackLevelMonitor()

    @Published private(set) var level: CGFloat = 0

    private struct Segment {
        let startFrame: AVAudioFramePosition
        let framesPerStep: Int
        let levels: [CGFloat]

        var endFrame: AVAudioFramePosition {
            startFrame + AVAudioFramePosition(levels.count * framesPerStep)
        }
    }

    private static let stepsPerSecond: Double = 50
    private static let refreshInterval: TimeInterval = 1.0 / 30.0

    private weak var player: AVAudioPlayerNode?
    private var segments: [Segment] = []
    private var scheduledFrameCount: AVAudioFramePosition = 0
    private var refreshTimer: Timer?

    /// Records the loudness envelope of samples about to be played.
    func noteScheduled(_ samples: [Int16], on player: AVAudioPlayerNode, sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        if self.player !== player {
            self.player = player
            segments.removeAll(keepingCapacity: true)
            scheduledFrameCount = 0
        }

        let framesPerStep = max(1, Int(sampleRate / Self.stepsPerSecond))
        var levels: [CGFloat] = []
        levels.reserveCapacity(samples.count / framesPerStep + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + framesPerStep, samples.count)
            var sumOfSquares: Float = 0
            for sampleIndex in index..<end {
                let value = Float(samples[sampleIndex]) / 32_768
                sumOfSquares += value * value
            }
            let rootMeanSquare = (sumOfSquares / Float(end - index)).squareRoot()
            levels.append(CGFloat(min(1, rootMeanSquare * 2)))
            index = end
        }

        segments.append(Segment(startFrame: scheduledFrameCount, framesPerStep: framesPerStep, levels: levels))
        scheduledFrameCount += AVAudioFramePosition(samples.count)
        startRefreshTimerIfNeeded()
    }

    /// Clears the meter once `player` has finished. Ignored when a newer
    /// player has already taken over.
    func reset(ifTracking player: AVAudioPlayerNode) {
        guard self.player === player else { return }
        self.player = nil
        segments.removeAll(keepingCapacity: true)
        scheduledFrameCount = 0
        refreshTimer?.invalidate()
        refreshTimer = nil
        level = 0
    }

    private func startRefreshTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLevel()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshLevel() {
        guard let player,
              player.engine != nil,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            apply(0)
            return
        }

        let frame = playerTime.sampleTime
        segments.removeAll { $0.endFrame <= frame }
        guard let segment = segments.first, frame >= segment.startFrame else {
            apply(0)
            return
        }
        let stepIndex = Int(frame - segment.startFrame) / segment.framesPerStep
        apply(stepIndex < segment.levels.count ? segment.levels[stepIndex] : 0)
    }

    /// Fast attack, slower release, so the bars follow speech without flicker.
    private func apply(_ newLevel: CGFloat) {
        let smoothed = newLevel > level ? newLevel : level * 0.8 + newLevel * 0.2
        let nextLevel = smoothed < 0.001 ? 0 : smoothed
        if nextLevel != level {
            level = nextLevel
        }
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
