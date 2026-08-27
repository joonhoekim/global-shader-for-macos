import Foundation
import CoreVideo

// Confirming feedback — the overlay capturing itself — with a number rather than an eye.
//
// --diag paints the top-left 64 pixels magenta (Renderer.gs_diag) and reads that spot
// back out of **the capture** on the next frame. If our window is properly excluded,
// the capture holds the original screen and no magenta appears. If it appears, that is
// feedback.
//
// Why the test is needed: with feedback running, the screen looks like "the shader is
// just a bit strong" and then slowly falls apart. One frame is not enough to tell.
final class DiagLog {
    static let shared = DiagLog()
    private let lock = NSLock()
    private var notes: [String] = []

    func note(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        notes.append(s)
        FileHandle.standardError.write("global-shader: [diag] \(s)\n".data(using: .utf8)!)
    }
}

enum FeedbackProbe {
    /// Reads the marker spot in a captured frame and returns the magenta fraction.
    /// SCK buffers are BGRA 8-bit, backed by IOSurface, so the CPU can read them.
    static func magentaFraction(in pb: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let w = min(64, CVPixelBufferGetWidth(pb))
        let h = min(64, CVPixelBufferGetHeight(pb))
        guard w > 8, h > 8 else { return nil }

        var hits = 0, total = 0
        let p = base.assumingMemoryBound(to: UInt8.self)
        // Only the inside of the marker. The edges can be blended by scaling.
        for y in stride_(8, h - 8, 4) {
            for x in stride_(8, w - 8, 4) {
                let o = y * stride + x * 4
                let b = p[o], g = p[o + 1], r = p[o + 2]
                if r > 200 && b > 200 && g < 60 { hits += 1 }
                total += 1
            }
        }
        return total > 0 ? Double(hits) / Double(total) : nil
    }

    private static func stride_(_ from: Int, _ to: Int, _ by: Int) -> StrideTo<Int> {
        Swift.stride(from: from, to: max(to, from + 1), by: by)
    }
}
