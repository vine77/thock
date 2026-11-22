import Accelerate

/// Linear-interpolation playback of PCM at an arbitrary rate, keeping fractional phase between calls.
enum Resampler {
    @discardableResult
    static func mix(source: UnsafeBufferPointer<Float>, channels: Int, frameCount: Int,
                    position: inout Double, rate: Double,
                    into out: UnsafeMutablePointer<Float>, outChannels: Int, outFrames: Int,
                    gains: (left: Float, right: Float),
                    fade: (remaining: Int, length: Int)? = nil) -> Int {
        guard let base = source.baseAddress, frameCount > 0, position < Double(frameCount) else { return 0 }

        // Unity rate on a whole frame, plain scaled copy
        if fade == nil, rate == 1, position == position.rounded(.down) {
            let start = Int(position)
            let count = min(outFrames, frameCount - start)
            var left = gains.left
            var right = gains.right
            let src = base + start * channels
            if outChannels == 1 {
                vDSP_vsma(src, vDSP_Stride(channels), &left, out, 1, out, 1, vDSP_Length(count))
            } else {
                let rightSrc = channels == 2 ? src + 1 : src
                vDSP_vsma(src, vDSP_Stride(channels), &left, out, 2, out, 2, vDSP_Length(count))
                vDSP_vsma(rightSrc, vDSP_Stride(channels), &right, out + 1, 2, out + 1, 2, vDSP_Length(count))
            }
            position += Double(count)
            return count
        }

        let last = frameCount - 1
        let rightOffset = channels == 2 ? 1 : 0
        var pos = position
        var written = 0
        // A fading voice ramps linearly to silence over `length` frames and writes nothing after it
        let limit = fade.map { min(outFrames, $0.remaining) } ?? outFrames
        let envelopeStep: Float = fade.map { 1 / Float(max(1, $0.length)) } ?? 0
        var envelope: Float = fade.map { Float($0.remaining) * envelopeStep } ?? 1
        while written < limit {
            let frame = Int(pos)
            if frame >= frameCount { break }
            let next = min(frame + 1, last)
            let fraction = Float(pos - Double(frame))
            let a = frame * channels
            let b = next * channels

            let leftSample = base[a] + (base[b] - base[a]) * fraction
            if outChannels == 1 {
                out[written] += leftSample * gains.left * envelope
            } else {
                let rightSample = base[a + rightOffset] + (base[b + rightOffset] - base[a + rightOffset]) * fraction
                out[written * 2] += leftSample * gains.left * envelope
                out[written * 2 + 1] += rightSample * gains.right * envelope
            }
            envelope -= envelopeStep
            pos += rate
            written += 1
        }
        position = pos
        return written
    }
}
