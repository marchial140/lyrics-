import Foundation

struct TimedLyric: Equatable, Identifiable {
    let time: TimeInterval
    let text: String
    var id: TimeInterval { time }
}

enum LyricsTimeline {
    static func parse(_ source: String) -> [TimedLyric] {
        guard let tags = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]"#),
              let offsets = try? NSRegularExpression(pattern: #"(?i)\[offset:([+-]?\d+)\]"#) else { return [] }
        let full = source as NSString
        let offset = offsets.firstMatch(in: source, range: NSRange(location: 0, length: full.length))
            .flatMap { Double(full.substring(with: $0.range(at: 1))) } ?? 0
        var byTime: [TimeInterval: String] = [:]
        for line in source.components(separatedBy: .newlines) {
            let ns = line as NSString
            let matches = tags.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Double(ns.substring(with: match.range(at: 1))),
                      let seconds = Double(ns.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                // Positive LRC offset advances the lyrics relative to the audio.
                let time = max(0, minutes * 60 + seconds - offset / 1000)
                byTime[time] = text
            }
        }
        return byTime.map { TimedLyric(time: $0.key, text: $0.value) }.sorted { $0.time < $1.time }
    }

    static func index(at time: TimeInterval, in lines: [TimedLyric]) -> Int? {
        guard !lines.isEmpty, time >= lines[0].time else { return nil }
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
}
