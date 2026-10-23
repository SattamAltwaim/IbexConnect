import AppKit
import SwiftUI

/// The KAUST logo as spinning ASCII art that dissolves into the Ibex, which
/// gallops for a while before dissolving back. Purely decorative; it sits
/// in the login window and the dashboard header.
struct LogoMorphView: View {
    var columns = 56
    var rows = 22
    var fontSize: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animation: LogoAnimation?

    nonisolated private static let frameRate = 12.0
    private let font: Font

    init(columns: Int = 56, rows: Int = 22, fontSize: CGFloat = 7) {
        self.columns = columns
        self.rows = rows
        self.fontSize = fontSize
        self.font = .system(size: fontSize, weight: .black, design: .monospaced)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.frameRate, paused: reduceMotion)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                guard let animation else { return }
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let lines = animation.frame(at: t)
                let lineHeight = size.height / CGFloat(rows)
                // One draw per row, not per character: a few dozen text
                // layouts a frame is cheap, a couple of thousand is not.
                for (row, line) in lines.enumerated() {
                    let text = context.resolve(Text(line).font(font).foregroundColor(.primary))
                    context.draw(text, at: CGPoint(x: size.width / 2, y: (CGFloat(row) + 0.5) * lineHeight))
                }
            }
        }
        .frame(width: CGFloat(columns) * fontSize * 0.6, height: CGFloat(rows) * fontSize * 1.15)
        .accessibilityHidden(true)
        .task {
            animation = await Task.detached(priority: .utility) {
                LogoAnimation(columns: columns, rows: rows, frameRate: Self.frameRate)
            }.value
        }
    }
}

/// Every frame of the loop, rendered once up front as one string per row:
/// sampling the logos each frame is far too slow for a decoration,
/// especially in Debug builds.
nonisolated final class LogoAnimation: Sendable {
    private let frames: [[String]]
    private let frameRate: Double

    init(columns: Int, rows: Int, frameRate: Double) {
        let rasterizer = LogoRasterizer(columns: columns, rows: rows)
        let count = Int(LogoRasterizer.period * frameRate)
        frames = (0..<count).map { rasterizer.frame(at: Double($0) / frameRate) }
        self.frameRate = frameRate
    }

    func frame(at time: TimeInterval) -> [String] {
        frames[Int(time * frameRate) % frames.count]
    }
}

/// Turns the two logos into rows of characters for a given moment of the loop.
nonisolated final class LogoRasterizer: Sendable {
    /// Heavy glyphs from the start, so the art reads as solid rather than
    /// as a texture.
    private static let ramp: [Character] = Array(" .:+*#%@@")
    /// Length of the loop in seconds.
    static let period: TimeInterval = 9

    let columns: Int
    let rows: Int
    private let kaust: CGImage?
    private let ibex: CGImage?
    /// Per-cell jitter so the dissolve looks like noise rather than a wipe.
    private let noise: [Float]

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        kaust = Self.load("KAUSTLogo")
        ibex = Self.load("IbexLogo")
        var generator = SplitMix64(seed: 0x1BE5)
        noise = (0..<(columns * rows)).map { _ in Float(generator.next() % 1000) / 1000 }
    }

    private static func load(_ name: String) -> CGImage? {
        guard let image = NSImage(named: name) else { return nil }
        var rect = CGRect(origin: .zero, size: CGSize(width: 512, height: 512))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Timeline

    /// The loop, in seconds: the KAUST logo spins for four, dissolves into
    /// the Ibex over one, the Ibex gallops for three, dissolves back over one.
    func frame(at time: TimeInterval) -> [String] {
        let t = Float(time.truncatingRemainder(dividingBy: Self.period))
        let kaustField: [Float]
        let ibexField: [Float]
        let blend: Float

        switch t {
        case ..<4:
            kaustField = sampleKaust(spin: t / 4)
            ibexField = []
            blend = 0
        case ..<5:
            kaustField = sampleKaust(spin: 0)
            ibexField = sampleIbex(stride: t - 4)
            blend = t - 4
        case ..<8:
            kaustField = []
            ibexField = sampleIbex(stride: t - 4)
            blend = 1
        default:
            kaustField = sampleKaust(spin: 0)
            ibexField = sampleIbex(stride: t - 4)
            blend = 1 - (t - 8)
        }

        return (0..<rows).map { row in
            String((0..<columns).map { col in
                let i = row * columns + col
                // Each cell flips at its own moment, spread around the global
                // blend, so the two logos dissolve into each other.
                let mix = Self.smoothstep((blend * 1.6 - 0.3 - noise[i] * 0.6) / 0.4)
                let a = kaustField.isEmpty ? 0 : kaustField[i]
                let b = ibexField.isEmpty ? 0 : ibexField[i]
                return Self.glyph(density: a * (1 - mix) + b * mix)
            })
        }
    }

    /// Two full turns about the vertical axis, with a little tilt so it
    /// reads as three-dimensional even in ASCII. The width goes negative
    /// on the far side, which mirrors the logo: that is what makes it look
    /// like a turn rather than a squash and a bounce back.
    private func sampleKaust(spin: Float) -> [Float] {
        guard let kaust else { return Array(repeating: 0, count: columns * rows) }
        let angle = spin * 4 * .pi
        let facing = CGFloat(cos(angle))
        let width = facing < 0 ? min(facing, -0.04) : max(facing, 0.04)
        let tilt = CGFloat(sin(angle)) * 0.1
        let transform = CGAffineTransform(rotationAngle: tilt).scaledBy(x: width, y: 1)
        return sample(kaust, transform: transform, whiteIsClear: false)
    }

    /// A gallop: the Ibex bobs, pitches forward on the way down, and
    /// stretches slightly at full extension.
    private func sampleIbex(stride: Float) -> [Float] {
        guard let ibex else { return Array(repeating: 0, count: columns * rows) }
        let phase = stride * 2 * .pi * 1.6
        let bob = CGFloat(abs(sin(phase))) * 0.08
        let pitch = CGFloat(sin(phase + .pi / 2)) * 0.08
        let stretch = 1 + CGFloat(sin(phase * 2)) * 0.05
        let transform = CGAffineTransform(translationX: 0, y: bob)
            .rotated(by: pitch)
            .scaledBy(x: stretch, y: 1 / stretch)
        return sample(ibex, transform: transform, whiteIsClear: true)
    }

    // MARK: - Sampling

    /// Draws the image into a small bitmap, two pixels wide and four tall per
    /// character cell (cells are about twice as tall as they are wide), and
    /// averages each block into a density. `transform` is applied about the
    /// centre, in units of the image's fitted height.
    private func sample(_ image: CGImage, transform: CGAffineTransform, whiteIsClear: Bool) -> [Float] {
        let supersample = 2
        let width = columns * supersample
        let height = rows * supersample * 2
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var field = [Float](repeating: 0, count: columns * rows)

        let fitted = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high

            // Fit the image inside the bitmap with a margin that leaves room
            // for the gallop's bob and tilt, then apply the caller's
            // transform about the centre.
            let margin: CGFloat = 0.84
            let scale = min(
                CGFloat(width) * margin / CGFloat(image.width),
                CGFloat(height) * margin / CGFloat(image.height)
            )
            let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            context.concatenate(
                CGAffineTransform(
                    a: transform.a, b: transform.b, c: transform.c, d: transform.d,
                    tx: transform.tx * drawn.height, ty: transform.ty * drawn.height
                )
            )
            context.draw(
                image,
                in: CGRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height)
            )
            return true
        }
        guard fitted else { return field }

        let blockWidth = supersample
        let blockHeight = supersample * 2
        let blockArea = Float(blockWidth * blockHeight)
        for row in 0..<rows {
            for col in 0..<columns {
                var density: Float = 0
                for y in 0..<blockHeight {
                    // The bitmap's first row in memory is the top of the
                    // image, same as the grid.
                    let py = row * blockHeight + y
                    for x in 0..<blockWidth {
                        let px = col * blockWidth + x
                        let offset = (py * width + px) * 4
                        let alpha = Float(pixels[offset + 3]) / 255
                        guard alpha > 0.02 else { continue }
                        var weight = alpha
                        if whiteIsClear {
                            // The Ibex logo sits on a white background:
                            // the lighter the pixel, the less it counts.
                            let r = Float(pixels[offset]) / 255 / alpha
                            let g = Float(pixels[offset + 1]) / 255 / alpha
                            let b = Float(pixels[offset + 2]) / 255 / alpha
                            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
                            weight *= min(max((0.92 - luminance) / 0.5, 0), 1)
                        }
                        density += weight
                    }
                }
                field[row * columns + col] = density / blockArea
            }
        }
        return field
    }

    private static func glyph(density: Float) -> Character {
        // Pull the midtones up so edges come out bold rather than wispy.
        let boosted = pow(min(max(density, 0), 1), 0.6)
        return ramp[Int((boosted * Float(ramp.count - 1)).rounded())]
    }

    private static func smoothstep(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Deterministic noise, so the dissolve pattern is the same every loop.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
