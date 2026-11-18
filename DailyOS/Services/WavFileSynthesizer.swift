import Foundation

/// Pure-Swift RIFF/WAVE PCM synthesizer that generates:
/// 1. In-memory silent WAV buffer for the overnight `AVAudioSession` keep-alive loop.
/// 2. Custom notification `.wav` files in `~/Library/Sounds` so `UNNotificationSound(named:)`
///    plays custom habit and alarm sounds without requiring external binary audio assets.
enum WavFileSynthesizer {
    static let sampleRate: Int = 44_100

    static var librarySoundsDirectory: URL {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let soundsURL = libraryURL.appendingPathComponent("Sounds", isDirectory: true)
        if !FileManager.default.fileExists(atPath: soundsURL.path) {
            try? FileManager.default.createDirectory(at: soundsURL, withIntermediateDirectories: true)
        }
        return soundsURL
    }

    /// Generates all custom notification and alarm `.wav` files in `~/Library/Sounds` if not yet present.
    static func ensureCustomSoundsInstalled() {
        let dir = librarySoundsDirectory

        // 1. Habit notification sounds
        for option in NotificationSoundOption.allCases {
            guard let fileName = option.soundFileName else { continue }
            let targetURL = dir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                let wavData = makeArpeggioWavData(notesHz: option.notesHz, noteDuration: 0.22)
                try? wavData.write(to: targetURL, options: .atomic)
            }
        }

        // 2. Alarm burst notification & preview sounds
        for tone in AlarmTone.allCases {
            guard let fileName = tone.bundledFileName else { continue }
            let targetURL = dir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                let wavData = makeAlarmToneWavData(
                    baseFreq: tone.baseFrequency,
                    secondaryFreq: tone.secondaryFrequency,
                    modulationHz: tone.modulationRateHz,
                    durationSeconds: 4.0
                )
                try? wavData.write(to: targetURL, options: .atomic)
            }
        }
    }

    /// Returns a URL for a sound file, checking `Bundle.main` first, then `~/Library/Sounds`.
    static func resolveSoundURL(fileName: String) -> URL? {
        let nsName = fileName as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension.isEmpty ? "wav" : nsName.pathExtension

        if let bundled = Bundle.main.url(forResource: base, withExtension: ext) {
            return bundled
        }
        if let bundledMp3 = Bundle.main.url(forResource: base, withExtension: "mp3") {
            return bundledMp3
        }
        let libraryCandidate = librarySoundsDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: libraryCandidate.path) {
            return libraryCandidate
        }
        return nil
    }

    /// Creates an in-memory 16-bit PCM WAV file containing pure silence for background keep-alive looping.
    static func makeSilentWavData(durationSeconds: Double = 2.0) -> Data {
        let totalSamples = max(1, Int(Double(sampleRate) * durationSeconds))
        let samples = [Int16](repeating: 0, count: totalSamples)
        return encodePCM16MonoWav(samples: samples, sampleRate: sampleRate)
    }

    /// Creates a pleasant multi-note arpeggio chime WAV for custom habit notifications.
    static func makeArpeggioWavData(notesHz: [Double], noteDuration: Double = 0.22) -> Data {
        guard !notesHz.isEmpty else {
            return makeSilentWavData(durationSeconds: 0.5)
        }
        let samplesPerNote = Int(Double(sampleRate) * noteDuration)
        let tailSamples = Int(Double(sampleRate) * 0.35)
        let totalSamples = samplesPerNote * notesHz.count + tailSamples
        var samples = [Int16](repeating: 0, count: totalSamples)

        for (noteIndex, freq) in notesHz.enumerated() {
            let startSample = noteIndex * samplesPerNote
            let activeLength = min(totalSamples - startSample, samplesPerNote + tailSamples)
            for i in 0..<activeLength {
                let t = Double(i) / Double(sampleRate)
                let attack = min(1.0, t / 0.015)
                let decay = exp(-3.8 * t)
                let envelope = attack * decay
                let fundamental = sin(2.0 * Double.pi * freq * t)
                let harmonic = 0.35 * sin(2.0 * Double.pi * (freq * 2.0) * t)
                let raw = (fundamental + harmonic) * envelope * 0.45
                let existing = Double(samples[startSample + i]) / Double(Int16.max)
                let combined = max(-0.98, min(0.98, existing + raw))
                samples[startSample + i] = Int16(combined * Double(Int16.max))
            }
        }

        return encodePCM16MonoWav(samples: samples, sampleRate: sampleRate)
    }

    /// Creates a high-energy modulated dual-tone alarm WAV for fallback notifications and tone previews.
    static func makeAlarmToneWavData(
        baseFreq: Double,
        secondaryFreq: Double,
        modulationHz: Double,
        durationSeconds: Double = 4.0
    ) -> Data {
        let totalSamples = max(1, Int(Double(sampleRate) * durationSeconds))
        var samples = [Int16](repeating: 0, count: totalSamples)

        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            let modCycle = sin(2.0 * Double.pi * modulationHz * t)
            let activeFreq = modCycle >= 0 ? baseFreq : secondaryFreq
            let pulseGate = sin(2.0 * Double.pi * (modulationHz * 0.5) * t) >= -0.65 ? 1.0 : 0.15

            let s1 = sin(2.0 * Double.pi * activeFreq * t)
            let s2 = 0.5 * sin(2.0 * Double.pi * (activeFreq * 2.0) * t)
            let s3 = 0.25 * sin(2.0 * Double.pi * (activeFreq * 3.0) * t)
            let normalized = max(-0.98, min(0.98, (s1 + s2 + s3) * 0.55 * pulseGate))
            samples[i] = Int16(normalized * Double(Int16.max))
        }

        return encodePCM16MonoWav(samples: samples, sampleRate: sampleRate)
    }

    /// Encodes 16-bit signed mono PCM samples into a standard 44-byte RIFF WAVE container.
    private static func encodePCM16MonoWav(samples: [Int16], sampleRate: Int) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        let chunkSize = 36 + dataSize

        var data = Data(capacity: Int(44 + dataSize))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendUInt32LE(&data, chunkSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt subchunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendUInt32LE(&data, 16)                         // Subchunk1Size (16 for PCM)
        appendUInt16LE(&data, 1)                          // AudioFormat (1 = PCM)
        appendUInt16LE(&data, numChannels)
        appendUInt32LE(&data, UInt32(sampleRate))
        appendUInt32LE(&data, byteRate)
        appendUInt16LE(&data, blockAlign)
        appendUInt16LE(&data, bitsPerSample)

        // data subchunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendUInt32LE(&data, dataSize)

        samples.withUnsafeBufferPointer { buffer in
            if let baseAddress = buffer.baseAddress {
                let rawPtr = UnsafeRawPointer(baseAddress)
                data.append( rawPtr.assumingMemoryBound(to: UInt8.self), count: Int(dataSize))
            }
        }

        return data
    }

    private static func appendUInt16LE(_ data: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
