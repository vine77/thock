import Foundation
import OSLog

class SoundpackConfigManager {
    static let shared = SoundpackConfigManager()
    
    private var keyboardConfig: SoundpackConfig? {
        didSet { keyboardConfigVersion &+= 1 }
    }
    private var mouseConfig: SoundpackConfig?
    
    /// Changes whenever the keyboard config is loaded or cleared, so state derived from it can be rebuilt
    private(set) var keyboardConfigVersion = 0
    
    private init() {}
    
    // MARK: - Keyboard
    
    func loadConfig(for soundpack: Soundpack) {
        keyboardConfig = loadConfig(at: soundpack.path, name: soundpack.name)
    }
    
    func clearConfig() {
        keyboardConfig = nil
    }
    
    func supportsKeyUpSounds() -> Bool {
        return keyboardConfig?.metadata.supportsKeyUp ?? false
    }
    
    func getKeyDownSounds(for key: String, shifted: Bool = false) -> [String] {
        return keyboardConfig?.sounds[key]?.downSounds(shifted: shifted)
        ?? keyboardConfig?.sounds[KeyMapper.keyCodeNotFound]?.down
        ?? []
    }
    
    func getKeyUpSounds(for key: String) -> [String] {
        return keyboardConfig?.sounds[key]?.up
        ?? keyboardConfig?.sounds[KeyMapper.keyCodeNotFound]?.up
        ?? []
    }
    
    func getKeySequences() -> [String: [String]] {
        return keyboardConfig?.sequences?.mapValues(\.down) ?? [:]
    }
    
    /// Fade-out time for the previous key's sound, or nil when the pack lets key sounds overlap
    func getMonophonicFade() -> TimeInterval? {
        return keyboardConfig?.monophonic.map { $0.fadeMs / 1000 }
    }
    
    // MARK: - Mouse
    
    func loadMouseConfig(for soundpack: Soundpack) {
        mouseConfig = loadConfig(at: soundpack.path, name: soundpack.name)
    }
    
    func clearMouseConfig() {
        mouseConfig = nil
    }
    
    func getMouseConfig() -> SoundpackConfig? {
        return mouseConfig
    }
    
    // MARK: - Private
    
    private func loadConfig(at path: String, name: String) -> SoundpackConfig? {
        let fileURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Thock/\(path)config.json")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Logger.engine.warning("Config not found for soundpack: '\(name)'")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let config = try JSONDecoder().decode(SoundpackConfig.self, from: data)
            Logger.engine.info("Loaded config for soundpack: '\(name)'")
            return config
        } catch {
            Logger.engine.error("Failed to decode SoundpackConfig for '\(name)': \(error)")
            return nil
        }
    }
}
