import ActivityKit
import Foundation

struct LyricAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var line: String
        var nextLine: String
        var lineNumber: Int
        var isPlaying: Bool
        var status: String? = nil
        var trackTitle: String? = nil
        var trackArtist: String? = nil
    }
    var title: String
    var artist: String
    var source: String? = nil
    var serverManaged: Bool? = nil
}

enum DemoSong {
    static let title = "Un chemin de lumière"
    static let artist = "Texte original · Mode démo"
    static let lines = [
        "Le ciel invente une couleur nouvelle.",
        "Nos pas dessinent un chemin de lumière.",
        "Le jour se pose au bord de la fenêtre.",
        "Un souffle emporte les ombres d’hier.",
        "La nuit s’efface et tout peut renaître."
    ]
    static let duration: Double = 30
    static func index(at elapsed: Double) -> Int {
        min(max(Int(elapsed / 6), 0), lines.count - 1)
    }
}
