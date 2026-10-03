//
//  MistralTTSClient.swift
//  cursor-buddy
//

import AVFoundation
import Foundation

/// A voice returned by Mistral's `/v1/audio/voices` listing. Custom voices
/// are the ones the user cloned in Mistral Studio; presets ship with Voxtral.
nonisolated struct MistralVoiceOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isCustom: Bool
    let languages: [String]

    var subtitle: String {
        let kind = isCustom ? "Custom voice" : "Preset voice"
        guard !languages.isEmpty else { return kind }
        return "\(kind) · \(languages.joined(separator: ", "))"
    }
}

/// TTS provider for Mistral Voxtral, parallel to `CartesiaTTSClient`.
/// Posts each sentence to `/v1/audio/speech`, which answers with JSON
/// carrying base64 audio. The audio is requested as WAV so the sample
/// rate and sample format come from the file header instead of being
/// assumed, then normalised to mono Int16 at `streamSampleRate` for the
/// shared `StreamingTTSSession` pipeline.
@MainActor
final class MistralTTSClient: OpenClickyTTSClient {
    // Verified against https://docs.mistral.ai/api/endpoint/audio/speech
    // and .../audio/voices (2026-10-03).
    nonisolated private static let speechEndpoint = "https://api.mistral.ai/v1/audio/speech"
    nonisolated private static let voicesEndpoint = "https://api.mistral.ai/v1/audio/voices"
    nonisolated private static let modelID = "voxtral-mini-tts-2603"
    nonisolated private static let voicesPageSize = 100
    nonisolated private static let maximumVoicePages = 10

    nonisolated static let streamSampleRate: Double = 24_000
    private static let chunkSampleCount = 2_048

    private var apiKey: String?
    private(set) var voiceID: String
    private let session: URLSession

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var streamingTask: Task<Void, Error>?
    private weak var activeStreamingSession: StreamingTTSSession?

    init(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: configuration)
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func warmUpConnection() {
        guard let url = URL(string: "https://api.mistral.ai") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    var isPlaying: Bool {
        guard let playerNode, playerNode.engine != nil else { return false }
        return playerNode.isPlaying
    }

    func stopPlayback() {
        activeStreamingSession?.cancel()
        activeStreamingSession = nil
        stopPlaybackInternal()
    }

    private func stopPlaybackInternal() {
        streamingTask?.cancel()
        streamingTask = nil
        if let playerNode {
            TTSStreamingPlaybackEngine.stopPlayerIfAttached(playerNode)
        }
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: One-shot playback

    func speakText(
        _ text: String,
        waitUntilFinished: Bool = true,
        onPlaybackStarted: (() -> Void)? = nil
    ) async throws {
        stopPlaybackInternal()

        let samples: [Int16]
        do {
            samples = try await fetchSentenceSamples(text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.isExpectedCancellation(error) { throw CancellationError() }
            throw error
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = TTSStreamingPlaybackEngine.makeStreamFormat(sampleRate: Self.streamSampleRate) else {
            throw Self.makeError(-102, "Could not build PCM stream format")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do { try engine.start() } catch {
            throw Self.makeError(-103, "Audio engine failed to start: \(error.localizedDescription)")
        }
        self.audioEngine = engine
        self.playerNode = player

        let playerRef = player
        let engineRef = engine
        let scheduledFrames = TTSStreamingPlaybackEngine.scheduleSamples(samples, on: playerRef, format: streamFormat)
        if scheduledFrames > 0 { onPlaybackStarted?() }

        let task = Task<Void, Error> { [weak self] in
            await TTSStreamingPlaybackEngine.waitForPlaybackToDrain(
                playerRef,
                scheduledFrameCount: scheduledFrames,
                sampleRate: Self.streamSampleRate
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.audioEngine === engineRef {
                    self.audioEngine?.stop()
                    self.audioEngine = nil
                    self.playerNode = nil
                }
            }
        }
        self.streamingTask = task
        if waitUntilFinished {
            do { try await task.value }
            catch is CancellationError { stopPlaybackInternal(); throw CancellationError() }
            catch { stopPlaybackInternal(); throw error }
        }
    }

    // MARK: Sentence-pipelined streaming

    func beginStreamingResponse(onPlaybackStarted: @escaping @MainActor () -> Void) -> StreamingTTSSession {
        stopPlaybackInternal()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let streamFormat = TTSStreamingPlaybackEngine.makeStreamFormat(sampleRate: Self.streamSampleRate) else {
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted
            )
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: streamFormat)
        do { try engine.start() } catch {
            print("⚠️ AVAudioEngine failed to start Mistral streaming session: \(error)")
            return StreamingTTSSession(
                fetchSamples: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.fetchSentenceSamples(text)
                },
                playerNode: nil,
                format: nil,
                sampleRate: Self.streamSampleRate,
                onPlaybackStarted: onPlaybackStarted
            )
        }
        self.audioEngine = engine
        self.playerNode = player
        let streamingSession = StreamingTTSSession(
            fetchSamples: { [weak self] text in
                guard let self else { throw CancellationError() }
                return try await self.fetchSentenceSamples(text)
            },
            playerNode: player,
            format: streamFormat,
            sampleRate: Self.streamSampleRate,
            onPlaybackStarted: onPlaybackStarted
        )
        self.activeStreamingSession = streamingSession
        return streamingSession
    }

    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        guard let apiKey, !apiKey.isEmpty else {
            throw Self.makeError(-10, "Mistral API key is not configured")
        }
        guard !voiceID.isEmpty else {
            throw Self.makeError(-11, "Mistral voice is not selected")
        }
        guard let url = URL(string: Self.speechEndpoint) else {
            throw Self.makeError(-12, "Could not build Mistral speech URL")
        }
        let request = Self.makeSpeechRequest(url: url, apiKey: apiKey, voiceID: voiceID, text: text)
        return try await Self.fetchSamples(request: request, session: session)
    }

    nonisolated private static func fetchSamples(
        request: URLRequest,
        session: URLSession
    ) async throws -> [Int16] {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw makeError(-13, "Mistral returned an invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data.prefix(500), encoding: .utf8) ?? "Unknown error"
            throw makeError(http.statusCode, "Mistral API error \(http.statusCode): \(bodyText)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encodedAudio = json["audio_data"] as? String,
              let audioData = Data(base64Encoded: encodedAudio, options: [.ignoreUnknownCharacters]),
              !audioData.isEmpty else {
            throw makeError(-14, "Mistral returned no audio")
        }
        return try decodeWAVDataToSamples(audioData)
    }

    // MARK: Voices

    /// Lists every voice the API key can use, custom voices first.
    nonisolated static func fetchVoices(apiKey: String) async throws -> [MistralVoiceOption] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw makeError(-20, "Mistral API key is not configured")
        }

        var voices: [MistralVoiceOption] = []
        var seenVoiceIDs = Set<String>()
        for pageIndex in 0..<maximumVoicePages {
            guard var components = URLComponents(string: voicesEndpoint) else {
                throw makeError(-21, "Could not build Mistral voices URL")
            }
            components.queryItems = [
                URLQueryItem(name: "limit", value: String(voicesPageSize)),
                URLQueryItem(name: "offset", value: String(pageIndex * voicesPageSize)),
                URLQueryItem(name: "type", value: "all")
            ]
            guard let url = components.url else {
                throw makeError(-21, "Could not build Mistral voices URL")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw makeError(-22, "Mistral returned an invalid response")
            }
            guard (200...299).contains(http.statusCode) else {
                let bodyText = String(data: data.prefix(500), encoding: .utf8) ?? "Unknown error"
                throw makeError(http.statusCode, "Mistral API error \(http.statusCode): \(bodyText)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                throw makeError(-23, "Mistral returned an unexpected voice list")
            }

            var addedOnThisPage = 0
            for item in items {
                guard let id = item["id"] as? String, !id.isEmpty, !seenVoiceIDs.contains(id) else { continue }
                seenVoiceIDs.insert(id)
                addedOnThisPage += 1
                let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                voices.append(
                    MistralVoiceOption(
                        id: id,
                        name: name.isEmpty ? id : name,
                        isCustom: (item["type"] as? String) == "custom",
                        languages: item["languages"] as? [String] ?? []
                    )
                )
            }

            let total = json["total"] as? Int ?? voices.count
            // Stop on a short or repeated page so an API that ignores `offset`
            // cannot loop.
            if items.count < voicesPageSize || addedOnThisPage == 0 || voices.count >= total {
                break
            }
        }

        return voices.sorted { lhs, rhs in
            if lhs.isCustom != rhs.isCustom { return lhs.isCustom }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Request building

    nonisolated private static func makeSpeechRequest(url: URL, apiKey: String, voiceID: String, text: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": modelID,
            "input": text,
            "voice_id": voiceID,
            "response_format": "wav"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Audio decoding

    nonisolated private static func decodeWAVDataToSamples(_ data: Data) throws -> [Int16] {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-mistral-tts-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try data.write(to: tempURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file = try AVAudioFile(forReading: tempURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw makeError(-15, "Could not allocate Mistral audio buffer")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw makeError(-16, "Could not decode Mistral audio")
        }

        let channelCount = max(1, Int(format.channelCount))
        let frames = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var mixed: Float = 0
            for channel in 0..<channelCount {
                mixed += channels[channel][frame]
            }
            mono[frame] = mixed / Float(channelCount)
        }

        var resampled = resample(mono, from: format.sampleRate, to: streamSampleRate)
        applyEdgeFades(to: &resampled)
        return resampled.map { sample in
            Int16(max(-1, min(1, sample)) * Float(Int16.max))
        }
    }

    /// Ramps the first and last few milliseconds to silence. A clip that
    /// starts or ends away from zero makes the speaker jump, which is heard
    /// as a click at sentence boundaries and when playback stops.
    nonisolated private static func applyEdgeFades(to samples: inout [Float]) {
        let fadeLength = min(Int(streamSampleRate * 0.008), samples.count / 2)
        guard fadeLength > 1 else { return }
        let lastIndex = samples.count - 1
        for offset in 0..<fadeLength {
            let gain = Float(offset) / Float(fadeLength)
            samples[offset] *= gain
            samples[lastIndex - offset] *= gain
        }
    }

    /// Linear-interpolation resampler. The playback engine runs at a fixed
    /// rate, so audio at any other rate would play at the wrong pitch.
    nonisolated private static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard sourceRate > 0, abs(sourceRate - targetRate) > 0.5, samples.count > 1 else { return samples }
        let ratio = sourceRate / targetRate
        let outputCount = Int((Double(samples.count) / ratio).rounded(.down))
        guard outputCount > 0 else { return samples }

        var output = [Float](repeating: 0, count: outputCount)
        let lastIndex = samples.count - 1
        for index in 0..<outputCount {
            let position = Double(index) * ratio
            let lower = min(Int(position), lastIndex)
            let upper = min(lower + 1, lastIndex)
            let fraction = Float(position - Double(lower))
            output[index] = samples[lower] + (samples[upper] - samples[lower]) * fraction
        }
        return output
    }

    nonisolated private static func makeError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "MistralTTS",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    nonisolated private static func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return true }
        let desc = String(describing: error).lowercased()
        return desc == "cancellationerror()" || desc.contains("cancelled") || desc.contains("canceled")
    }
}
