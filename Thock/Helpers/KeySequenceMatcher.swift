import Foundation

/// Recognises multi-key sequences such as "t h" in a stream of key-downs, so a soundpack can give a
/// letter pair its own sound. A pure state machine: it owns no clock and touches no audio.
struct KeySequenceMatcher {
    enum Outcome: Equatable {
        /// The key takes no part in sequences and plays its own sound.
        case untracked
        /// The key plays its own sound and may start or continue a sequence.
        case single
        /// The key completed a sequence spanning `span` keys. `sounds` replaces the key's own sound and
        /// the voices of the earlier keys in the span. An empty list means the key stays silent and
        /// the earlier voices are left alone.
        case sequence(sounds: [String], span: Int)
    }

    static let defaultMaxGap: TimeInterval = 0.4

    /// Held while typing ordinary text, so they must not break a sequence ("Th" is still "t h").
    private static let transparentKeys: Set<String> = ["shiftLeft", "shiftRight", "capsLock"]

    private let sequences: [[String]: [String]]
    private let alphabet: Set<String>
    private let maxLength: Int
    private let maxGap: TimeInterval

    /// Recent key-downs, each tagged with the match that consumed it (0 when unconsumed).
    private var history: [(key: String, match: Int)] = []
    private var lastKeyTime: TimeInterval?
    private var nextMatch = 1

    var isEmpty: Bool { sequences.isEmpty }

    /// - Parameter sequences: Key names separated by spaces ("t h", "i g h") mapped to candidate sounds.
    init(sequences: [String: [String]], maxGap: TimeInterval = KeySequenceMatcher.defaultMaxGap) {
        var parsed: [[String]: [String]] = [:]
        for (pattern, sounds) in sequences {
            let keys = pattern.split(separator: " ").map(String.init)
            if keys.count >= 2 {
                parsed[keys] = sounds
            }
        }
        self.sequences = parsed
        self.alphabet = Set(parsed.keys.joined())
        self.maxLength = parsed.keys.map(\.count).max() ?? 0
        self.maxGap = maxGap
    }

    mutating func reset() {
        history.removeAll(keepingCapacity: true)
        lastKeyTime = nil
    }

    /// - Parameters:
    ///   - time: Monotonic time of the key-down in seconds.
    ///   - shortcutModifiersHeld: True while command, control or option is down; shortcuts aren't typing.
    mutating func keyDown(_ key: String, at time: TimeInterval, shortcutModifiersHeld: Bool = false) -> Outcome {
        guard !sequences.isEmpty, !Self.transparentKeys.contains(key) else { return .untracked }
        guard !shortcutModifiersHeld, alphabet.contains(key) else {
            reset()
            return .untracked
        }
        if let lastKeyTime, time - lastKeyTime > maxGap {
            reset()
        }
        lastKeyTime = time

        history.append((key, 0))
        // One entry beyond the longest sequence is enough to tell where an earlier match began
        if history.count > maxLength + 1 {
            history.removeFirst(history.count - maxLength - 1)
        }

        var length = min(maxLength, history.count)
        while length >= 2 {
            let start = history.count - length
            if let sounds = sequences[history[start...].map(\.key)], canMatch(from: start) {
                for index in start..<history.count {
                    history[index].match = nextMatch
                }
                nextMatch += 1
                return .sequence(sounds: sounds, span: length)
            }
            length -= 1
        }
        return .single
    }

    /// Keys an earlier match consumed can't seed a new one: after "e a", an "r" must not turn the
    /// "a" into "a r". The exception is growing that whole earlier match, "o u" into "o u r".
    private func canMatch(from start: Int) -> Bool {
        let earlier = history[start..<(history.count - 1)]
        if earlier.allSatisfy({ $0.match == 0 }) { return true }
        guard let match = earlier.first?.match, match != 0,
              earlier.allSatisfy({ $0.match == match }) else { return false }
        return start == 0 || history[start - 1].match != match
    }
}
