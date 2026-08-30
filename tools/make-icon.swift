// make-icon.swift — Resources/icon.png → an .iconset directory for iconutil.
//
//   swift tools/make-icon.swift Resources/icon.png build/AppIcon.iconset
//
// ── Why anything at all is done to the artwork ───────────────────────────
// Resources/icon.png is a full-bleed square whose edges feather out to transparent.
// Dropped into an .icns as-is it reads as a cropped screenshot: macOS lays app icons out
// on a shared optical grid, and next to Finder, Safari and System Settings the one square
// with ragged edges is the one that looks like it did not finish installing. So the
// artwork is masked into the shape everything else on the system already has.
//
// Apple's macOS grid, on a 1024 canvas: the icon body is 824x824 — a 100pt margin all
// round — with a shadow cast into the bottom margin. Those are the numbers below.
//
// ── Why a superellipse and not a rounded rect ────────────────────────────
// A rounded rect corners with a circular arc, and where the arc meets the straight edge
// the curvature jumps from 1/r to 0. At 1024 that kink is subtle; at 32 it is what makes
// a hand-rolled icon look hand-rolled. Apple's shape is continuous — squircle-ish — and
// |x|^n + |y|^n = 1 at n = 5 lands close enough that the difference does not survive
// being drawn at 16 points.
//
// ── Why every size is composed from the master ───────────────────────────
// The obvious shortcut is to render 1024 once and let sips downscale it into the other
// nine slots. That downscales the mask edge and the shadow along with the art, and both
// are about a pixel wide by the time they reach icon_16x16 — the edge goes soft and the
// shadow turns into grey mud. Composing each slot at its own size keeps the mask a hard
// edge and gives the shadow a radius that means something at that scale.
//
// ── Why CoreGraphics and not AppKit ──────────────────────────────────────
// NSImage and NSGraphicsContext would be shorter. But this runs inside Homebrew's build
// sandbox, which hands the build a throwaway HOME and no window server session, and
// dragging in an application framework to composite an image is how that turns into a
// failure nobody can reproduce locally. Nothing here needs more than a bitmap context.
import CoreGraphics
import Foundation
import ImageIO

func die(_ message: String) -> Never {
    FileHandle.standardError.write("make-icon: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { die("usage: make-icon.swift <master.png> <out.iconset>") }
let masterURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { die("cannot read \(masterURL.path)") }

/// |x|^n + |y|^n = 1, traced as a polygon. 720 segments is far more than any slot can
/// resolve, so the polygon never shows as flat spots — even at 1024 a segment is under a
/// pixel of arc.
func squircle(in r: CGRect, n: Double = 5) -> CGPath {
    let a = r.width / 2, b = r.height / 2
    let cx = r.midX, cy = r.midY
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let p = CGPoint(x: cx + a * copysign(pow(abs(ct), 2 / n), ct),
                        y: cy + b * copysign(pow(abs(st), 2 / n), st))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// One slot, composed at its own pixel size. Every measurement is a fraction of the
/// canvas, so the 16pt slot is the 1024pt one scaled — not a different design.
func compose(px: Int) -> CGImage {
    let n = Double(px)
    guard let ctx = CGContext(data: nil, width: px, height: px,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { die("cannot make a \(px)x\(px) bitmap context") }
    ctx.interpolationQuality = .high

    // 100/1024 margin all round; the body rides 8/1024 high so the shadow has somewhere
    // to fall without clipping.
    let margin = n * 100 / 1024
    let body = CGRect(x: margin, y: margin + n * 8 / 1024,
                      width: n - margin * 2, height: n - margin * 2)
    let path = squircle(in: body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -n * 10 / 1024),
                  blur: n * 24 / 1024,
                  color: CGColor(gray: 0, alpha: 0.30))
    // Filled with something opaque purely to cast the shadow; the artwork is painted over
    // it in the next block, so the colour itself never shows.
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    // The master is drawn to the body rather than to the whole canvas: its own feathered
    // edge falls outside the clip either way, and scaling it to the body is what keeps
    // the art centred once the corners are taken off.
    ctx.draw(master, in: body)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { die("cannot read back the \(px)x\(px) bitmap") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { die("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { die("cannot finish \(url.path)") }
}

// The ten slots iconutil expects. A missing one is not an error to iconutil — it simply
// ships an icon with nothing to show at that size, which surfaces later as a blurry
// Spotlight result rather than as a build failure.
let slots: [(name: String, px: Int)] = [
    ("icon_16x16",       16), ("icon_16x16@2x",     32),
    ("icon_32x32",       32), ("icon_32x32@2x",     64),
    ("icon_128x128",    128), ("icon_128x128@2x",  256),
    ("icon_256x256",    256), ("icon_256x256@2x",  512),
    ("icon_512x512",    512), ("icon_512x512@2x", 1024),
]

do {
    try? FileManager.default.removeItem(at: outDir)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch { die("cannot make \(outDir.path): \(error.localizedDescription)") }

// Composed once per pixel size; the three sizes two slots share (32, 256, 512) are drawn
// once and written twice.
var rendered: [Int: CGImage] = [:]
for (name, px) in slots {
    let image = rendered[px] ?? { let i = compose(px: px); rendered[px] = i; return i }()
    writePNG(image, to: outDir.appendingPathComponent("\(name).png"))
}
print("iconset      \(slots.count) slots, \(rendered.count) rendered → \(outDir.path)")
