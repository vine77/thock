import CoreGraphics
import Foundation

// MARK: - Sound Engine

/// Orchestrates sound playback by coordinating between keyboard events,
/// sound selection, and the low-level audio manager.
final class SoundEngine {
    static let shared = SoundEngine()
    
    // MARK: - Key Sequences (confined to SoundManager.playbackQueue)
    
    private struct WeakVoice {
        // Device changes and recovery discard voices, so a handle must not keep one alive
        weak var voice: SoundManager.ActiveSound?
    }
    
    private static let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
    private static let rememberedVoices = 8
    
    private var sequenceMatcher = KeySequenceMatcher(sequences: [:])
    private var sequenceConfigVersion: Int?
    /// Voices of the most recent sequence-eligible key-downs, oldest first; nil-backed when a key was silent
    private var recentVoices: [WeakVoice] = []
    /// The key-down voice still sounding in a monophonic soundpack
    private var soloVoice = WeakVoice()
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Sound Loading
    
    func preloadSounds(for soundpack: Soundpack) {
        SoundManager.shared.preloadSounds(for: soundpack)
    }
    
    func preloadMouseSounds(for soundpack: Soundpack, config: SoundpackConfig) {
        SoundManager.shared.preloadMouseSoundsFromPack(for: soundpack, config: config)
    }
    
    // MARK: - Playback
    
    /// Plays sound for a keyboard event by selecting appropriate sound and delegating to manager
    /// - Parameters:
    ///   - keyCode: The keyboard key code
    ///   - isKeyDown: true for key press, false for key release
    ///   - layout: Physical layout captured from the originating keyboard event
    ///   - flags: Modifier flags of the originating event, used to keep shortcuts out of key sequences
    ///   - latencyId: Optional UUID for latency measurement tracking
    func play(for keyCode: Int64, isKeyDown: Bool, layout: KeyLayout.Physical = .ansi, flags: CGEventFlags = [], latencyId: UUID? = nil) {
        // Don't play if app is disabled
        guard AppEngine.shared.isEnabled() else {
            sequenceMatcher.reset()
            return
        }
        
        recordLatencyCheckpoint(latencyId, point: .soundEngineInvoked)
        
        // Map key code to key type and get appropriate sounds
        let keyType = KeyMapper.fromKeyCode(keyCode)
        // Keypad keys share names with the main keys but shift doesn't change what they type
        let shifted = flags.contains(.maskShift) && !flags.contains(.maskNumericPad)
        var keySoundList = isKeyDown
        ? SoundpackEngine.shared.getKeyDownSounds(for: keyType, shifted: shifted)
        : SoundpackEngine.shared.getKeyUpSounds(for: keyType)
        
        var tracksVoice = false
        var voicesToCut: ArraySlice<WeakVoice> = []
        if isKeyDown {
            switch matchSequence(endingWith: keyType, flags: flags) {
            case .untracked:
                break
            case .single:
                tracksVoice = true
            case .sequence(let sounds, let span):
                tracksVoice = true
                keySoundList = sounds
                // A silent sequence ("c k") leaves the earlier keys' sounds ringing
                if !sounds.isEmpty {
                    voicesToCut = recentVoices.suffix(span - 1)
                }
            }
        }
        
        let soloFade = isKeyDown ? SoundpackConfigManager.shared.getMonophonicFade() : nil
        
        // Play random sound from the list
        var voice: SoundManager.ActiveSound?
        if let soundFileName = keySoundList.randomElement() {
            recordLatencyCheckpoint(latencyId, point: .soundSelected)
            if let soloFade {
                // Every earlier key of a sequence was already cut by the key after it
                if let previous = soloVoice.voice {
                    SoundManager.shared.fadeOut(previous, duration: soloFade)
                }
            } else {
                for replaced in voicesToCut {
                    if let replaced = replaced.voice {
                        SoundManager.shared.fadeOut(replaced)
                    }
                }
            }
            voice = play(sound: soundFileName, latencyId: latencyId, position: KeyLayout.position(for: keyCode, width: SettingsEngine.shared.getSpatialWidth(), layout: layout))
            if soloFade != nil {
                soloVoice = WeakVoice(voice: voice)
            }
        }
        
        if tracksVoice {
            recentVoices.append(WeakVoice(voice: voice))
            if recentVoices.count > Self.rememberedVoices {
                recentVoices.removeFirst(recentVoices.count - Self.rememberedVoices)
            }
        }
    }
    
    /// Feeds a key-down to the sequence matcher, rebuilding it first if the keyboard soundpack changed
    private func matchSequence(endingWith key: String, flags: CGEventFlags) -> KeySequenceMatcher.Outcome {
        let configVersion = SoundpackConfigManager.shared.keyboardConfigVersion
        if sequenceConfigVersion != configVersion {
            sequenceConfigVersion = configVersion
            sequenceMatcher = KeySequenceMatcher(sequences: SoundpackConfigManager.shared.getKeySequences())
            recentVoices.removeAll()
        }
        guard !sequenceMatcher.isEmpty else { return .untracked }
        return sequenceMatcher.keyDown(key, at: ProcessInfo.processInfo.systemUptime,
                                       shortcutModifiersHeld: !flags.isDisjoint(with: Self.shortcutModifiers))
    }
    
    /// Plays a specific sound by name
    /// - Parameters:
    ///   - name: The sound file name
    ///   - latencyId: Optional UUID for latency measurement tracking
    ///   - position: Where the sound sits in space when spatial audio is on
    @discardableResult
    func play(sound name: String, latencyId: UUID? = nil, position: SoundPosition? = nil) -> SoundManager.ActiveSound? {
        let pitchVariation = SettingsEngine.shared.getPitchVariation()
        return SoundManager.shared.play(sound: name, pitchVariation: pitchVariation, latencyId: latencyId, position: position)
    }
}
