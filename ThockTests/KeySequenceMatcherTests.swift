import Foundation
import Testing
@testable import Thock

struct KeySequenceMatcherTests {
    private typealias Outcome = KeySequenceMatcher.Outcome

    private func makeMatcher(_ extra: [String: [String]] = [:]) -> KeySequenceMatcher {
        var sequences: [String: [String]] = [
            "t h": ["th.wav"],
            "c h": ["ch.wav"],
            "t c h": ["tch.wav"],
            "c k": [],
            "e a": ["ee.wav"],
            "a r": ["ar.wav"],
        ]
        sequences.merge(extra) { $1 }
        return KeySequenceMatcher(sequences: sequences, maxGap: 0.4)
    }

    /// Types keys 100 ms apart and returns the outcome of each
    private func type(_ keys: [String], into matcher: inout KeySequenceMatcher, from start: TimeInterval = 0) -> [Outcome] {
        keys.enumerated().map { matcher.keyDown($1, at: start + Double($0) * 0.1) }
    }

    @Test func aPairPlaysItsSequenceSoundOnTheSecondKey() {
        var matcher = makeMatcher()
        #expect(type(["t", "h"], into: &matcher) == [.single, .sequence(sounds: ["th.wav"], span: 2)])
    }

    @Test func theLongestSequenceWins() {
        var matcher = makeMatcher()
        #expect(type(["t", "c", "h"], into: &matcher) == [.single, .single, .sequence(sounds: ["tch.wav"], span: 3)])
    }

    @Test func aShorterSequenceStillMatchesWhenTheLongerOneDoesNot() {
        var matcher = makeMatcher()
        #expect(type(["e", "c", "h"], into: &matcher).last == .sequence(sounds: ["ch.wav"], span: 2))
    }

    @Test func anEmptySoundListIsAMatchThatStaysSilent() {
        var matcher = makeMatcher()
        #expect(type(["c", "k"], into: &matcher) == [.single, .sequence(sounds: [], span: 2)])
    }

    @Test func keysConsumedByAMatchCannotStartAnother() {
        var matcher = makeMatcher()
        // "ear": the "a" belongs to "e a", so "a r" must not fire
        #expect(type(["e", "a", "r"], into: &matcher) == [.single, .sequence(sounds: ["ee.wav"], span: 2), .single])
    }

    @Test func consumedKeysStayConsumedAfterAnUnmatchedKey() {
        var matcher = makeMatcher(["a t h": ["ath.wav"]])
        // The "a" was used by "e a"; two keys later it still can't open "a t h", but "t h" can match
        #expect(type(["e", "a", "t", "h"], into: &matcher).last == .sequence(sounds: ["th.wav"], span: 2))
    }

    @Test func aMatchCanGrowIntoALongerSequence() {
        var matcher = makeMatcher(["o u": ["ow.wav"], "o u r": ["our.wav"]])
        #expect(type(["o", "u", "r"], into: &matcher) == [
            .single, .sequence(sounds: ["ow.wav"], span: 2), .sequence(sounds: ["our.wav"], span: 3),
        ])
    }

    @Test func aKeyOutsideEverySequenceResetsTheHistory() {
        var matcher = makeMatcher()
        #expect(type(["t", "space", "h"], into: &matcher) == [.single, .untracked, .single])
        #expect(type(["t", "del", "h"], into: &matcher, from: 10) == [.single, .untracked, .single])
    }

    @Test func aPauseLongerThanTheGapResetsTheHistory() {
        var matcher = makeMatcher()
        #expect(matcher.keyDown("t", at: 1.0) == .single)
        #expect(matcher.keyDown("h", at: 1.41) == .single)
        #expect(matcher.keyDown("t", at: 2.0) == .single)
        #expect(matcher.keyDown("h", at: 2.4) == .sequence(sounds: ["th.wav"], span: 2))
    }

    @Test func shortcutsDoNotMatchAndResetTheHistory() {
        var matcher = makeMatcher()
        #expect(matcher.keyDown("t", at: 0) == .single)
        #expect(matcher.keyDown("h", at: 0.1, shortcutModifiersHeld: true) == .untracked)
        #expect(matcher.keyDown("h", at: 0.2) == .single)
    }

    @Test func shiftDoesNotBreakASequence() {
        var matcher = makeMatcher()
        #expect(type(["shiftLeft", "t", "h"], into: &matcher) == [.untracked, .single, .sequence(sounds: ["th.wav"], span: 2)])
        #expect(type(["t", "shiftRight", "h"], into: &matcher, from: 10).last == .sequence(sounds: ["th.wav"], span: 2))
    }

    @Test func explicitResetForgetsTheHistory() {
        var matcher = makeMatcher()
        #expect(matcher.keyDown("t", at: 0) == .single)
        matcher.reset()
        #expect(matcher.keyDown("h", at: 0.1) == .single)
    }

    @Test func aPackWithoutSequencesTracksNothing() {
        var matcher = KeySequenceMatcher(sequences: [:])
        #expect(matcher.isEmpty)
        #expect(type(["t", "h"], into: &matcher) == [.untracked, .untracked])
    }

    @Test func malformedSingleKeyPatternsAreIgnored() {
        var matcher = KeySequenceMatcher(sequences: ["t": ["t.wav"], "": []])
        #expect(matcher.isEmpty)
        #expect(matcher.keyDown("t", at: 0) == .untracked)
    }
}
