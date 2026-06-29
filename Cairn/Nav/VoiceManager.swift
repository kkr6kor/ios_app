import Foundation
import AVFoundation
import AudioToolbox

/// On-device turn-by-turn voice — mirrors the Kotlin `VoiceManager`: off / chime /
/// full. Ducks other audio so guidance is audible over music.
final class VoiceManager {
    enum Mode: String, CaseIterable { case off, chime, full }
    var mode: Mode = .full

    private let synth = AVSpeechSynthesizer()

    func announce(_ text: String) {
        switch mode {
        case .off: return
        case .chime:
            configureAudio()
            AudioServicesPlaySystemSound(1057)   // short alert tone
        case .full:
            configureAudio()
            let u = AVSpeechUtterance(string: text)
            u.rate = AVSpeechUtteranceDefaultSpeechRate
            synth.speak(u)
        }
    }

    private func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }
}
