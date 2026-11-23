import Foundation

// MARK: - Alarm Soundscape Categories & 12-Sound Library

enum AlarmSoundCategory: String, CaseIterable, Identifiable {
    case hopecoreSunrise = "Hopecore & Sunrise"
    case groundedMinimal = "Grounded & Minimal"
    case highClarity = "High-Clarity Wake-Ups"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .hopecoreSunrise: return "Uplifting, warm & cinematic"
        case .groundedMinimal: return "Deep, cool & calm focus"
        case .highClarity: return "Alert, crisp & non-siren"
        }
    }

    var sounds: [AlarmSoundscape] {
        AlarmSoundscape.allCases.filter { $0.category == self }
    }
}

enum AlarmSoundscape: String, CaseIterable, Codable, Identifiable {
    // 1. Hopecore & Sunrise
    case goldenHour
    case firstLight
    case mainCharacter
    case alpineAir

    // 2. Grounded & Minimal
    case obsidianPulse
    case ironAndCedar
    case nightDrive
    case horizonDrift

    // 3. High-Clarity Wake-Ups
    case solarFlare
    case kineticTap
    case crispBeacon
    case classicAlarm

    var id: String { rawValue }

    var category: AlarmSoundCategory {
        switch self {
        case .goldenHour, .firstLight, .mainCharacter, .alpineAir:
            return .hopecoreSunrise
        case .obsidianPulse, .ironAndCedar, .nightDrive, .horizonDrift:
            return .groundedMinimal
        case .solarFlare, .kineticTap, .crispBeacon, .classicAlarm:
            return .highClarity
        }
    }

    var displayName: String {
        switch self {
        case .goldenHour: return "Golden Hour"
        case .firstLight: return "First Light"
        case .mainCharacter: return "Main Character Morning"
        case .alpineAir: return "Alpine Air"
        case .obsidianPulse: return "Obsidian Pulse"
        case .ironAndCedar: return "Iron & Cedar"
        case .nightDrive: return "Night Drive"
        case .horizonDrift: return "Horizon Drift"
        case .solarFlare: return "Solar Flare"
        case .kineticTap: return "Kinetic Tap"
        case .crispBeacon: return "Crisp Beacon"
        case .classicAlarm: return "Classic Chime (Legacy)"
        }
    }

    var vibeDescription: String {
        switch self {
        case .goldenHour: return "Warm major-9th sunrise synth pad with harmonic shimmer"
        case .firstLight: return "Bright acoustic-harp & celesta arpeggio with silky decay"
        case .mainCharacter: return "Euphoric Fmaj7→Cmaj7→G6→Am7 progression + bell motif"
        case .alpineAir: return "Crisp wooden marimba intervals & airy open fifths"
        case .obsidianPulse: return "Deep 65 Hz analog heartbeat + percussive mechanical tick"
        case .ironAndCedar: return "Low resonant baritone fifths with steady rhythmic swell"
        case .nightDrive: return "Sleek minimal analog A-minor-9 synth arpeggio"
        case .horizonDrift: return "Wide atmospheric pad with a clear 2s harmonic sonar chime"
        case .solarFlare: return "Crisp ascending harmonic chimes that cut through deep sleep"
        case .kineticTap: return "Rhythmic woodblock pulse + bright bell accent"
        case .crispBeacon: return "Clean studio dual-tone harmonic chime (528 Hz + 792 Hz)"
        case .classicAlarm: return "Traditional high-urgency rhythmic chime for max sharpness"
        }
    }

    var fileName: String {
        "soundscape_\(rawValue).wav"
    }

    /// Safely migrates any legacy `AlarmTone` rawValue or unknown ID to a valid soundscape.
    static func resolve(legacyOrID raw: String) -> AlarmSoundscape {
        if let exact = AlarmSoundscape(rawValue: raw) {
            return exact
        }
        switch raw {
        case "nuclear_siren", "classic_pulse", "digital_siren":
            return .classicAlarm
        case "radar_chime":
            return .crispBeacon
        case "submarine_alert":
            return .obsidianPulse
        case "synth_engine":
            return .nightDrive
        default:
            return .goldenHour
        }
    }
}

// MARK: - Self-Contained 44.1 kHz 16-Bit PCM Procedural Soundscape Synthesizer

enum AlarmSoundSynthesizer {
    static let sampleRate: Int = 44_100
    private static let cacheLock = NSLock()
    private static var memoryCache: [AlarmSoundscape: Data] = [:]

    /// Returns a seamless looping 44.1 kHz 16-bit PCM `.wav` buffer in memory (cached after first render).
    static func wavData(for sound: AlarmSoundscape) -> Data {
        cacheLock.lock()
        if let cached = memoryCache[sound] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let rendered = synthesize(sound: sound)

        cacheLock.lock()
        memoryCache[sound] = rendered
        cacheLock.unlock()
        return rendered
    }

    // MARK: - DSP Synthesis Engine

    private static func synthesize(sound: AlarmSoundscape) -> Data {
        let duration: Double
        switch sound {
        case .mainCharacter: duration = 8.0
        case .goldenHour, .ironAndCedar, .horizonDrift: duration = 6.0
        case .firstLight, .alpineAir, .nightDrive, .solarFlare: duration = 4.0
        case .obsidianPulse, .kineticTap, .crispBeacon, .classicAlarm: duration = 4.0
        }

        let sr = Double(sampleRate)
        let totalSamples = Int(sr * duration)
        var buffer = [Double](repeating: 0.0, count: totalSamples)
        let twoPi = 2.0 * Double.pi

        switch sound {
        // MARK: 1. Hopecore & Sunrise
        case .goldenHour:
            // Lush Cmaj9 pad: C3 (130.81), G3 (196.00), D4 (293.66), E4 (329.63), B4 (493.88)
            let notes: [(Double, Double)] = [
                (130.81, 0.28), (196.00, 0.22), (293.66, 0.18), (329.63, 0.16), (493.88, 0.11), (659.25, 0.06)
            ]
            for i in 0..<totalSamples {
                let t = Double(i) / sr
                let swell = 0.72 + 0.28 * sin(twoPi * (t / duration) - Double.pi * 0.5)
                let shimmer = 0.5 + 0.5 * sin(twoPi * 0.5 * t)
                var sum = 0.0
                for (idx, (freq, amp)) in notes.enumerated() {
                    let detune = 1.0 + (idx % 2 == 0 ? 0.0018 : -0.0015)
                    let base = sin(twoPi * freq * t) + 0.5 * sin(twoPi * freq * detune * t)
                    let overtone = (0.18 + 0.14 * shimmer) * sin(twoPi * freq * 2.0 * t)
                    sum += (base + overtone) * amp * 0.52
                }
                buffer[i] = sum * swell
            }
            applyOnePoleLowPass(&buffer, cutoffHz: 2600.0)

        case .firstLight:
            // Bright harp / celesta arpeggio: D4, F#4, A4, E5, F#5, A5, E5, A4
            let arp: [Double] = [293.66, 369.99, 440.00, 659.25, 739.99, 880.00, 659.25, 440.00]
            let stepSec = duration / Double(arp.count)
            // Soft warm D-major bed
            for i in 0..<totalSamples {
                let t = Double(i) / sr
                let bed = 0.14 * sin(twoPi * 146.83 * t) + 0.10 * sin(twoPi * 220.0 * t)
                buffer[i] = bed * (0.8 + 0.2 * sin(twoPi * 0.25 * t))
            }
            for (idx, freq) in arp.enumerated() {
                addPluckVoice(to: &buffer, startSec: Double(idx) * stepSec, freq: freq, amp: 0.42, decayRate: 3.1, harmonicMix: 0.34, durationSec: 1.6)
            }
            applyOnePoleLowPass(&buffer, cutoffHz: 4800.0)

        case .mainCharacter:
            // Euphoric Fmaj7 -> Cmaj7 -> G6 -> Am7 (2 seconds per chord) + sparkling bell motif
            let chords: [[Double]] = [
                [174.61, 220.00, 261.63, 329.63], // Fmaj7
                [130.81, 196.00, 246.94, 329.63], // Cmaj7
                [196.00, 246.94, 293.66, 329.63], // G6
                [220.00, 261.63, 329.63, 392.00]  // Am7
            ]
            let chordDur = 2.0
            for (cIdx, chord) in chords.enumerated() {
                let startSample = Int(Double(cIdx) * chordDur * sr)
                let lenSamples = Int(chordDur * sr)
                for j in 0..<lenSamples {
                    let pos = startSample + j
                    guard pos < totalSamples else { break }
                    let localT = Double(j) / sr
                    let env = min(1.0, localT / 0.18) * min(1.0, (chordDur - localT) / 0.22)
                    var sum = 0.0
                    for freq in chord {
                        sum += (sin(twoPi * freq * localT) + 0.24 * sin(twoPi * freq * 2.0 * localT)) * 0.18
                    }
                    buffer[pos] += sum * env
                }
            }
            // Sparkling bell motif across the 8 seconds
            let bells: [(Double, Double)] = [
                (0.0, 659.25), (0.5, 783.99), (1.0, 1046.50), (1.5, 783.99),
                (2.0, 659.25), (2.5, 587.33), (3.0, 523.25), (3.5, 783.99),
                (4.0, 659.25), (4.5, 783.99), (5.0, 987.77), (5.5, 783.99),
                (6.0, 880.00), (6.5, 783.99), (7.0, 659.25), (7.5, 523.25)
            ]
            for (t0, freq) in bells {
                addBellVoice(to: &buffer, startSec: t0, freq: freq, amp: 0.24, decayRate: 4.0, durationSec: 1.1)
            }
            applyOnePoleLowPass(&buffer, cutoffHz: 4200.0)

        case .alpineAir:
            // Crisp wooden marimba intervals + airy open fifths (C4-G4-D5-A4-G4-E4-D4-G4)
            let marimba: [Double] = [261.63, 392.00, 587.33, 440.00, 392.00, 329.63, 293.66, 392.00]
            let stepSec = duration / Double(marimba.count)
            for i in 0..<totalSamples {
                let t = Double(i) / sr
                let fifthPad = (sin(twoPi * 130.81 * t) + 0.7 * sin(twoPi * 196.00 * t)) * 0.12
                buffer[i] = fifthPad
            }
            for (idx, freq) in marimba.enumerated() {
                addMarimbaVoice(to: &buffer, startSec: Double(idx) * stepSec, freq: freq, amp: 0.50)
            }
            applyOnePoleLowPass(&buffer, cutoffHz: 3600.0)

        // MARK: 2. Grounded & Minimal
        case .obsidianPulse:
            // Deep 65 Hz warm analog heartbeat + crisp mechanical tick (2 beats per 2s)
            for i in 0..<totalSamples {
                let t = Double(i) / sr
                let beatPhase = t.truncatingRemainder(dividingBy: 1.0)
                // Double thump heartbeat (lub-dub at 0.0s and 0.24s)
                let lub = exp(-7.5 * beatPhase) * min(1.0, beatPhase / 0.012)
                let dubT = beatPhase - 0.24
                let dub = dubT > 0 ? exp(-9.5 * dubT) * min(1.0, dubT / 0.012) * 0.65 : 0.0
                let sub = sin(twoPi * 65.41 * t) + 0.35 * sin(twoPi * 130.81 * t)
                let warmSub = tanh(sub * 1.45) * (lub + dub) * 0.68

                // Subtle deep obsidian drone
                let drone = 0.14 * sin(twoPi * 98.0 * t)
                buffer[i] = warmSub + drone
            }
            // Crisp percussive mechanical tick every 0.5s
            for step in 0..<8 {
                let t0 = Double(step) * 0.5
                let accentAmp = (step % 2 == 0) ? 0.30 : 0.16
                addMechanicalTick(to: &buffer, startSec: t0, freq: step % 2 == 0 ? 1850.0 : 1420.0, amp: accentAmp)
            }

        case .ironAndCedar:
            // Low resonant baritone/cello fifths: D2 (73.42), A2 (110.00), F#3 (185.00), A3 (220.00)
            let voices: [(Double, Double)] = [(73.42, 0.34), (110.00, 0.28), (185.00, 0.18), (220.00, 0.12)]
            for i in 0..<totalSamples {
                let t = Double(i) / sr
                let bowSwell = 0.55 + 0.45 * (0.5 - 0.5 * cos(twoPi * (t / 2.0)))
                var sum = 0.0
                for (freq, amp) in voices {
                    // Warm bowed-string harmonic series (fundamental + 2nd + 3rd)
                    let wave = sin(twoPi * freq * t)
                        + 0.42 * sin(twoPi * freq * 2.0 * t)
                        + 0.18 * sin(twoPi * freq * 3.0 * t)
                    sum += wave * amp * 0.62
                }
                buffer[i] = sum * bowSwell
            }
            applyOnePoleLowPass(&buffer, cutoffHz: 1450.0)

        case .nightDrive:
            // Sleek minimal analog synth arpeggio (A minor 9: A2, E3, G3, B3, C4, B3, G3, E3)
            let notes: [Double] = [110.00, 164.81, 196.00, 246.94, 261.63, 246.94, 196.00, 164.81]
            let stepSec = duration / Double(notes.count * 2) // 16 eighth-notes over 4s
            for idx in 0..<(notes.count * 2) {
                let freq = notes[idx % notes.count]
                let startSec = Double(idx) * stepSec
                let startSample = Int(startSec * sr)
                let noteLen = Int(stepSec * 1.45 * sr)
                for j in 0..<noteLen {
                    let pos = (startSample + j) % totalSamples
                    let lt = Double(j) / sr
                    let env = min(1.0, lt / 0.008) * exp(-5.2 * lt)
                    // Warm analog saw-sine hybrid
                    let wave = 0.65 * sin(twoPi * freq * lt)
                        + 0.25 * sin(twoPi * freq * 2.0 * lt)
                        + 0.12 * sin(twoPi * freq * 3.0 * lt)
                    buffer[pos] += wave * env * 0.48
                }
            }
            // Subtle bass root pulse on beat 1 & 3
            for beat in 0..<4 {
                addPluckVoice(to: &buffer, startSec: Double(beat) * 1.0, freq: 55.0, amp: 0.32, decayRate: 2.8, harmonicMix: 0.25, durationSec: 0.9)
            }
            applyOnePoleLowPass(&buffer, cutoffHz: 2200.0)

        case .horizonDrift:
            // Wide atmospheric pad (E2 + B2 + F#3 + G#3) + clear harmonic sonar chime every 2.0s
            let pad: [(Double, Double)] = [(82.41, 0.28), (123.47, 0.22), (185.00, 0.16), (207.65, 0.12)]
            for i in 0..<totalSamples {
                let t = Double(i) / sr
                let drift = 0.72 + 0.28 * sin(twoPi * (t / duration))
                var sum = 0.0
                for (freq, amp) in pad {
                    sum += (sin(twoPi * freq * t) + 0.25 * sin(twoPi * freq * 1.002 * t)) * amp * 0.58
                }
                buffer[i] = sum * drift
            }
            for sonarIdx in 0..<3 {
                addBellVoice(to: &buffer, startSec: Double(sonarIdx) * 2.0 + 0.15, freq: 659.25, amp: 0.44, decayRate: 2.1, durationSec: 1.8)
                addBellVoice(to: &buffer, startSec: Double(sonarIdx) * 2.0 + 0.15, freq: 987.77, amp: 0.18, decayRate: 2.8, durationSec: 1.4)
            }
            applyOnePoleLowPass(&buffer, cutoffHz: 3200.0)

        // MARK: 3. High-Clarity Wake-Ups
        case .solarFlare:
            // Crisp ascending harmonic chimes (E5 -> G#5 -> B5 -> E6) repeating cleanly every 2s
            let motif: [(Double, Double)] = [
                (0.00, 659.25), (0.24, 830.61), (0.48, 987.77), (0.72, 1318.51),
                (2.00, 659.25), (2.24, 830.61), (2.48, 987.77), (2.72, 1318.51)
            ]
            for (t0, freq) in motif {
                addBellVoice(to: &buffer, startSec: t0, freq: freq, amp: 0.46, decayRate: 3.4, durationSec: 1.2)
            }

        case .kineticTap:
            // Rhythmic woodblock pulse + bright bell accent engineered for physical movement
            let pattern: [(Double, Bool)] = [
                (0.00, true), (0.25, false), (0.50, false), (0.75, false),
                (1.00, true), (1.25, false), (1.50, true),  (1.75, false),
                (2.00, true), (2.25, false), (2.50, false), (2.75, false),
                (3.00, true), (3.25, false), (3.50, true),  (3.75, false)
            ]
            for (t0, accented) in pattern {
                addMarimbaVoice(to: &buffer, startSec: t0, freq: accented ? 880.0 : 660.0, amp: accented ? 0.48 : 0.30)
                if accented {
                    addBellVoice(to: &buffer, startSec: t0, freq: 1318.51, amp: 0.28, decayRate: 6.5, durationSec: 0.45)
                }
            }

        case .crispBeacon:
            // Clean studio/aviation dual-tone harmonic chime (528 Hz + 792 Hz) with soft attack
            let hits: [Double] = [0.0, 0.42, 2.0, 2.42]
            for t0 in hits {
                addBellVoice(to: &buffer, startSec: t0, freq: 528.0, amp: 0.42, decayRate: 4.5, durationSec: 0.85)
                addBellVoice(to: &buffer, startSec: t0, freq: 792.0, amp: 0.34, decayRate: 5.0, durationSec: 0.75)
            }

        case .classicAlarm:
            // Traditional high-urgency rhythmic chime (clean, punchy, non-clipping)
            for cycle in 0..<4 {
                let base = Double(cycle) * 1.0
                for pulse in 0..<4 {
                    let t0 = base + Double(pulse) * 0.16
                    let startSample = Int(t0 * sr)
                    let pulseSamples = Int(0.11 * sr)
                    for j in 0..<pulseSamples {
                        let pos = startSample + j
                        guard pos < totalSamples else { break }
                        let lt = Double(j) / sr
                        let env = min(1.0, lt / 0.006) * min(1.0, (0.11 - lt) / 0.012)
                        let tone = sin(twoPi * 880.0 * lt)
                            + 0.45 * sin(twoPi * 1318.51 * lt)
                            + 0.25 * sin(twoPi * 1760.0 * lt)
                        buffer[pos] += tone * env * 0.44
                    }
                }
            }
        }

        // Seamless loop crossfade (80ms) + soft tanh headroom limiter -> 16-bit PCM WAV
        applySeamlessLoopCrossfade(&buffer, crossfadeSamples: Int(0.08 * sr))
        var pcm16 = [Int16](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            let limited = tanh(buffer[i] * 1.15) * 0.90
            let clamped = max(-0.98, min(0.98, limited))
            pcm16[i] = Int16(clamped * Double(Int16.max))
        }
        return WavFileSynthesizer.encodePCM16MonoWav(samples: pcm16, sampleRate: sampleRate)
    }

    // MARK: - Voice Building Blocks

    private static func addPluckVoice(
        to buffer: inout [Double],
        startSec: Double,
        freq: Double,
        amp: Double,
        decayRate: Double,
        harmonicMix: Double,
        durationSec: Double
    ) {
        let sr = Double(sampleRate)
        let twoPi = 2.0 * Double.pi
        let startIdx = Int(startSec * sr)
        let count = Int(durationSec * sr)
        let total = buffer.count
        for j in 0..<count {
            let pos = (startIdx + j) % total
            let lt = Double(j) / sr
            let env = min(1.0, lt / 0.006) * exp(-decayRate * lt)
            let wave = sin(twoPi * freq * lt)
                + harmonicMix * sin(twoPi * freq * 2.0 * lt) * exp(-1.5 * lt)
                + (harmonicMix * 0.4) * sin(twoPi * freq * 3.0 * lt) * exp(-3.5 * lt)
            buffer[pos] += wave * env * amp
        }
    }

    private static func addBellVoice(
        to buffer: inout [Double],
        startSec: Double,
        freq: Double,
        amp: Double,
        decayRate: Double,
        durationSec: Double
    ) {
        let sr = Double(sampleRate)
        let twoPi = 2.0 * Double.pi
        let startIdx = Int(startSec * sr)
        let count = Int(durationSec * sr)
        let total = buffer.count
        for j in 0..<count {
            let pos = (startIdx + j) % total
            let lt = Double(j) / sr
            let attack = min(1.0, lt / 0.010)
            let env = attack * exp(-decayRate * lt)
            let wave = sin(twoPi * freq * lt)
                + 0.30 * sin(twoPi * freq * 2.0 * lt) * exp(-decayRate * 0.6 * lt)
                + 0.14 * sin(twoPi * freq * 3.0 * lt) * exp(-decayRate * 1.4 * lt)
            buffer[pos] += wave * env * amp
        }
    }

    private static func addMarimbaVoice(
        to buffer: inout [Double],
        startSec: Double,
        freq: Double,
        amp: Double
    ) {
        let sr = Double(sampleRate)
        let twoPi = 2.0 * Double.pi
        let startIdx = Int(startSec * sr)
        let count = Int(0.45 * sr)
        let total = buffer.count
        for j in 0..<count {
            let pos = (startIdx + j) % total
            let lt = Double(j) / sr
            let env = min(1.0, lt / 0.003) * exp(-11.5 * lt)
            // Classic marimba 1st + 4th harmonic transient
            let wave = sin(twoPi * freq * lt) + 0.35 * sin(twoPi * freq * 4.0 * lt) * exp(-28.0 * lt)
            buffer[pos] += wave * env * amp
        }
    }

    private static func addMechanicalTick(
        to buffer: inout [Double],
        startSec: Double,
        freq: Double,
        amp: Double
    ) {
        let sr = Double(sampleRate)
        let twoPi = 2.0 * Double.pi
        let startIdx = Int(startSec * sr)
        let count = Int(0.045 * sr)
        let total = buffer.count
        for j in 0..<count {
            let pos = (startIdx + j) % total
            let lt = Double(j) / sr
            let env = min(1.0, lt / 0.001) * exp(-85.0 * lt)
            let click = (sin(twoPi * freq * lt) + 0.5 * sin(twoPi * freq * 1.62 * lt)) * env
            buffer[pos] += click * amp
        }
    }

    /// Warm one-pole low-pass filter to eliminate digital harshness.
    private static func applyOnePoleLowPass(_ samples: inout [Double], cutoffHz: Double) {
        let dt = 1.0 / Double(sampleRate)
        let rc = 1.0 / (2.0 * Double.pi * max(100.0, cutoffHz))
        let alpha = dt / (rc + dt)
        var prev = samples.first ?? 0.0
        for i in 0..<samples.count {
            prev = prev + alpha * (samples[i] - prev)
            samples[i] = prev
        }
    }

    /// Smoothly blends loop start/end over `crossfadeSamples` to eliminate clicks at loop repeat.
    private static func applySeamlessLoopCrossfade(_ samples: inout [Double], crossfadeSamples: Int) {
        let n = samples.count
        let fade = min(crossfadeSamples, n / 8)
        guard fade > 1 else { return }
        for i in 0..<fade {
            let ratio = Double(i) / Double(fade)
            let head = samples[i]
            let tail = samples[n - fade + i]
            samples[i] = head * ratio + tail * (1.0 - ratio)
            samples[n - fade + i] = tail * (1.0 - ratio) + head * ratio
        }
    }
}
