import AppKit

/// The built-in macOS alert sounds, for the completion chime.
enum Sounds {
    static let all = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                      "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}
