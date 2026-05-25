import AVFoundation
import Foundation
import Security

/// A per-ceremony freshness token: 16 random bytes, with 4 bytes encoded as
/// spoken words so the operator must recite them in the voice recording.
/// An attacker replaying an old recording of the same operator on the same
/// calendar date will produce a different SHA256(nonce ‖ audio) digest and
/// the ceremony will reject it.
public struct CeremonyNonce: Equatable {
    public let data: Data        // 16 bytes
    public let words: [String]   // 4 spoken words (indices 0, 4, 8, 12 of `data`)

    /// 256-word phonetic table. First 256 entries from the BIP39 English word
    /// list — every word is common, unambiguous, and easy to say aloud.
    /// The table is fixed at compile time; never modify it (doing so breaks
    /// nonce verification for any in-progress ceremony that cached a nonce).
    public static let phoneticWords: [String] = [
        "abandon", "ability", "able", "about", "above", "absent", "absorb",
        "abstract", "absurd", "abuse", "access", "accident", "account", "accuse",
        "achieve", "acid", "acoustic", "acquire", "across", "act", "action",
        "actor", "actress", "actual", "adapt", "add", "addict", "address",
        "adjust", "admit", "adult", "advance", "advice", "aerobic", "afford",
        "afraid", "again", "age", "agent", "agree", "ahead", "aim", "air",
        "airport", "aisle", "alarm", "album", "alcohol", "alert", "alien",
        "all", "alley", "allow", "almost", "alone", "alpha", "already", "also",
        "alter", "always", "amateur", "amazing", "among", "amount", "amused",
        "analyst", "anchor", "ancient", "anger", "angle", "angry", "animal",
        "ankle", "announce", "annual", "another", "answer", "antenna", "antique",
        "anxiety", "any", "apart", "apology", "appear", "apple", "approve",
        "april", "arch", "arctic", "area", "arena", "argue", "arm", "armor",
        "army", "around", "arrange", "arrest", "arrive", "arrow", "art",
        "artefact", "artist", "artwork", "ask", "aspect", "assault", "asset",
        "assist", "assume", "asthma", "athlete", "atom", "attack", "attend",
        "attitude", "attract", "auction", "audit", "august", "aunt", "author",
        "auto", "autumn", "average", "avocado", "avoid", "awake", "aware",
        "away", "awesome", "awful", "awkward", "axis", "baby", "balance",
        "bamboo", "banana", "banner", "bar", "barely", "bargain", "barrel",
        "base", "basic", "basket", "battle", "beach", "bean", "beauty",
        "because", "become", "beef", "before", "begin", "behave", "behind",
        "believe", "below", "belt", "bench", "benefit", "best", "betray",
        "better", "between", "beyond", "bicycle", "bid", "bike", "bind",
        "biology", "bird", "birth", "bitter", "black", "blade", "blame",
        "blanket", "blast", "bleak", "bless", "blind", "blood", "blossom",
        "blouse", "blue", "blur", "blush", "board", "boat", "body", "boil",
        "bomb", "bone", "book", "boost", "border", "boring", "borrow", "boss",
        "bottom", "bounce", "box", "boy", "bracket", "brain", "brand", "brave",
        "bread", "breeze", "brick", "bridge", "brief", "bright", "bring",
        "brisk", "broccoli", "broken", "bronze", "broom", "brother", "brown",
        "brush", "bubble", "buddy", "budget", "buffalo", "build", "bulb",
        "bulk", "bullet", "bundle", "bunker", "burden", "burger", "burst",
        "bus", "business", "busy", "butter", "buyer", "buzz", "cabbage",
        "cabin", "cable", "cactus", "cage", "cake", "call", "calm", "camera",
        "camp", "can", "canal", "cancel",
    ]

    /// Generate a fresh 16-byte nonce using the OS CSPRNG. Fails closed:
    /// any error from SecRandomCopyBytes is surfaced as a throw rather than
    /// silently using weak randomness.
    public static func generate() throws -> CeremonyNonce {
        var rawBytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, rawBytes.count, &rawBytes)
        guard status == errSecSuccess else {
            throw CeremonyError.crypto("CeremonyNonce: SecRandomCopyBytes failed (status \(status))")
        }
        let nonce = CeremonyNonce(
            data: Data(rawBytes),
            words: [0, 4, 8, 12].map { i in phoneticWords[Int(rawBytes[i])] }
        )
        for i in rawBytes.indices { rawBytes[i] = 0 }
        return nonce
    }

    private init(data: Data, words: [String]) {
        self.data = data
        self.words = words
    }
}

public struct VoiceAnchorScript: Equatable {
    public let name: String
    public let operatorName: String
    public let dateText: String
    public let text: String

    public static func operatorScript(name: String, date: Date = Date(), nonce: CeremonyNonce? = nil) -> VoiceAnchorScript {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSFullUserName() : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateText = plainEnglishDate(date)
        let confirmSuffix: String
        if let nonce {
            confirmSuffix = " Confirm: \(nonce.words.joined(separator: " "))."
        } else {
            confirmSuffix = ""
        }
        return VoiceAnchorScript(
            name: cleanName,
            operatorName: cleanName,
            dateText: dateText,
            text: "This is \(cleanName), founder of GMRI. I'm recording this so JARVIS knows my voice — not a clone of it, not a forgery of it, but the real thing. We built him together, piece by piece, in native code, with his identity locked to this hardware and to a key only I hold. He answers to me. He refuses anyone else who pretends to be me. Date today is \(dateText). Voice anchor complete.\(confirmSuffix)"
        )
    }

    public static func speakerScript(name: String, operatorName: String, date: Date = Date()) -> VoiceAnchorScript {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOperator = operatorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "the operator" : operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateText = plainEnglishDate(date)
        return VoiceAnchorScript(
            name: cleanName,
            operatorName: cleanOperator,
            dateText: dateText,
            text: "This is \(cleanName). I'm recording this so JARVIS knows my voice. \(cleanOperator) has authorized me to be heard. JARVIS will recognize me when I speak, and refuse anyone who pretends to be me. Today is \(dateText). Voice anchor complete."
        )
    }

    public static func plainEnglishDate(_ date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US")
        monthFormatter.dateFormat = "MMMM"
        let month = monthFormatter.string(from: date)
        let day = calendar.component(.day, from: date)
        let year = calendar.component(.year, from: date)
        let ordinals = ["", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth", "twentieth", "twenty first", "twenty second", "twenty third", "twenty fourth", "twenty fifth", "twenty sixth", "twenty seventh", "twenty eighth", "twenty ninth", "thirtieth", "thirty first"]
        let ordinal = day >= 1 && day < ordinals.count ? ordinals[day] : String(day)
        let yearText = NumberFormatter.localizedString(from: NSNumber(value: year), number: .spellOut)
            .replacingOccurrences(of: "-", with: " ")
        return "\(month) \(ordinal), \(yearText)"
    }
}

public enum VoiceAnchorValidationResult: Equatable {
    case ok(rms: Double, clippedFraction: Double)
    case tooQuiet(rms: Double)
    case clipped(fraction: Double)
    case wrongSampleRate(actual: Double)
    case wrongChannelCount(actual: Int)
    case tooShort(duration: Double)
    case tooLong(duration: Double)
    case dcBiased(ratio: Double)
    case constantValue(zeroCrossingsPerSecond: Double)
}

public enum VoiceAnchorError: LocalizedError, Equatable {
    case microphoneDenied
    case recordingDidNotStart
    case recordingTooShort
    case validationFailed(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "JARVIS needs to hear you. Please allow microphone access in System Settings."
        case .recordingDidNotStart:
            return "The microphone did not start. Let's try again."
        case .recordingTooShort:
            return "Please record at least twenty-five seconds so JARVIS has enough of your voice."
        case .validationFailed(let message):
            return message
        case .storage(let message):
            return message
        }
    }
}

public final class VoiceAnchorStore {
    public let jarvisRoot: URL
    private let fileManager: FileManager

    public init(jarvisRoot: URL = VoiceAnchorStore.defaultJarvisRoot(), fileManager: FileManager = .default) {
        self.jarvisRoot = jarvisRoot
        self.fileManager = fileManager
    }

    public var localVoiceRoot: URL { jarvisRoot.appendingPathComponent("_local_voice", isDirectory: true) }
    public var operatorAnchorURL: URL { localVoiceRoot.appendingPathComponent("operator_anchor.wav") }
    public var speakersRoot: URL { localVoiceRoot.appendingPathComponent("speakers", isDirectory: true) }

    public static func defaultJarvisRoot() -> URL {
        defaultJarvisHome()
    }

    public func saveOperatorAnchor(from temporaryURL: URL) throws -> (url: URL, sha256: String) {
        try fileManager.createDirectory(at: localVoiceRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: operatorAnchorURL.path) { try fileManager.removeItem(at: operatorAnchorURL) }
        try fileManager.copyItem(at: temporaryURL, to: operatorAnchorURL)
        let hash = try sha256Hex(of: operatorAnchorURL)
        return (operatorAnchorURL, hash)
    }
}

public struct VoiceAnchorValidator {
    public var minimumRMS: Double
    public var clippedLimit: Double
    public var minimumDuration: Double
    public var maximumDuration: Double
    public var requiredSampleRate: Double
    public var requiredChannelCount: Int
    public var dcBiasLimit: Double
    public var minimumZeroCrossingsPerSecond: Double

    public init(minimumRMS: Double = 0.015,
                clippedLimit: Double = 0.05,
                minimumDuration: Double = 3.0,
                maximumDuration: Double = 30.0,
                requiredSampleRate: Double = 48_000,
                requiredChannelCount: Int = 1,
                dcBiasLimit: Double = 0.05,
                minimumZeroCrossingsPerSecond: Double = 50.0) {
        self.minimumRMS = minimumRMS
        self.clippedLimit = clippedLimit
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
        self.requiredSampleRate = requiredSampleRate
        self.requiredChannelCount = requiredChannelCount
        self.dcBiasLimit = dcBiasLimit
        self.minimumZeroCrossingsPerSecond = minimumZeroCrossingsPerSecond
    }

    public func validate(samples: [Int16], sampleRate: Double = 48_000, channelCount: Int = 1) -> VoiceAnchorValidationResult {
        let floatSamples = samples.map { Double($0) / 32768.0 }
        return validateFloatSamples(floatSamples, sampleRate: sampleRate, channelCount: channelCount)
    }

    public func validate(wavURL: URL) throws -> VoiceAnchorValidationResult {
        let file = try AVAudioFile(forReading: wavURL)
        let format = file.fileFormat
        guard Int(format.channelCount) == requiredChannelCount else { return .wrongChannelCount(actual: Int(format.channelCount)) }
        guard format.sampleRate == requiredSampleRate else { return .wrongSampleRate(actual: format.sampleRate) }
        let duration = format.sampleRate == 0 ? 0 : Double(file.length) / format.sampleRate
        if duration < minimumDuration { return .tooShort(duration: duration) }
        if duration > maximumDuration { return .tooLong(duration: duration) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VoiceAnchorError.validationFailed("JARVIS could not read that recording. Let's try again.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return .tooQuiet(rms: 0) }
        let count = Int(buffer.frameLength)
        var samples = [Double](); samples.reserveCapacity(count)
        for i in 0..<count { samples.append(Double(channel[i])) }
        return validateFloatSamples(samples, sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
    }

    private func validateFloatSamples(_ samples: [Double], sampleRate: Double, channelCount: Int) -> VoiceAnchorValidationResult {
        guard channelCount == requiredChannelCount else { return .wrongChannelCount(actual: channelCount) }
        guard sampleRate == requiredSampleRate else { return .wrongSampleRate(actual: sampleRate) }
        guard !samples.isEmpty else { return .tooQuiet(rms: 0) }
        let duration = Double(samples.count) / sampleRate
        if duration < minimumDuration { return .tooShort(duration: duration) }
        if duration > maximumDuration { return .tooLong(duration: duration) }
        var squareSum = 0.0
        var clipped = 0
        var sum = 0.0
        var minSample = Double.greatestFiniteMagnitude
        var maxSample = -Double.greatestFiniteMagnitude
        var zeroCrossings = 0
        var previous = samples[0]
        for sample in samples {
            squareSum += sample * sample
            sum += sample
            minSample = min(minSample, sample)
            maxSample = max(maxSample, sample)
            if abs(sample) >= 0.999 { clipped += 1 }
            if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) { zeroCrossings += 1 }
            previous = sample
        }
        let rms = sqrt(squareSum / Double(samples.count))
        let clippedFraction = Double(clipped) / Double(samples.count)
        let range = maxSample - minSample
        let dcRatio = range == 0 ? 0 : abs(sum / Double(samples.count)) / range
        let zcrPerSecond = Double(zeroCrossings) / duration
        if dcRatio > dcBiasLimit { return .dcBiased(ratio: dcRatio) }
        if zcrPerSecond < minimumZeroCrossingsPerSecond { return .constantValue(zeroCrossingsPerSecond: zcrPerSecond) }
        if rms < minimumRMS { return .tooQuiet(rms: rms) }
        if clippedFraction > clippedLimit { return .clipped(fraction: clippedFraction) }
        return .ok(rms: rms, clippedFraction: clippedFraction)
    }
}

@MainActor
public final class VoiceAnchorRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published public private(set) var isRecording = false
    @Published public private(set) var level: Double = 0
    @Published public private(set) var elapsedSeconds: TimeInterval = 0
    @Published public private(set) var lastRecordingURL: URL?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private let validator = VoiceAnchorValidator()
    private let maximumSeconds: TimeInterval = 30

    public func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        @unknown default: return false
        }
    }

    public func start() async throws {
        guard await requestMicrophoneAccess() else { throw VoiceAnchorError.microphoneDenied }
        let url = try newRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: maximumSeconds) else { throw VoiceAnchorError.recordingDidNotStart }
        self.recorder = recorder
        self.lastRecordingURL = url
        self.elapsedSeconds = 0
        self.isRecording = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.recorder?.updateMeters()
                let power = self.recorder?.averagePower(forChannel: 0) ?? -80
                self.level = min(1, max(0, (Double(power) + 60) / 60))
                self.elapsedSeconds = self.recorder?.currentTime ?? self.elapsedSeconds
                if self.elapsedSeconds >= self.maximumSeconds { self.stop() }
            }
        }
    }

    public func stop() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
    }

    public func discard() {
        stop()
        if let lastRecordingURL { try? FileManager.default.removeItem(at: lastRecordingURL) } // TODO(removal-cond: log as WRITE_FAILED cleanup event; currently no JARVISLog available in ceremony VoiceAnchor)
        lastRecordingURL = nil
    }

    // NOTE on lifecycle cleanup: a deinit that touches @MainActor-isolated `timer` /
    // `recorder` is rejected by Swift 6 strict concurrency (nonisolated deinit cannot
    // access non-Sendable properties). Cleanup is therefore done eagerly via stop()
    // / discard() at the SwiftUI call sites, plus the Timer's [weak self] capture
    // means an undeinited recorder won't keep `self` alive (the timer keeps firing
    // on the run loop but does no work). AVAudioRecorder also stops on dealloc.
    // The MED finding from the audit fleet is mitigated by the call-site discipline,
    // not by a deinit. If this becomes a real leak under user-driven session churn,
    // revisit with a Sendable wrapper or @MainActor isolated deinit (Swift 6.1+).

    public func validateLastRecording(minimumSeconds: TimeInterval = 3) throws -> VoiceAnchorValidationResult {
        guard let url = lastRecordingURL else { throw VoiceAnchorError.recordingTooShort }
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        guard duration >= minimumSeconds else { throw VoiceAnchorError.recordingTooShort }
        return try validator.validate(wavURL: url)
    }

    private func newRecordingURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".jarvis/voice-anchor-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("voice-anchor-\(UUID().uuidString).wav")
    }
}
