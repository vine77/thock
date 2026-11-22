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

    // MARK: - Fade-out

    /// Renders `blocks` blocks of `frames` frames and returns the left channel
    private func renderLeft(_ manager: SoundManager, blocks: Int, frames: Int) -> [Float] {
        var left: [Float] = []
        var output = [Float](repeating: 0, count: frames * 2)
        for _ in 0..<blocks {
            output.withUnsafeMutableBufferPointer {
                manager.renderSamples(into: $0.baseAddress!, frameCount: frames)
            }
            left.append(contentsOf: stride(from: 0, to: frames * 2, by: 2).map { output[$0] })
        }
        return left
    }

    @Test(arguments: [64, 256])
    func aCutVoiceRampsToSilenceAcrossBlocksAndIsRemoved(blockFrames: Int) {
        let manager = SoundManager(audioOutputEnabled: false)
        let sound = SoundManager.PCMSound(data: Array(repeating: 0.8, count: 16_384), frameCount: 8192)
        let voice = manager.enqueue(sound, pitchVariation: 0, latencyId: nil, position: nil, source: .keyboard)

        let level = renderLeft(manager, blocks: 1, frames: blockFrames)[0]
        #expect(level > 0)

        // 5 ms at the offline manager's 44.1 kHz
        let fadeFrames = 221
        manager.fadeOut(voice, duration: 0.005)
        let faded = renderLeft(manager, blocks: fadeFrames / blockFrames + 2, frames: blockFrames)

        // Starts at full level and never steps by more than one ramp increment: no click
        #expect(abs(faded[0] - level) < 0.000001)
        let largestStep = zip(faded, faded.dropFirst()).map { $0 - $1 }.max() ?? 0
        #expect(largestStep <= level / Float(fadeFrames) + 0.000001)
        #expect(zip(faded, faded.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(faded[fadeFrames - 1] > 0)
        #expect(faded[fadeFrames...].allSatisfy { $0 == 0 })
        #expect(voice.isFinished)
        #expect(manager.activeVoiceCount == 0)
    }

    @Test func cuttingOneVoiceLeavesOthersUntouched() {
        let manager = SoundManager(audioOutputEnabled: false)
        let sound = SoundManager.PCMSound(data: Array(repeating: 0.8, count: 16_384), frameCount: 8192)
        let cut = manager.enqueue(sound, pitchVariation: 0, latencyId: nil, position: nil, source: .keyboard)
        let level = renderLeft(manager, blocks: 1, frames: 64)[0]
        manager.enqueue(sound, pitchVariation: 0, latencyId: nil, position: nil, source: .mouse)

        manager.fadeOut(cut, duration: 0.005)
        let output = renderLeft(manager, blocks: 8, frames: 64)
        #expect(abs(output[511] - level) < 0.000001)
        #expect(manager.activeVoiceCount == 1)
    }

    @Test func aVoiceCutBeforeItWasHeardIsDroppedSilently() {
        let manager = SoundManager(audioOutputEnabled: false)
        let sound = SoundManager.PCMSound(data: Array(repeating: 0.8, count: 1024), frameCount: 512)
        let voice = manager.enqueue(sound, pitchVariation: 0, latencyId: nil, position: nil, source: .keyboard)
        manager.fadeOut(voice)
        #expect(renderLeft(manager, blocks: 1, frames: 64).allSatisfy { $0 == 0 })
        #expect(manager.activeVoiceCount == 0)
    }

    @Test func cuttingADiscardedVoiceIsHarmless() {
        let manager = SoundManager(audioOutputEnabled: false)
        let sound = SoundManager.PCMSound(data: Array(repeating: 0.8, count: 1024), frameCount: 512)
        let voice = manager.enqueue(sound, pitchVariation: 0, latencyId: nil, position: nil, source: .keyboard)
        _ = renderLeft(manager, blocks: 1, frames: 64)
        // Device changes and recovery clear every voice while callers may still hold one
        _ = manager.stopPlayback(preservingLatestSound: false) {}
        manager.fadeOut(voice)
        #expect(renderLeft(manager, blocks: 2, frames: 64).allSatisfy { $0 == 0 })
        #expect(manager.activeVoiceCount == 0)
    }

    @Test func aFadingVoiceIsNotRetainedAcrossRecovery() {
        let manager = SoundManager(audioOutputEnabled: false)
        let sound = SoundManager.PCMSound(data: Array(repeating: 0.8, count: 16_384), frameCount: 8192)
        let voice = manager.enqueue(sound, pitchVariation: 0, latencyId: nil, position: nil, source: .keyboard)
        _ = renderLeft(manager, blocks: 1, frames: 64)
        manager.fadeOut(voice)
        #expect(manager.stopPlayback(preservingLatestSound: true) {} == nil)
    }
}
