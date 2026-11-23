// Renders clips with a built-in macOS voice, one audio file per clip. Used by the soundpack scripts.
//
//   apple_voice_clips <voice identifier> <output folder> <clip> ...
//
// A clip is <name>=<ipa> to speak exact phonemes or <name>:<text> to read ordinary text, and is
// written as <name>.caf. Only some voices honour IPA (Samantha and Daniel do); the rest read a
// placeholder letter aloud instead.

import AVFoundation

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write(Data("usage: apple_voice_clips <voice identifier> <output folder> <name>=<ipa>|<name>:<text> ...\n".utf8))
    exit(64)
}
guard let voice = AVSpeechSynthesisVoice(identifier: arguments[1]) else {
    FileHandle.standardError.write(Data("Voice '\(arguments[1])' is not installed.\n".utf8))
    exit(1)
}

let outputFolder = URL(fileURLWithPath: arguments[2])
var pending = Array(arguments.dropFirst(3))
var synthesizer: AVSpeechSynthesizer?
var lastProgress = Date()

func renderNext() {
    guard !pending.isEmpty else { exit(0) }
    let request = pending.removeFirst()
    guard let separator = request.firstIndex(where: { $0 == "=" || $0 == ":" }), separator != request.startIndex else {
        FileHandle.standardError.write(Data("Expected <name>=<ipa> or <name>:<text>, got '\(request)'.\n".utf8))
        exit(64)
    }
    let name = String(request[..<separator])
    let content = String(request[request.index(after: separator)...])
    let utterance: AVSpeechUtterance
    if request[separator] == "=" {
        // The IPA attribute replaces how the text is spoken, so the text itself is only a placeholder
        let text = NSMutableAttributedString(string: "x")
        text.addAttribute(NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute), value: content,
                          range: NSRange(location: 0, length: 1))
        utterance = AVSpeechUtterance(attributedString: text)
    } else {
        utterance = AVSpeechUtterance(string: content)
    }
    utterance.voice = voice

    var file: AVAudioFile?
    var finished = false
    // Reusing one synthesizer stalls after the first clip on some voices
    let current = AVSpeechSynthesizer()
    synthesizer = current
    current.write(utterance) { buffer in
        guard !finished, let pcm = buffer as? AVAudioPCMBuffer else { return }
        lastProgress = Date()
        // An empty buffer marks the end of the utterance
        if pcm.frameLength == 0 {
            finished = true
            file = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { renderNext() }
            return
        }
        if file == nil {
            file = try? AVAudioFile(forWriting: outputFolder.appendingPathComponent("\(name).caf"),
                                    settings: pcm.format.settings, commonFormat: pcm.format.commonFormat,
                                    interleaved: pcm.format.isInterleaved)
        }
        try? file?.write(from: pcm)
    }
}

// The synthesizer reports no error when a voice can't render, it just never calls back
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    if Date().timeIntervalSince(lastProgress) > 12 {
        FileHandle.standardError.write(Data("Speech synthesis stalled with \(pending.count) clips left.\n".utf8))
        exit(2)
    }
}
renderNext()
RunLoop.main.run()
