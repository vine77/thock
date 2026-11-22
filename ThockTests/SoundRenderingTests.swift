import Foundation
import Testing
@testable import Thock

struct SoundRenderingTests {
    @Test func recoveryDetachesTheNewestVoiceBeforeTeardownCallbacksRender() throws {
        let manager = SoundManager(audioOutputEnabled: false)
        let older = SoundManager.PCMSound(data: Array(repeating: 0.8, count: 1024), frameCount: 512)
        let newest = SoundManager.PCMSound(data: Array(repeating: -0.4, count: 8), frameCount: 4)
        let position = SoundPosition(azimuth: 30, elevation: -10)
        let latencyID = UUID()
        manager.enqueue(older, pitchVariation: 0, latencyId: nil, position: nil, source: .keyboard)
        manager.enqueue(newest, pitchVariation: 0, latencyId: latencyID, position: position,
                        source: .mouse, playbackRate: 1.25)

        var output = [Float](repeating: 0, count: 64)
        let retained = try #require(manager.stopPlayback(preservingLatestSound: true) {
            // Model pending buffers returned by synchronous AudioQueueStop. A late
            // snapshot would consume the short newest voice and retain the older one.
            for _ in 0..<3 {
                output.withUnsafeMutableBufferPointer {
                    manager.renderSamples(into: $0.baseAddress!, frameCount: 32)
                }
                #expect(output.allSatisfy { $0 == 0 }, "Teardown callbacks must not render pending voices")
            }
        })
        #expect(retained.sound === newest)
        #expect(retained.rate == 1.25)
        #expect(retained.source == .mouse)
        #expect(retained.position == position)
        #expect(retained.latencyId == latencyID)
        #expect(retained.sourcePosition == 0)
    }

    @Test func soundsRecordedBelowTheDeviceRateAreStretchedToKeepTheirDuration() {
        // The offline manager renders at 44.1 kHz, so a 22.05 kHz sound must last twice its frame count
        let manager = SoundManager(audioOutputEnabled: false)
        let halfRate = SoundManager.PCMSound(data: Array(repeating: 0.8, count: 32), frameCount: 16, sampleRate: 22_050)
        manager.enqueue(halfRate, pitchVariation: 0, latencyId: nil, position: nil, source: .keyboard)

        var output = [Float](repeating: 0, count: 96)
        output.withUnsafeMutableBufferPointer {
            manager.renderSamples(into: $0.baseAddress!, frameCount: 48)
        }
        #expect(output[..<64].allSatisfy { $0 > 0 })
        #expect(output[64...].allSatisfy { $0 == 0 })
    }

    @Test func soundsWithoutARecordedRatePlayFrameForFrame() {
        let manager = SoundManager(audioOutputEnabled: false)
        let sound = SoundManager.PCMSound(data: Array(repeating: 0.8, count: 32), frameCount: 16)
        manager.enqueue(sound, pitchVariation: 0, latencyId: nil, position: nil, source: .keyboard)

        var output = [Float](repeating: 0, count: 96)
        output.withUnsafeMutableBufferPointer {
            manager.renderSamples(into: $0.baseAddress!, frameCount: 48)
        }
        #expect(output[..<32].allSatisfy { $0 > 0 })
        #expect(output[32...].allSatisfy { $0 == 0 })
    }
}
