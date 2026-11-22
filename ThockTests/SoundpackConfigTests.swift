import Foundation
import Testing
@testable import Thock

struct SoundpackConfigTests {
    private func decode(extra: String = "") throws -> SoundpackConfig {
        let json = """
        {
          "id": "6F1C2B7E-0C0A-4B1E-9C55-0B8F6C0A7D11",
          "metadata": { "name": "Test", "brand": "Test", "author": "Test" },
          "license": { "type": "MIT", "url": "https://example.com" },
          "sounds": { "a": { "down": ["a.wav"], "up": [] } }\(extra)
        }
        """
        return try JSONDecoder().decode(SoundpackConfig.self, from: Data(json.utf8))
    }

    @Test func aConfigWithoutSequencesStillDecodes() throws {
        let config = try decode()
        #expect(config.sequences == nil)
        #expect(config.sounds["a"]?.down == ["a.wav"])
    }

    @Test func sequencesDecodeWithTheirSoundLists() throws {
        let config = try decode(extra: #", "sequences": { "t h": { "down": ["th_1.wav", "th_2.wav"] }, "c k": { "down": [] } }"#)
        #expect(config.sequences?["t h"]?.down == ["th_1.wav", "th_2.wav"])
        #expect(config.sequences?["c k"]?.down == [])
    }
}
