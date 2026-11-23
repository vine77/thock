import Foundation

struct SoundpackConfig: Decodable {
    let id: UUID
    let metadata: SoundpackConfigMetadata
    let license: License
    let sounds: [String: KeySound]
    /// Optional sounds for key sequences, keyed by key names separated by spaces ("t h")
    let sequences: [String: SequenceSound]?
    /// When present, the pack sounds one key at a time: each key-down fades out the one before it
    let monophonic: MonophonicPlayback?
}

struct SoundpackConfigMetadata: Decodable {
    let name: String
    let brand: String
    let author: String
    let category: String
    let supportsKeyUp: Bool
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        brand = try container.decode(String.self, forKey: .brand)
        author = try container.decode(String.self, forKey: .author)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "keyboard"
        supportsKeyUp = try container.decodeIfPresent(Bool.self, forKey: .supportsKeyUp) ?? false
    }
    
    private enum CodingKeys: String, CodingKey {
        case name, brand, author, category, supportsKeyUp
    }
}

struct License: Decodable {
    let type: String
    let url: String
}

struct KeySound: Decodable {
    let down: [String]
    let up: [String]
}

struct MonophonicPlayback: Decodable {
    static let defaultFadeMs = 20.0
    
    /// How long the previous key's sound takes to fade out, in milliseconds
    let fadeMs: Double
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fadeMs = max(0, try container.decodeIfPresent(Double.self, forKey: .fadeMs) ?? Self.defaultFadeMs)
    }
    
    private enum CodingKeys: String, CodingKey {
        case fadeMs
    }
}

struct SequenceSound: Decodable {
    /// Played when the last key of the sequence goes down. Empty keeps that key silent.
    let down: [String]
}
