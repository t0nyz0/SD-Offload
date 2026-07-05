import AppKit

/// The built-in macOS alert sounds, for the completion chime.
enum Sounds {
    static let all = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                      "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        if sound.isPlaying { sound.stop() }   // restart on rapid re-taps (named sounds are cached)
        sound.play()
    }
}
