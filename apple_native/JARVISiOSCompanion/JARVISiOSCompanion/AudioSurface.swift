import AVFoundation
import Foundation

struct AudioPCMFrame: Equatable {
    let pcm16Mono: Data
    let sampleRate: Double
    let channelCount: AVAudioChannelCount

    var metadata: [String: String] {
        [
            "encoding": "pcm_s16le",
            "sampleRate": String(Int(sampleRate)),
            "channels": String(channelCount),
            "surface": "iphone-microphone"
        ]
    }
}

enum AudioPCMCodec {
    static func pcm16MonoData(from buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channel = buffer.floatChannelData?[0] else { return Data() }
        var data = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        for index in 0..<frameCount {
            let clipped = max(-1.0, min(1.0, channel[index]))
            var sample = Int16(clipped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func makePlaybackBuffer(pcm16Mono: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        let sampleCount = pcm16Mono.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        pcm16Mono.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / Float(Int16.max)
            }
        }
        return buffer
    }
}

final class AudioCaptureEngine {
    private let engine = AVAudioEngine()
    private let sampleRate = 16_000.0
    private var isRunning = false

    func start(onFrame: @escaping (AudioPCMFrame) -> Void) throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { throw AudioSurfaceError.converterUnavailable }

        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, _ in
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(self.sampleRate / 20)) else { return }
            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            _ = converter.convert(to: converted, error: nil, withInputFrom: inputBlock)
            let pcm = AudioPCMCodec.pcm16MonoData(from: converted)
            guard !pcm.isEmpty else { return }
            onFrame(AudioPCMFrame(pcm16Mono: pcm, sampleRate: self.sampleRate, channelCount: 1))
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }
}

final class AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false

    func play(pcm16Mono: Data, sampleRate: Double) {
        guard let buffer = AudioPCMCodec.makePlaybackBuffer(pcm16Mono: pcm16Mono, sampleRate: sampleRate) else { return }
        do {
            try ensureStarted(format: buffer.format)
            player.scheduleBuffer(buffer, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } catch {
            return
        }
    }

    private func ensureStarted(format: AVAudioFormat) throws {
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        if !engine.isRunning {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            try engine.start()
        }
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}

enum AudioSurfaceError: LocalizedError, Equatable {
    case converterUnavailable
    var errorDescription: String? { "Audio converter unavailable" }
}
